import Foundation
import TermoCore
import WatchConnectivity

/// 保存 iPhone 发来的最新无凭证快照；离线时仍可展示上次收到的主机名称。
final class WatchHostInbox: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot: WatchSnapshot?
    private let cacheKey = "lastWatchHostSnapshot"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: cacheKey) {
            snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        accept(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        accept(applicationContext)
    }

    private func accept(_ context: [String: Any]) {
        guard let data = context["hosts"] as? Data,
            let decoded = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return }
        DispatchQueue.main.async {
            self.snapshot = decoded
            UserDefaults.standard.set(data, forKey: self.cacheKey)
        }
    }
}
