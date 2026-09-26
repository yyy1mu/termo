import Foundation
import CTermoSSH
import TermoEngine
import TermoCore

/// 一台主机的密钥指纹信息（用于首次连接验证弹窗）。
struct HostKeyInfo {
    let host: String
    let port: Int
    let keyLine: String   // known_hosts 行（"<host|[host]:port> <keytype> <base64key>"），用于写入信任
    let sha256: String
    let md5: String
    var changed = false    // true=已有记录但密钥变了（疑似 MITM），弹窗需醒目警示
}

enum HostKeyDecision { case cancel, once, save }

/// 基于 SSH 引擎的主机密钥验证（替代旧的 ssh-keyscan / ssh-keygen 子进程）。
/// known_hosts 用「真实文件 + 本次会话临时文件」两份：信任并保存写真实文件，仅本次写临时文件（重启即失效）。
/// 实际连接由 `SSHSession.connect` 在认证前强制核对 known_hosts，仅匹配才继续；
/// 本类负责连接前的「首次未知/已变更」交互式确认。
enum HostKeyVerifier {
    enum Preflight { case known, prompt(HostKeyInfo), changed(HostKeyInfo), scanFailed }

    static var realKnownHosts: String { NSHomeDirectory() + "/.ssh/known_hosts" }
    static var sessionKnownHosts: String { NSHomeDirectory() + "/.termo/session_known_hosts" }

    /// App 启动时清空会话临时文件（让「仅本次」在重启后重新验证）。
    static func resetSession() {
        ensureParentDir(sessionKnownHosts)
        try? Data().write(to: URL(fileURLWithPath: sessionKnownHosts))
    }

    /// Only handshakes; no credentials are sent. Task cancellation reaches the engine,
    /// and the detached call retains its token until socket cleanup has completed.
    static func preflight(connection: SSHConnection,
                          cancellation: SSHConnectionCancellation = SSHConnectionCancellation()) async -> Preflight {
        guard (1...65535).contains(connection.port), !connection.host.isEmpty,
              let options = try? SSHTransportOptions(connection) else { return .scanFailed }
        return await withTaskCancellationHandler {
            await Task.detached {
                scan(connection: connection, options: options, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func scan(connection: SSHConnection, options: SSHTransportOptions,
                             cancellation: SSHConnectionCancellation) -> Preflight {
        var scan = TermoHostKeyScan()
        options.withRawOptions { rawOptions in
            termo_ssh_scan_hostkey(connection.host, Int32(connection.port), realKnownHosts,
                                   sessionKnownHosts, cancellation.handle, rawOptions, &scan)
        }
        switch scan.status {
        case 0:  return .known
        case 1:  return info(connection.host, connection.port, scan).map { .prompt($0) } ?? .scanFailed
        case 2:  return info(connection.host, connection.port, scan).map { var i = $0; i.changed = true; return .changed(i) } ?? .scanFailed
        default: return .scanFailed   // -1：连接/握手失败，交给后续实际连接报错
        }
    }

    private static let writeLock = NSLock()

    /// 保留既有信任记录，原子追加；写入失败必须告知调用方，不能假装信任已保存。
    static func trust(_ info: HostKeyInfo, persist: Bool,
                      realPath: String = realKnownHosts, sessionPath: String = sessionKnownHosts) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        let line = info.keyLine.trimmingCharacters(in: .newlines)
        guard !line.isEmpty, !line.contains(where: \.isNewline) else {
            throw SSHSession.SSHError(message: String(localized: "主机指纹记录无效，未保存信任。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        let url = URL(fileURLWithPath: persist ? realPath : sessionPath)
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

    private static func info(_ host: String, _ port: Int, _ scan: TermoHostKeyScan) -> HostKeyInfo? {
        let line = cstr(scan.line)
        guard !line.isEmpty else { return nil }
        return HostKeyInfo(host: host, port: port, keyLine: line,
                           sha256: cstr(scan.sha256), md5: cstr(scan.md5))
    }

    /// C 定长 char 数组（导入为 Swift 元组）→ String。
    private static func cstr<T>(_ tuple: T) -> String {
        var t = tuple
        return withUnsafeBytes(of: &t) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func ensureParentDir(_ path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
}
