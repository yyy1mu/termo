import Foundation

/// 跨设备可共享的主机连接资料。认证凭证不属于该模型。
public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        hostname: String,
        port: Int = 22,
        username: String
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
    }
}
