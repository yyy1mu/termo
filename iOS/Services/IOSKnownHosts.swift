import Foundation

/// iOS 端 known_hosts 路径约定：应用容器内 Application Support/Termo/。
/// 与 macOS 的「真实文件 + 本会话临时文件」双文件语义一致，供后续 SSH 连接功能
/// 经 SSHConnectionEnvironment 显式注入 TermoEngine。
enum IOSKnownHosts {
    /// 持久信任记录（对应 macOS 的 ~/.ssh/known_hosts）。
    static var real: String { directory.appendingPathComponent("known_hosts").path }
    /// 本会话临时信任（重启即失效，对应 macOS 的 ~/.termo/session_known_hosts）。
    static var session: String { directory.appendingPathComponent("session_known_hosts").path }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Termo", isDirectory: true)
    }
}
