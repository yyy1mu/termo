import Foundation
import TermoCore
import WatchConnectivity

/// 仅传无凭证的主机名称快照；离线时系统会在配对设备可用后交付最新状态。
final class IOSWatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    private var latest = WatchSnapshot(hosts: [])

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(hosts: [HostProfile]) {
        latest = .from(hosts)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
            WCSession.default.isPaired, WCSession.default.isWatchAppInstalled
        else { return }
        do {
            let data = try JSONEncoder().encode(latest)
            try WCSession.default.updateApplicationContext(["hosts": data])
        } catch {
            // Watch 同步是附加投影；不影响 iPhone 本地主机资料的保存。
        }
    }

    func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async { self.sendLatestIfAvailable() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.sendLatestIfAvailable() }
    }

    private func sendLatestIfAvailable() {
        guard WCSession.default.activationState == .activated,
            WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
            let data = try? JSONEncoder().encode(latest)
        else { return }
        try? WCSession.default.updateApplicationContext(["hosts": data])
    }
}
