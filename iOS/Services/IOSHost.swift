import Foundation
import TermoCore

/// iOS 主机：完整 SSH 连接配置。密码不进 JSON（SSHConnection 的 CodingKeys 已排除），
/// 由 IOSHostRepository 在保存/加载时与设备钥匙串（IOSKeychain）同步。
struct IOSHost: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var ssh: SSHConnection

    init(id: String = UUID().uuidString, name: String, ssh: SSHConnection) {
        self.id = id
        self.name = name
        self.ssh = ssh
    }

    /// 投影为无凭证的 Watch/列表快照资料。
    var profile: HostProfile {
        HostProfile(id: id, name: name, hostname: ssh.host, port: ssh.port, username: ssh.user)
    }

    /// 旧版 hosts-ios.json（[HostProfile]，无凭证字段）迁移：认证方式置「每次询问」，
    /// 首次连接时弹密码，不伪造任何凭证。
    init(legacy profile: HostProfile) {
        self.init(
            id: profile.id, name: profile.name,
            ssh: SSHConnection(
                user: profile.username, host: profile.hostname, port: profile.port,
                authMethod: .ask))
    }
}
