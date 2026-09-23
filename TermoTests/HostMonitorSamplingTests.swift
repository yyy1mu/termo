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
}
