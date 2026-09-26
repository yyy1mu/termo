import XCTest
@testable import Termo
import TermoCore

@MainActor
final class HostMonitoringServiceTests: XCTestCase {
    private func host(_ id: String = "a", password: String = "fixture", enabled: Bool? = nil) -> Termo.Host {
        var ssh = SSHConnection(host: "\(id).invalid")
        ssh.password = password
        ssh.monitoringEnabled = enabled
        return Termo.Host(id: id, name: id, addr: ssh.host, group: "", status: .offline, os: "linux", ssh: ssh)
    }

    private func service(onAlert: @escaping (String, ResourceAlert) -> Void = { _, _ in }) -> HostMonitoringService<MonitorSpy> {
        HostMonitoringService(makeMonitor: MonitorSpy.init, alertsEnabled: true, onAlert: onAlert)
    }

    func testViewingHostCreatesSamplerWithoutStartingItAndReusesIdentity() {
        let service = service()
        let machine = host()
        let monitor = service.monitor(for: machine)
        XCTAssertTrue(monitor === service.monitor(for: machine))
        XCTAssertEqual(monitor.events, [])
        XCTAssertFalse(monitor.isEnabled)
    }

    func testMissingPasswordAndExplicitDisableNeverStartSampling() {
        let service = service()
        service.ensureMonitoring(host(password: ""))
        let monitor = service.monitor(for: host())
        XCTAssertEqual(monitor.events, ["stop", "update"])
        service.ensureMonitoring(host(enabled: false))
        XCTAssertEqual(monitor.events, ["stop", "update", "stop", "update"])
        XCTAssertFalse(monitor.isEnabled)
        service.ensureMonitoring(host()) // absent flag retains default enabled behavior
        XCTAssertEqual(monitor.events.suffix(2), ["update", "start"])
        XCTAssertTrue(monitor.isEnabled)
    }

    func testClosingLastWorkspaceKeepsRunningMonitorButReleasesStoppedOne() {
        let service = service()
        let machine = host()
        service.ensureMonitoring(machine)
        let original = service.monitor(for: machine)
        service.releaseIfUnused(hostID: machine.id, hasOpenWorkspace: false)
        XCTAssertTrue(original === service.monitor(for: machine))
        service.stop(hostID: machine.id)
        service.releaseIfUnused(hostID: machine.id, hasOpenWorkspace: true)
        XCTAssertTrue(original === service.monitor(for: machine))
        service.releaseIfUnused(hostID: machine.id, hasOpenWorkspace: false)
        XCTAssertFalse(original === service.monitor(for: machine))
        XCTAssertNil(original.onSample)
    }

    func testSyncStopsBeforeUpdatingCredentialsAndRestartsOnlyAfterExplicitRefresh() {
        let service = service()
        let original = host()
        service.ensureMonitoring(original)
        let monitor = service.monitor(for: original)
        service.applyPersistedHosts([host(password: "replacement")])
        XCTAssertEqual(monitor.events.suffix(2), ["stop", "update"])
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertEqual(monitor.connection.password, "replacement")
        service.refresh(host(password: "replacement"), hasOpenWorkspace: false)
        XCTAssertTrue(monitor.isEnabled)
        XCTAssertEqual(monitor.events.suffix(2), ["update", "start"])
    }

    func testSyncRemovingSSHConfigurationStopsAndDropsExistingSampler() {
        let service = service()
        var machine = host()
        service.ensureMonitoring(machine)
        let old = service.monitor(for: machine)
        machine.ssh = nil
        service.applyPersistedHosts([machine])
        XCTAssertFalse(old.isEnabled)
        XCTAssertNil(old.onSample)
        XCTAssertFalse(old === service.monitor(for: host()))
    }

    func testRefreshingUnusedHostDoesNotCreateSampler() {
        var created = 0
        let service = HostMonitoringService(makeMonitor: { connection in
            created += 1
            return MonitorSpy(connection)
        }, alertsEnabled: true, onAlert: { _, _ in })
        service.refresh(host(), hasOpenWorkspace: false)
        service.applyPersistedHosts([host()])
        XCTAssertEqual(created, 0)
        service.refresh(host(), hasOpenWorkspace: true)
        XCTAssertEqual(created, 1)
    }

    func testRemovedHostCannotDeliverLateSampleEvenIfIDIsReused() {
        var notifications: [String] = []
        let service = service { id, _ in notifications.append(id) }
        let machine = host()
        service.ensureMonitoring(machine)
        let old = service.monitor(for: machine)
        let lateCallback = old.onSample
        service.applyPersistedHosts([])
        XCTAssertFalse(old.isEnabled)
        XCTAssertNil(old.onSample)
        service.ensureMonitoring(machine)
        for _ in 0..<15 { lateCallback?(HostMetrics(cpuPercent: 99)) }
        XCTAssertTrue(notifications.isEmpty)
        for _ in 0..<15 { service.monitor(for: machine).onSample?(HostMetrics(cpuPercent: 99)) }
        XCTAssertEqual(notifications, [machine.id])
    }

    func testNetworkAndAlertToggleResetPendingStreaks() {
        var alerts = 0
        let service = service { _, _ in alerts += 1 }
        let machine = host()
        service.ensureMonitoring(machine)
        let monitor = service.monitor(for: machine)
        for _ in 0..<14 { monitor.onSample?(HostMetrics(cpuPercent: 95)) }
        service.handleNetworkChange()
        XCTAssertEqual(monitor.events.last, "network")
        monitor.onSample?(HostMetrics(cpuPercent: 95))
        XCTAssertEqual(alerts, 0)
        for _ in 0..<13 { monitor.onSample?(HostMetrics(cpuPercent: 95)) }
        service.setAlertsEnabled(false)
        for _ in 0..<30 { monitor.onSample?(HostMetrics(cpuPercent: 95)) }
        service.setAlertsEnabled(true)
        monitor.onSample?(HostMetrics(cpuPercent: 95))
        XCTAssertEqual(alerts, 0)
        for _ in 0..<14 { monitor.onSample?(HostMetrics(cpuPercent: 95)) }
        XCTAssertEqual(alerts, 1)
    }

    func testTrustRetryIsExplicitAndAffectsOnlyRequestedHost() {
        let service = service()
        service.ensureMonitoring(host("a"))
        service.ensureMonitoring(host("b"))
        let other = service.monitor(for: host("b"))
        let previous = other.events
        service.ensureMonitoring(host("a"), allowTrustRetry: true)
        XCTAssertEqual(service.monitor(for: host("a")).events.last, "retry-trust")
        XCTAssertEqual(other.events, previous)
        service.remove(hostID: "a")
        XCTAssertTrue(other.isEnabled)
    }
}

@MainActor
private final class MonitorSpy: HostMonitoring {
    var isEnabled = false
    var onSample: ((HostMetrics) -> Void)?
    private(set) var connection: SSHConnection
    private(set) var events: [String] = []
    init(_ connection: SSHConnection) { self.connection = connection }
    func updateConnection(_ connection: SSHConnection) { events.append("update"); self.connection = connection }
    func start(allowTrustRetry: Bool) { events.append(allowTrustRetry ? "retry-trust" : "start"); isEnabled = true }
    func stop() { events.append("stop"); isEnabled = false }
    func handleNetworkChange() { events.append("network") }
}
