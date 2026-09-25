import XCTest
@testable import Termo

final class ResourceAlertEvaluatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testRequiresSustainedSamplesAndHonorsCooldown() {
        var evaluator = ResourceAlertEvaluator()
        for frame in 0..<14 {
            XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95),
                                             at: start.addingTimeInterval(Double(frame * 2))).isEmpty)
        }
        let first = evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95), at: start.addingTimeInterval(28))
        XCTAssertEqual(first, [ResourceAlert(metric: .cpu, percent: 95)])
        XCTAssertEqual(first.first?.approximateDuration, 30)
        for frame in 15..<164 {
            XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95),
                                             at: start.addingTimeInterval(Double(frame * 2))).isEmpty)
        }
        XCTAssertEqual(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95),
                                         at: start.addingTimeInterval(328)).count, 1)
    }

    func testMissingInvalidAndRecoveredSamplesResetStreak() {
        for interrupted in [nil, Double.nan, Double.infinity, -1, 101, 89.9] as [Double?] {
            var evaluator = ResourceAlertEvaluator()
            for _ in 0..<14 { _ = evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95), at: start) }
            XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: interrupted), at: start).isEmpty)
            XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95), at: start).isEmpty)
        }
    }

    func testLongSamplingGapDoesNotCountAsContinuousHighUsage() {
        var evaluator = ResourceAlertEvaluator()
        for _ in 0..<14 { _ = evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95), at: start) }
        XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95),
                                         at: start.addingTimeInterval(60)).isEmpty)
    }

    func testMetricsAndHostsHaveIndependentStreaksAndCleanup() {
        var evaluator = ResourceAlertEvaluator()
        let metrics = HostMetrics(cpuPercent: 95, memUsedKB: 95, memTotalKB: 100)
        for _ in 0..<14 {
            _ = evaluator.evaluate(hostID: "a", metrics: metrics, at: start)
            _ = evaluator.evaluate(hostID: "a|cpu", metrics: metrics, at: start)
        }
        evaluator.remove(hostID: "a")
        XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: metrics, at: start).isEmpty)
        XCTAssertEqual(evaluator.evaluate(hostID: "a|cpu", metrics: metrics, at: start).map(\.metric), [.cpu, .memory])
    }

    func testDiskAlertUsesFullestValidVolumeAndMissingMemoryDoesNotAlert() {
        var evaluator = ResourceAlertEvaluator()
        let metrics = HostMetrics(memUsedKB: 99, memTotalKB: 0, disks: [
            DiskUsage(mount: "/", usedKB: 12, totalKB: 100),
            DiskUsage(mount: "/data", usedKB: 98, totalKB: 100),
            DiskUsage(mount: "/invalid", usedKB: 1000, totalKB: 1)
        ])
        for _ in 0..<14 { _ = evaluator.evaluate(hostID: "a", metrics: metrics, at: start) }
        XCTAssertEqual(evaluator.evaluate(hostID: "a", metrics: metrics, at: start),
                       [ResourceAlert(metric: .disk, percent: 98)])
    }

    func testRestartResetsStreakButPreservesNotificationCooldown() {
        var evaluator = ResourceAlertEvaluator()
        for _ in 0..<15 { _ = evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95), at: start) }
        evaluator.resetSampling(hostID: "a")
        for _ in 0..<15 {
            XCTAssertTrue(evaluator.evaluate(hostID: "a", metrics: HostMetrics(cpuPercent: 95),
                                             at: start.addingTimeInterval(60)).isEmpty)
        }
    }
}
