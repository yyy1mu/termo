import Network
import Foundation

/// 全局网络可达性监听。网络切换（WiFi 互换、有线无线切换、断网恢复）时 NWPathMonitor 在系统层面
/// 立即感知，用来主动触发监控重连，而不必干等 SSH keepalive 超时（约十几秒）。
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true
    /// 网络发生实质变化时回调，参数为当前是否在线。
    var onChange: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var lastKey = ""

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            // 指纹取「是否在线 + 可用网卡名集合」，仅在实质变化时通知，避免抖动重复触发。
            let key = "\(online)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in self?.apply(online: online, key: key) }
        }
        monitor.start(queue: DispatchQueue(label: "com.termo.netpath"))
    }

    private func apply(online: Bool, key: String) {
        guard key != lastKey else { return }
        let first = lastKey.isEmpty
        lastKey = key
        isOnline = online
        if !first { onChange?(online) }   // 跳过启动首帧，只在真正切换时触发
    }
}

