import CTermoSSH
import Foundation
import TermoCore
import TermoEngine

/// 一台主机的密钥指纹信息（用于首次连接确认弹窗）。
struct IOSHostKeyInfo {
    let host: String
    let port: Int
    let keyLine: String   // known_hosts 行（"<host|[host]:port> <keytype> <base64key>"），用于写入信任
    let sha256: String
    let md5: String
    var changed = false    // true=已有记录但密钥变了（疑似 MITM），弹窗需醒目警示
}

/// 基于 SSH 引擎的主机密钥验证（与 macOS HostKeyVerifier 同一 russh 后端）。
/// iOS 简化：信任确认一律写入持久 known_hosts（不用会话临时文件）；
/// 引擎在实际连接时仍会强制核对 known_hosts，仅明确匹配才继续认证。
enum IOSHostKeyVerifier {
    enum Preflight {
        case known, prompt(IOSHostKeyInfo), changed(IOSHostKeyInfo), scanFailed
    }

    /// 仅握手不认证；扫描在后台线程执行（阻塞调用），取消经 cancellation 传入引擎。
    static func preflight(
        connection: SSHConnection,
        cancellation: SSHConnectionCancellation = SSHConnectionCancellation()
    ) async -> Preflight {
        guard (1...65535).contains(connection.port), !connection.host.isEmpty,
              let options = try? SSHTransportOptions(connection) else { return .scanFailed }
        return await withTaskCancellationHandler {
            await Task.detached {
                scan(connection: connection, options: options, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func scan(
        connection: SSHConnection, options: SSHTransportOptions,
        cancellation: SSHConnectionCancellation
    ) -> Preflight {
        var scan = TermoHostKeyScan()
        options.withRawOptions { rawOptions in
            termo_ssh_scan_hostkey(connection.host, Int32(connection.port),
                                   IOSKnownHosts.real, IOSKnownHosts.session,
                                   cancellation.handle, rawOptions, &scan)
        }
        switch scan.status {
        case 0:  return .known
        case 1:  return info(connection.host, connection.port, scan).map { .prompt($0) } ?? .scanFailed
        case 2:  return info(connection.host, connection.port, scan).map { var i = $0; i.changed = true; return .changed(i) } ?? .scanFailed
        default: return .scanFailed   // -1：连接/握手失败，交给后续实际连接报错
        }
    }

    /// 扫描失败时的病因诊断：跑引擎分阶段测试，取第一个失败阶段的消息（如 TCP 不通/握手失败）。
    /// 仅用于把「无法核对主机指纹」细化成可操作的错误文案。
    static func diagnose(connection: SSHConnection) -> String? {
        guard let options = try? SSHTransportOptions(connection) else { return nil }
        final class Box { var message: String? }
        let box = Box()
        // 必须显式绑定：临时量的 deinit 会 free token，内联传 .handle 会被 ARC 提前释放
        let cancellation = SSHConnectionCancellation()
        options.withRawOptions { rawOptions in
            termo_ssh_test(
                connection.host, Int32(connection.port), connection.user,
                nil, nil, nil,
                IOSKnownHosts.real, IOSKnownHosts.session,
                cancellation.handle, rawOptions,
                { userdata, _, ok, message in
                    guard ok == 0, let userdata, let message else { return }
                    Unmanaged<Box>.fromOpaque(userdata).takeUnretainedValue()
                        .message = String(cString: message)
                },
                Unmanaged.passUnretained(box).toOpaque())
        }
        return box.message
    }

    private static let writeLock = NSLock()

    /// 保留既有信任记录，原子追加到持久 known_hosts。
    static func trust(_ info: IOSHostKeyInfo, path: String = IOSKnownHosts.real) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let line = info.keyLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty, !line.contains(where: \.isNewline) else {
            throw SSHSession.SSHError(message: String(localized: "主机指纹记录无效，未保存信任。"))
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content: String
        do { content = try String(contentsOf: url, encoding: .utf8) }
        catch CocoaError.fileReadNoSuchFile { content = "" }
        if content.components(separatedBy: .newlines).contains(line) { return }
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 内部

    private static func info(_ host: String, _ port: Int, _ scan: TermoHostKeyScan) -> IOSHostKeyInfo? {
        let line = cstr(scan.line)
        guard !line.isEmpty else { return nil }
        return IOSHostKeyInfo(host: host, port: port, keyLine: line,
                              sha256: cstr(scan.sha256), md5: cstr(scan.md5))
    }

    /// C 定长 char 数组（导入为 Swift 元组）→ String。
    private static func cstr<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafeBytes(of: &t) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
