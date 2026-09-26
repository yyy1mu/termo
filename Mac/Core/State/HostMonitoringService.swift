import Foundation
import TermoCore

/// The lifecycle surface needed by the owner; tests substitute an in-memory sampler without SSH.
@MainActor
protocol HostMonitoring: AnyObject {
    var isEnabled: Bool { get }
    var onSample: ((HostMetrics) -> Void)? { get set }
    func updateConnection(_ connection: SSHConnection)
    func start(allowTrustRetry: Bool)
    func stop()
    func handleNetworkChange()
}

extension HostMonitor: HostMonitoring {}

/// Owns per-host samplers and alert state independently of tabs and views.
/// The concrete sampler type is preserved so SwiftUI observes HostMonitor directly.
@MainActor
final class HostMonitoringService<Monitor: HostMonitoring> {
    private struct Entry {
        let monitor: Monitor
        var connection: SSHConnection?
    }

    private var entries: [String: Entry] = [:]
    private var alerts = ResourceAlertEvaluator()
    private var alertsEnabled: Bool
    private let makeMonitor: (SSHConnection) -> Monitor
    private let now: () -> Date
    private let onAlert: (String, ResourceAlert) -> Void

    init(makeMonitor: @escaping (SSHConnection) -> Monitor, alertsEnabled: Bool,
         now: @escaping () -> Date = Date.init,
         onAlert: @escaping (String, ResourceAlert) -> Void) {
        self.makeMonitor = makeMonitor
        self.alertsEnabled = alertsEnabled
        self.now = now
        self.onAlert = onAlert
    }

    func monitor(for host: Host) -> Monitor {
        if let entry = entries[host.id] { return entry.monitor }
        let monitor = makeMonitor(host.ssh ?? SSHConnection())
        let id = host.id
        monitor.onSample = { [weak self, weak monitor] metrics in
            guard let self, let monitor, self.entries[id]?.monitor === monitor,
                  monitor.isEnabled, self.alertsEnabled else { return }
            for alert in self.alerts.evaluate(hostID: id, metrics: metrics, at: self.now()) {
                self.onAlert(id, alert)
            }
        }
        entries[id] = Entry(monitor: monitor, connection: host.ssh)
        return monitor
    }

    /// No password prompts; callers supply already-resolved credentials for this host.
    func ensureMonitoring(_ host: Host, allowTrustRetry: Bool = false) {
        guard let ssh = host.ssh else { remove(hostID: host.id); return }
        let monitor = monitor(for: host)
        let allowed = ssh.monitoringEnabled != false && (ssh.authMethod == .key || !ssh.password.isEmpty)
        if !allowed { stop(hostID: host.id) }
        if entries[host.id]?.connection != ssh { alerts.remove(hostID: host.id) }
        entries[host.id]?.connection = ssh
        monitor.updateConnection(ssh)
        if allowed { monitor.start(allowTrustRetry: allowTrustRetry) }
    }

    /// Saving unrelated hosts must not open connections to machines the user has not used.
    func refresh(_ host: Host, hasOpenWorkspace: Bool) {
        guard hasOpenWorkspace || entries[host.id] != nil else { return }
        ensureMonitoring(host)
    }

    /// Synchronization imports credentials in a later stage. Update existing samplers without reconnecting.
    func applyPersistedHosts(_ hosts: [Host]) {
        let ids = Set(hosts.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) { remove(hostID: id) }
        for host in hosts {
            guard let entry = entries[host.id] else { continue }
            guard let ssh = host.ssh else { remove(hostID: host.id); continue }
            guard entry.connection != ssh else { continue }
            stop(hostID: host.id)
            alerts.remove(hostID: host.id)
            entries[host.id]?.connection = ssh
            entry.monitor.updateConnection(ssh)
        }
    }

    func releaseIfUnused(hostID: String, hasOpenWorkspace: Bool) {
        guard !hasOpenWorkspace, entries[hostID]?.monitor.isEnabled != true else { return }
        remove(hostID: hostID)
    }

    func stop(hostID: String) {
        entries[hostID]?.monitor.stop()
        alerts.resetSampling(hostID: hostID)
    }

    func remove(hostID: String) {
        let monitor = entries.removeValue(forKey: hostID)?.monitor
        monitor?.onSample = nil
        monitor?.stop()
        alerts.remove(hostID: hostID)
    }

    func handleNetworkChange() {
        alerts.resetSampling()
        for entry in entries.values { entry.monitor.handleNetworkChange() }
    }

    func setAlertsEnabled(_ enabled: Bool) {
        guard alertsEnabled != enabled else { return }
        alertsEnabled = enabled
        alerts.resetSampling()
    }
}
