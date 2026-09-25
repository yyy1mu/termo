import Foundation

struct RemoteFSError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - 上传 v2 传输层类型

/// 传输信号（单一原子状态）。
enum UploadSignal { case run, cancel, pause }

/// 单文件传输控制盒（跨线程，锁保护）：承载控制信号与已发送字节（后者仅供 UI 进度显示）。
final class UploadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _signal: UploadSignal = .run
    private var _sent: Int64 = 0
    func set(_ s: UploadSignal) { lock.lock(); _signal = s; lock.unlock() }
    var signal: UploadSignal { lock.lock(); defer { lock.unlock() }; return _signal }
    func setSent(_ v: Int64) { lock.lock(); _sent = v; lock.unlock() }
    var sent: Int64 { lock.lock(); defer { lock.unlock() }; return _sent }
}

/// 命令取消句柄：持有运行中的引擎会话，cancel() 置其取消标志——exec 循环检测后中断、通道关闭。
/// 用于让「正在删除」等可能较慢的命令支持用户中途取消。线程安全。
final class CommandHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SSHSession?
    private var cancelled = false

    /// 绑定借出的会话；若在绑定前已被取消，立即打断它。
    func bind(_ s: SSHSession) {
        lock.lock(); let c = cancelled; if !c { session = s }; lock.unlock()
        if c { s.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let s = session; lock.unlock()
        s?.cancel()
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// 单文件传输结果。续传偏移**不在这里返回**——须由上层在传输结束后重新 stat 远端 .part 取得
/// （本地"已发送"含管道缓冲，会高估实际落地字节，直接当偏移会造成数据空洞，见审查 R1）。
enum UploadOutcome: Equatable { case completed, cancelled, paused, failed(String) }

/// 文件浏览的加载状态。
enum LoadPhase: Equatable { case loading, loaded, error(String) }

/// 一个远程目录条目。
struct RemoteFile: Identifiable, Hashable {
    enum Kind { case directory, file, symlink, other }
    let name: String
    let path: String          // 绝对路径
    let kind: Kind
    let size: Int64
    let modified: Date?
    var id: String { path }
    var isDir: Bool { kind == .directory }
}

/// 远程文件系统：优先 SFTP，必要时使用独立 SSH exec 通道。
/// 两种操作均经 SSHSessionPool 共享认证传输，不启动本机 ssh 子进程。
final class RemoteFS {
    private let ssh: SSHConnection
    private let sftpStore: RemoteSFTPStore<SFTPSession>

    init(_ ssh: SSHConnection) {
        self.ssh = ssh
        sftpStore = RemoteSFTPStore(create: { SFTPSession(ssh) }, retire: { session in
            Task { await session.shutdown() }
        })
    }

    /// Release this filesystem's operation channel without disconnecting other SSH features.
    func closeSession() { sftpStore.close() }

    /// Network recovery clears fallback state; the next operation lazily creates a new session.
    func resetForReconnect() { sftpStore.reset() }

    struct OpResult { let data: Data; let stderr: Data; let code: Int32 }

    /// 执行一条远端命令（经登录 shell）。流式抽干管道，避免大输出时缓冲区填满导致死锁。
    /// `stdin` 非空时写入子进程标准输入（用于写文件等大数据下行）。
    func run(_ remoteCommand: String, stdin: Data? = nil, timeout: Double = 20,
             handle: CommandHandle? = nil) async -> OpResult {
        let conn = ssh
        return await withCheckedContinuation { (cont: CheckedContinuation<OpResult, Never>) in
            DispatchQueue.global().async {
                let pool = SSHSessionPool.shared
                let s: SSHSession
                do { s = try pool.acquireOperation(for: conn) }      // 独立操作句柄，共享已认证传输
                catch {
                    let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "连接失败")
                    cont.resume(returning: OpResult(data: Data(), stderr: Data(msg.utf8), code: -1))
                    return
                }
                defer { s.close() }
                handle?.bind(s)                     // 绑定取消句柄：用户取消 → s.cancel() 中断 exec 循环
                do {
                    let r = try s.execBytes(remoteCommand, stdin: stdin, timeout: timeout)
                    let code = (r.timedOut || r.cancelled) ? -1 : r.exitCode
                    cont.resume(returning: OpResult(data: r.stdout, stderr: r.stderr, code: code))
                } catch {
                    let msg = (error as? SSHSession.SSHError)?.message ?? String(localized: "执行失败")
                    cont.resume(returning: OpResult(data: Data(), stderr: Data(msg.utf8), code: -1))
                }
            }
        }
    }

    // MARK: - 上传（.part 落地 + 续写 + 取消）

    /// 探测远端：.part 半截大小（续传偏移）、正式文件是否存在/大小（同名询问）。
    func probeUpload(remotePath: String) async throws -> UploadProbe {
        if let sftp = sftpStore.acquire() {
            do {
                return try await UploadPreflight.read(path: remotePath) { try await sftp.lstat($0) }
            } catch let error as SFTPError where error.isTransport {
                sftpStore.markUnavailable(ifCurrent: sftp)
            } catch let error as SFTPError {
                throw RemoteFSError(message: error.isPermission ? String(localized: "没有读取目标文件状态的权限。") : error.message)
            }
        }
        let result = await run(UploadPreflight.shellCommand(path: remotePath), timeout: 20)
        guard result.code == 0 else {
            throw Self.shellErr(result, String(localized: "无法确认远端文件状态，上传已停止。"))
        }
        return try UploadPreflight.parse(result.data)
    }

    /// 提交已传完的文件。仅明确不支持覆盖扩展时切换 shell；失败或未知结果不重放。
    func finalizeUpload(_ request: UploadCommit) async -> Result<Void, RemoteFSError> {
        if let sftp = sftpStore.acquire() {
            do {
                switch try await UploadFinalizer.commit(request, using: sftp) {
                case .committed: return .success(())
                case .unsupportedOverwrite: break
                }
            } catch let error as RemoteFSError {
                return .failure(error)
            } catch let error as SFTPError {
                if error.isTransport { sftpStore.markUnavailable(ifCurrent: sftp) }
                return .failure(RemoteFSError(message: error.isTransport
                    ? String(localized: "提交时连接中断，结果尚未确认，请检查远端文件后重试。")
                    : error.message))
            } catch {
                return .failure(RemoteFSError(message: error.localizedDescription))
            }
        }
        let result = await run(UploadShellCommands.finalize(request), timeout: 30)
        switch result.code {
        case 0: return .success(())
        case 9: return .failure(UploadFinalizer.invalidPartial())
        case 10: return .failure(UploadFinalizer.invalidTarget())
        case 11: return .failure(UploadFinalizer.targetExists())
        default: return .failure(Self.shellErr(result,
            String(localized: "文件提交未确认，请检查远端文件后重试。")))
        }
    }

    /// Best-effort cleanup, still a single mutation: a lost reply never triggers a second delete.
    func cleanupPart(remotePath: String) async {
        _ = await mutate(.remove(remotePath + ".part", recursive: false))
    }

    // MARK: - 新建 / 下载

    func mkdir(_ path: String) async -> Result<Void, RemoteFSError> {
        await mutate(.createDirectory(path))
    }

    func createFile(_ path: String) async -> Result<Void, RemoteFSError> {
        await mutate(.createFile(path))
    }

    /// Streams into a task-owned destination; the task retains it across pause and discards it on failure.
    /// Each operation captures its SFTP session once so handle cleanup always uses the session that opened it.
    func download(_ remotePath: String, to destination: DownloadDestination, control: UploadControl) async -> UploadOutcome {
        guard let sftp = sftpStore.acquire() else { return .failed(String(localized: "需要 SFTP 连接")) }
        do {
            return try await DownloadStream.run(path: remotePath, source: sftp, sink: destination, control: control)
        } catch let error as SFTPError where error.isTransport {
            sftpStore.markUnavailable(ifCurrent: sftp); return .failed(String(localized: "连接中断"))
        } catch let error as SFTPError {
            return .failed(error.isPermission ? String(localized: "没有读取权限") : error.message)
        } catch let error as RemoteFSError {
            return .failed(error.message)
        } catch {
            return .failed(String(localized: "下载失败：\(error.localizedDescription)"))
        }
    }

    private static func shellErr(_ r: OpResult, _ fallback: String) -> RemoteFSError {
        let err = String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RemoteFSError(message: err.isEmpty ? fallback : err)
    }

    /// Both transports use the same version-pinned local source; a failed operation is never auto-replayed.
    func upload(source: UploadSource, toRemote remotePath: String,
                startOffset: Int64, control: UploadControl) async -> UploadOutcome {
        if let sftp = sftpStore.acquire() {
            do {
                return try await UploadStream.run(source: source, destination: sftp, path: remotePath,
                                                  startOffset: startOffset, control: control)
            } catch let error as SFTPError where error.isTransport {
                sftpStore.markUnavailable(ifCurrent: sftp); return .failed(String(localized: "连接中断"))
            } catch let error as SFTPError {
                return .failed(error.isPermission ? String(localized: "没有写入权限") : error.message)
            } catch let error as RemoteFSError {
                return .failed(error.message)
            } catch {
                return .failed(String(localized: "上传失败：\(error.localizedDescription)"))
            }
        }
        if let stopped = UploadStream.interruption(control) { return stopped }
        let conn = ssh
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let session = try SSHSessionPool.shared.acquireOperation(for: conn)
                    defer { session.close() }
                    let outcome = UploadShellStream.run(source: source, path: remotePath,
                                                       startOffset: startOffset, control: control) { command, pull in
                        try session.execUpload(command, pull: pull)
                    }
                    continuation.resume(returning: outcome)
                } catch {
                    continuation.resume(returning: .failed(
                        (error as? SSHSession.SSHError)?.message ?? String(localized: "无法连接")))
                }
            }
        }
    }

    // MARK: - 文件管理（删除 / 重命名 / 权限）

    /// Recursive deletion uses a cancellable exec channel; other mutations prefer SFTP.
    private func mutate(_ operation: RemoteFileMutation, handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        guard handle?.isCancelled != true else {
            return .failure(RemoteFSError(message: String(localized: "已取消")))
        }
        let sftp = operation.usesSFTP ? sftpStore.acquire() : nil
        return await operation.perform(
            using: sftp,
            shell: { await self.run($0, handle: handle) },
            didLoseSFTP: {
                if let sftp { self.sftpStore.markUnavailable(ifCurrent: sftp) }
            })
    }

    func delete(_ path: String, isDir: Bool, handle: CommandHandle? = nil) async -> Result<Void, RemoteFSError> {
        await mutate(.remove(path, recursive: isDir), handle: handle)
    }

    func rename(_ from: String, to: String) async -> Result<Void, RemoteFSError> {
        await mutate(.rename(from: from, to: to))
    }

    func chmod(_ path: String, mode: String) async -> Result<Void, RemoteFSError> {
        guard let permissions = FilePermissionMode(mode) else {
            return .failure(RemoteFSError(message: String(localized: "权限值无效")))
        }
        return await mutate(.permissions(path, permissions))
    }

    /// 取当前权限（八进制低 12 位，含 setuid/setgid/sticky）。
    func statPerms(_ path: String) async -> Result<Int, RemoteFSError> {
        if let sftp = sftpStore.acquire() {
            do {
                guard let p = (try await sftp.stat(path)).permissions else {
                    return .failure(RemoteFSError(message: String(localized: "无法读取权限")))
                }
                return .success(Int(p & 0o7777))
            }
            catch let e as SFTPError where e.isTransport { sftpStore.markUnavailable(ifCurrent: sftp) }
            catch { return .failure(RemoteFSError(message: String(localized: "无法读取权限"))) }
        }
        return await statPermsViaShell(path)
    }
    private func statPermsViaShell(_ path: String) async -> Result<Int, RemoteFSError> {
        let cmd = "\(RemoteShellPath.assign(path)); stat -c '%a' \"$P\" 2>/dev/null || stat -f '%Lp' \"$P\" 2>/dev/null"
        let r = await run(cmd)
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard r.code == 0, let v = Int(s, radix: 8) else {
            return .failure(RemoteFSError(message: String(localized: "无法读取权限")))
        }
        return .success(v)
    }

    /// 登录用户的家目录绝对路径。
    func home() async -> String {
        if let sftp = sftpStore.acquire() {
            do { let p = try await sftp.realpath("."); return p.isEmpty ? "/" : p }
            catch let e as SFTPError where e.isTransport { sftpStore.markUnavailable(ifCurrent: sftp) }
            catch { /* 业务级失败：退到 shell */ }
        }
        return await homeViaShell()
    }
    private func homeViaShell() async -> String {
        let r = await run("cd && pwd")
        let s = String(data: r.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "/" : s
    }

    func list(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        if let sftp = sftpStore.acquire() {
            do { return .success(try await RemoteDirectoryListing.read(path, using: sftp)) }
            catch let e as SFTPError where e.isTransport { sftpStore.markUnavailable(ifCurrent: sftp) }
            catch let e as SFTPError {
                return .failure(RemoteFSError(message: e.isNoSuchFile ? String(localized: "目录不存在")
                    : (e.isPermission ? String(localized: "没有访问权限") : e.message)))
            }
            catch let error as RemoteFSError { return .failure(error) }
            catch { return .failure(RemoteFSError(message: String(localized: "列目录失败"))) }
        }
        return await listViaShell(path)
    }

    private func listViaShell(_ path: String) async -> Result<[RemoteFile], RemoteFSError> {
        let result = await run(RemoteDirectoryListing.shellCommand(path: path))
        guard result.code == 0 else {
            return .failure(Self.shellErr(result, String(localized: "无法列出目录，请刷新后重试。")))
        }
        do { return .success(try RemoteDirectoryListing.parse(result.data, directory: path)) }
        catch let error as RemoteFSError { return .failure(error) }
        catch { return .failure(RemoteDirectoryListing.invalidResponse()) }
    }

}

/// 把字节数格式化为人类可读（用于文件大小显示）。
func humanSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "—" }
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(bytes); var i = 0
    while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(bytes) B" : String(format: "%.1f%@", v, units[i])
}
