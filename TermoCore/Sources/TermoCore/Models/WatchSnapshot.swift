import Foundation

/// iPhone → Watch 的最小资料投影；不传输地址、用户名、密码或私钥。
public struct WatchHostSummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct WatchSnapshot: Codable, Equatable, Sendable {
    public var hosts: [WatchHostSummary]
    public var updatedAt: Date

    public init(hosts: [WatchHostSummary], updatedAt: Date = Date()) {
        self.hosts = hosts
        self.updatedAt = updatedAt
    }

    public static func from(_ profiles: [HostProfile]) -> WatchSnapshot {
        WatchSnapshot(hosts: profiles.map { WatchHostSummary(id: $0.id, name: $0.name) })
    }
}
