import XCTest
@testable import Termo

@MainActor
final class HostMonitorSamplingTests: XCTestCase {
    private func frame(uptime: Int, interfaces: [(String, UInt64, UInt64)], gpus: [String] = []) -> String {
        (["UP \(uptime)"]
            + interfaces.map { "NET \($0.0) \($0.1) \($0.2)" }
            + gpus).joined(separator: "\n")
    }

    func testEachInterfaceAndAggregateUseTheirOwnCounterDeltas() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse(frame(uptime: 10, interfaces: [("eth0", 1_000, 2_000), ("wlan0", 5_000, 8_000)]))
        XCTAssertNil(monitor.metrics?.netRxBytesPerSec)
        XCTAssertEqual(monitor.metrics?.interfaces.count, 2)

        monitor.parse(frame(uptime: 12, interfaces: [("eth0", 1_200, 2_100), ("wlan0", 5_600, 8_200)]))
        XCTAssertEqual(monitor.metrics?.netRxBytesPerSec, 400)
        XCTAssertEqual(monitor.metrics?.netTxBytesPerSec, 150)
        XCTAssertEqual(monitor.metrics?.interfaces.first(where: { $0.name == "eth0" })?.rxBytesPerSec, 100)
        XCTAssertEqual(monitor.metrics?.interfaces.first(where: { $0.name == "wlan0" })?.txBytesPerSec, 100)
        XCTAssertEqual(monitor.netHistoryByInterface["eth0"]?.count, 1)
        XCTAssertEqual(monitor.netHistoryByInterface["wlan0"]?.count, 1)
    }

    func testHotplugAndCounterResetDoNotSpikeAggregate() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse(frame(uptime: 10, interfaces: [("eth0", 1_000, 1_000)]))
        monitor.parse(frame(uptime: 12, interfaces: [("eth0", 1_200, 1_200), ("veth1", 900_000, 900_000)]))
        XCTAssertEqual(monitor.metrics?.netRxBytesPerSec, 100)
        XCTAssertNil(monitor.metrics?.interfaces.first(where: { $0.name == "veth1" })?.rxBytesPerSec)

        monitor.parse(frame(uptime: 14, interfaces: [("eth0", 10, 10), ("veth1", 900_400, 900_200)]))
        XCTAssertEqual(monitor.metrics?.netRxBytesPerSec, 200)
        XCTAssertEqual(monitor.metrics?.netTxBytesPerSec, 100)
        XCTAssertNil(monitor.metrics?.interfaces.first(where: { $0.name == "eth0" })?.rxBytesPerSec)

        monitor.parse(frame(uptime: 16, interfaces: [("eth0", 30, 50)]))
        XCTAssertEqual(monitor.metrics?.netRxBytesPerSec, 10)
        XCTAssertNil(monitor.netHistoryByInterface["veth1"])
    }

    func testLargeCountersAndRebootKeepSmallDeltasAccurate() {
        let monitor = HostMonitor(ssh: SSHConnection())
        let large: UInt64 = 9_007_199_254_740_993
        monitor.parse(frame(uptime: 100, interfaces: [("eth0", large, large)]))
        monitor.parse(frame(uptime: 102, interfaces: [("eth0", large + 6, large + 10)]))
        XCTAssertEqual(monitor.metrics?.netRxBytesPerSec, 3)
        XCTAssertEqual(monitor.metrics?.netTxBytesPerSec, 5)

        monitor.parse(frame(uptime: 1, interfaces: [("eth0", large + 100, large + 100)]))
        XCTAssertNil(monitor.metrics?.netRxBytesPerSec)
    }

    func testMixedGPUVendorsPreserveUnavailableMetrics() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse(frame(uptime: 1, interfaces: [], gpus: [
            "GPU NVIDIA|0|RTX A5000|86|1200|24576|71",
            "GPU AMD|1|Radeon card1|42|512|8192|54",
            "GPU Intel|2|Graphics card2||||",
            "GPU NVIDIA|3|Virtual GPU|[N/A]|[N/A]|[N/A]|[N/A]",
        ]))
        XCTAssertEqual(monitor.metrics?.gpus.count, 4)
        XCTAssertEqual(monitor.metrics?.gpus.first(where: { $0.id == "AMD:1" })?.memPercent, 6.25)
        XCTAssertEqual(monitor.metrics?.gpus.first(where: { $0.id == "NVIDIA:0" })?.utilPercent, 86)
        XCTAssertNil(monitor.metrics?.gpus.first(where: { $0.id == "Intel:2" })?.utilPercent)
        XCTAssertNil(monitor.metrics?.gpus.first(where: { $0.id == "NVIDIA:3" })?.memTotalMB)
    }

    func testGPUCollectionStateExplainsMissingAndPartialSamples() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse(frame(uptime: 1, interfaces: [], gpus: ["GPU_STATUS DEVICE_UNAVAILABLE"]))
        XCTAssertTrue(monitor.metrics?.gpus.isEmpty == true)
        XCTAssertEqual(monitor.metrics?.gpuStatus, .deviceUnavailable)

        monitor.parse(frame(uptime: 3, interfaces: [], gpus: [
            "GPU NVIDIA|0|RTX A5000|86|1200|24576|71|nvidia-smi",
            "GPU_STATUS OK",
        ]))
        XCTAssertEqual(monitor.metrics?.gpuStatus, .available)
        XCTAssertEqual(monitor.metrics?.gpus.first?.source, "nvidia-smi")
        XCTAssertEqual(monitor.metrics?.gpus.first?.memPercent, Double(1200) / 24576 * 100)

        monitor.parse(frame(uptime: 5, interfaces: [], gpus: [
            "GPU NVIDIA|0|GPU card0|||||DRM sysfs",
            "GPU_STATUS QUERY_FAILED",
        ]))
        XCTAssertEqual(monitor.metrics?.gpuStatus, .queryFailed)
        XCTAssertNil(monitor.metrics?.gpus.first?.utilPercent)
        XCTAssertNil(monitor.metrics?.gpus.first?.memPercent)
    }
    func testProcessCPUUsesIntervalAndRejectsReusedPIDsAndResetCounters() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse("UP 10\nPROC_CLOCK 100\nPROC_STATUS OK\nPROC 42 1000 200 512 worker (main)")
        XCTAssertNil(monitor.metrics?.processes.first?.cpuPercent)
        XCTAssertEqual(monitor.metrics?.processes.first?.name, "worker (main)")
        XCTAssertTrue(monitor.metrics?.processesAvailable == true)

        monitor.parse("UP 12\nPROC_CLOCK 100\nPROC 42 1000 500 768 worker (main)")
        XCTAssertEqual(monitor.metrics?.processes.first?.cpuPercent, 150)
        XCTAssertEqual(monitor.metrics?.processes.first?.memoryKB, 768)
        monitor.parse("UP 14\nPROC_CLOCK 100\nPROC 42 1100 600 256 replacement")
        XCTAssertNil(monitor.metrics?.processes.first?.cpuPercent)
        monitor.parse("UP 16\nPROC_CLOCK 100\nPROC 42 1100 20 256 replacement")
        XCTAssertNil(monitor.metrics?.processes.first?.cpuPercent)
        monitor.parse("UP 1\nPROC_CLOCK 100\nPROC 42 1100 100 256 replacement")
        XCTAssertNil(monitor.metrics?.processes.first?.cpuPercent)
        monitor.parse("UP 3\nPROC_CLOCK 100")
        XCTAssertTrue(monitor.metrics?.processes.isEmpty == true)
    }

    func testGPUProcessesKeepDeviceAssociationAndUnavailableMemory() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse("""
        GPU NVIDIA|0|RTX A5000|86|1200|24576|71|nvidia-smi|GPU-first
        GPU NVIDIA|1|RTX A5000|42|200|24576|65|nvidia-smi|GPU-second
        GPUPROC GPU-first|88|1024|python training.py
        GPUPROC GPU-second|88|[N/A]|python training.py
        GPUPROC GPU-first|88|1024|python training.py
        GPUPROC_STATUS OK
        """)
        XCTAssertEqual(monitor.metrics?.gpus.first?.uuid, "GPU-first")
        XCTAssertEqual(monitor.metrics?.gpuProcesses.count, 2)
        XCTAssertEqual(monitor.metrics?.gpuProcesses.first?.memoryMB, 1024)
        XCTAssertNil(monitor.metrics?.gpuProcesses.last?.memoryMB)
        XCTAssertTrue(monitor.metrics?.gpuProcessesAvailable == true)
        monitor.parse("GPU_STATUS QUERY_FAILED")
        XCTAssertTrue(monitor.metrics?.gpuProcesses.isEmpty == true)
        XCTAssertFalse(monitor.metrics?.gpuProcessesAvailable == true)
    }

    func testVolumesAndVisibleProcessConnectionsAreParsedWithoutDuplicateRows() {
        let monitor = HostMonitor(ssh: SSHConnection())
        monitor.parse("""
        VOLUME /dev/sda1|/|100|1000
        VOLUME /dev/sdb1|/data files|200|2000
        VOLUME /dev/sda1|/|100|1000
        VOLUME /dev/bad|/bad|-1|1000
        PROC 42 1000 200 512 server
        NETCONN tcp ESTAB 0 0 127.0.0.1:80 127.0.0.1:100 users:(("server",pid=42,fd=3),("server",pid=42,fd=4))
        NETCONN tcp LISTEN 0 0 *:80 *:* users:(("server",pid=42,fd=5))
        NETCONN tcp ESTAB 0 0 *:90 *:* users:(("worker",pid=43,fd=6))
        NETPROC_STATUS OK
        """)
        XCTAssertEqual(monitor.metrics?.disks.count, 2)
        XCTAssertEqual(monitor.metrics?.disks.last?.mount, "/data files")
        XCTAssertEqual(monitor.metrics?.disks.last?.device, "/dev/sdb1")
        XCTAssertEqual(monitor.metrics?.networkProcesses.first?.pid, 42)
        XCTAssertEqual(monitor.metrics?.networkProcesses.first?.connections, 2)
        XCTAssertEqual(monitor.metrics?.networkProcesses.first?.name, "server")
        XCTAssertEqual(monitor.metrics?.networkProcesses.last?.name, "PID 43")
        XCTAssertTrue(monitor.metrics?.networkProcessesAvailable == true)
    }
    func testMonitorStartsStoppedAndStopKeepsLastSample() {
        let monitor = HostMonitor(ssh: SSHConnection())
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertEqual(monitor.phase, .stopped)
        monitor.parse("UP 12\nPROC 42 100 200 512 NOPROC-worker")
        XCTAssertEqual(monitor.metrics?.processes.first?.name, "NOPROC-worker")
        monitor.stop()
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertEqual(monitor.phase, .stopped)
        XCTAssertEqual(monitor.metrics?.uptimeSecs, 12)
        monitor.handleNetworkChange()
        XCTAssertEqual(monitor.phase, .stopped)
    }

    func testHostMonitoringSwitchIsIsolatedAndBlocksRestart() {
        var a = SSHConnection()
        a.monitoringEnabled = false
        let first = HostMonitor(ssh: a)
        let second = HostMonitor(ssh: SSHConnection())
        first.start()
        first.handleNetworkChange()
        XCTAssertFalse(first.monitoringAllowed)
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.phase, .stopped)
        XCTAssertTrue(second.monitoringAllowed)
        a.monitoringEnabled = true
        first.updateConnection(a)
        XCTAssertTrue(first.monitoringAllowed)
        a.monitoringEnabled = false
        first.updateConnection(a)
        first.start(allowTrustRetry: true)
        XCTAssertFalse(first.isEnabled)
        XCTAssertEqual(first.phase, .stopped)
        XCTAssertTrue(second.monitoringAllowed)
    }

    func testConnectionReuseIsScopedToEndpointUserAndCredentials() {
        var base = SSHConnection()
        base.host = "fixture.invalid"
        base.password = "fixture-only"
        var changed = base
        changed.authMethod = .ask
        XCTAssertEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed.password = "different-fixture"
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base; changed.user = "another-user"
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base; changed.port = 2222
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base; changed.authMethod = .key; changed.keyId = "another-key"
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base; changed.monitoringEnabled = false
        XCTAssertEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base; changed.defaultPath = "/tmp"; changed.initialCommand = "pwd"
        XCTAssertEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
    }


}
