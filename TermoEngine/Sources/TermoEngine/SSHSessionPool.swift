import Foundation
import TermoCore

/// 统一连接入口：借用独立操作句柄，底层认证连接按身份共享。
/// `shared` 单例由各平台 App 侧装配注入（见 Mac 的 SSHEngineEnvironment.swift），引擎不持有全局状态。
public final class SSHSessionPool {
    private let makeHub: () -> SSHConnectionHub

    public init(makeHub: @escaping () -> SSHConnectionHub) {
        self.makeHub = makeHub
    }
    private var hubs: [SSHConnectionReuseKey: SSHConnectionHub] = [:]
    private let lock = NSLock()

    public func connectionHub(for connection: SSHConnection) -> SSHConnectionHub {
        let key = SSHConnectionReuseKey(connection)
        lock.lock(); defer { lock.unlock() }
        if let hub = hubs[key] { return hub }
        let hub = makeHub()
        hubs[key] = hub
        return hub
    }

    public func hasLiveSession(_ connection: SSHConnection) -> Bool {
        existingHub(for: connection)?.hasLiveSession ?? false
    }

    public func withSession<T>(_ connection: SSHConnection, _ body: (SSHSession) throws -> T) throws -> T {
        let operation = try acquireOperation(for: connection)
        defer { operation.close() }
        return try body(operation)
    }

    /// 调用方拥有独立操作句柄，结束时 close；共享传输仍由 Hub 管理。
    public func acquireOperation(for connection: SSHConnection) throws -> SSHSession {
        try connectionHub(for: connection).acquire(connection)
    }

    /// 只回收已有的空闲传输；状态查询和收尾不能创建新的连接条目。
    public func closeIdleConnection(for connection: SSHConnection) {
        guard let hub = existingHub(for: connection) else { return }
        DispatchQueue.global(qos: .utility).async { hub.closeIfIdle() }
    }

    private func existingHub(for connection: SSHConnection) -> SSHConnectionHub? {
        let key = SSHConnectionReuseKey(connection)
        lock.lock()
        defer { lock.unlock() }
        return hubs[key]
    }

    /// 网络切换/退出时作废所有传输；正常停止某个功能仅 close 其操作句柄。
    public func closeAll() {
        lock.lock()
        let all = Array(hubs.values)
        all.forEach { $0.retire() }
        hubs.removeAll()
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { all.forEach { $0.disconnect() } }
    }
}
