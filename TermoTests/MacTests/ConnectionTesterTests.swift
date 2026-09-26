import XCTest

@testable import Termo
import TermoEngine
import TermoCore

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func read() -> Value { lock.withLock { value } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&value) } }
}

@MainActor
final class ConnectionTesterTests: XCTestCase {
    func testCancelSignalsTheActiveEngineAttempt() async {
        let started = expectation(description: "diagnostic started")
        let captured = LockedValue<SSHConnectionCancellation?>(nil)
        let tester = ConnectionTester(
            preflight: { _, _ in .known },
            runTest: { _, _, cancellation, _, _ in
                captured.update { $0 = cancellation }
                started.fulfill()
            })

        tester.start(conn: SSHConnection(host: "example.test", password: "fixture"))
        await fulfillment(of: [started], timeout: 1)
        tester.cancel()

        XCTAssertTrue(captured.read()?.isCancelled == true)
        XCTAssertTrue(tester.cancelled)
        XCTAssertFalse(tester.isRunning)
    }

    func testLateCallbackFromReplacedAttemptCannotFinishTheNewAttempt() async throws {
        let firstStarted = expectation(description: "first diagnostic started")
        let secondStarted = expectation(description: "second diagnostic started")
        let callbacks = LockedValue<[SSHConnectionDiagnostic.Stage]>([])
        let tester = ConnectionTester(
            preflight: { _, _ in .known },
            runTest: { _, _, _, _, report in
                callbacks.update {
                    $0.append(report)
                    ($0.count == 1 ? firstStarted : secondStarted).fulfill()
                }
            })

        let connection = SSHConnection(host: "example.test", password: "fixture")
        tester.start(conn: connection)
        await fulfillment(of: [firstStarted], timeout: 1)
        tester.start(conn: connection)
        await fulfillment(of: [secondStarted], timeout: 1)

        let reports = callbacks.read()
        reports[0](5, true, "stale success")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(tester.isRunning)
        XCTAssertFalse(tester.succeeded)

        for stage in 1...5 { reports[1](stage, true, nil) }
        for _ in 0..<20 where !tester.succeeded {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(tester.succeeded)
        XCTAssertFalse(tester.isRunning)
    }

    func testInvalidPortStopsBeforeFingerprintOrDiagnosticWork() {
        let preflightCount = LockedValue(0)
        let diagnosticCount = LockedValue(0)
        let tester = ConnectionTester(
            preflight: { _, _ in
                preflightCount.update { $0 += 1 }
                return .known
            },
            runTest: { _, _, _, _, _ in
                diagnosticCount.update { $0 += 1 }
            })

        tester.start(conn: SSHConnection(host: "example.test", port: 0, password: "fixture"))

        XCTAssertEqual(preflightCount.read(), 0)
        XCTAssertEqual(diagnosticCount.read(), 0)
        XCTAssertTrue(tester.failed)
        XCTAssertFalse(tester.isRunning)
    }
}
