import Foundation
import TermoCore

/// 一个认证身份共用一条 SSH 传输，每次借用得到独立可取消的操作句柄。
/// 监控、终端、SFTP 与短命令都持有自己的引用，旧连接的迟到归还不影响新连接。
public final class SSHConnectionHub: @unchecked Sendable {
    private let environment: SSHConnectionEnvironment
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var retired = false
    private var session: SSHSession?
    private var users = 0
    private var idleWork: DispatchWorkItem?
    private var idleEpoch = 0

    public init(environment: SSHConnectionEnvironment) {
        self.environment = environment
    }

    private var isRetired: Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return retired
    }

    /// 网络切换时先同步作废入口，避免旧驱动在后台重建已移出注册表的连接。
    public func retire() {
        lifecycleLock.lock(); retired = true; lifecycleLock.unlock()
    }

    public var hasLiveSession: Bool {
        // 连接期间不能阻塞主线程的 UI 状态查询。
        guard lock.try() else { return false }
        defer { lock.unlock() }
        return !isRetired && (session.map { !$0.isPoisoned } ?? false)
    }

    /// 同步建连，仅后台调用；同一身份的并发请求合并为一次认证。
    public func acquire(_ connection: SSHConnection) throws -> SSHSession {
        lock.lock(); defer { lock.unlock() }
        guard !isRetired else { throw SSHSession.SSHError(message: String(localized: "SSH 连接已断开")) }
        idleEpoch &+= 1
        idleWork?.cancel(); idleWork = nil
        if session?.isPoisoned != false {
            session?.close()
            session = nil
            users = 0
            session = try SSHSession.connect(connection, environment: environment)
        }
        guard let session else { throw SSHSession.SSHError(message: String(localized: "SSH 连接已断开")) }
        guard !isRetired else {
            session.disconnectTransport()
            session.close()
            self.session = nil
            throw SSHSession.SSHError(message: String(localized: "SSH 连接已断开"))
        }
        let identity = session.transportID
        let operation = try session.fork { [weak self] in
            // 旧通道关闭可能与新连接认证并发；归还不能让主线程等待建连锁。
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.returned(identity) }
        }
        users += 1
        return operation
    }

    /// 通道拒绝/命令失败不应破坏其他通道；只有真正断开的传输才失效。
    public func invalidate(_ operation: SSHSession) {
        guard operation.isDisconnected else { return }
        let identity = operation.transportID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.session?.transportID == identity ? self.session : nil
            if stale != nil { self.session = nil; self.users = 0; self.idleEpoch &+= 1 }
            self.lock.unlock()
            stale?.close()
        }
    }

    private func returned(_ identity: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard session?.transportID == identity else { return }
        users -= 1
        guard users == 0 else { return }
        idleEpoch &+= 1
        let epoch = idleEpoch
        let work = DispatchWorkItem { [weak self] in self?.closeIfIdle(epoch: epoch) }
        idleWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: work)
    }

    /// 仅回收空闲缓存；有监控/终端/文件操作时保持共享传输。
    public func closeIfIdle(epoch: Int? = nil) {
        lock.lock()
        guard users == 0, epoch == nil || epoch == idleEpoch else { lock.unlock(); return }
        let old = session
        session = nil
        idleEpoch &+= 1
        idleWork?.cancel(); idleWork = nil
        lock.unlock()
        old?.close()
    }

    public func disconnect() {
        lock.lock()
        let old = session
        session = nil; users = 0; idleEpoch &+= 1
        idleWork?.cancel(); idleWork = nil
        lock.unlock()
        old?.disconnectTransport()
        old?.close()
    }

    deinit { idleWork?.cancel(); session?.close() }
}
