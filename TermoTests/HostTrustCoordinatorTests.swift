import Combine
import XCTest
@testable import Termo

@MainActor
final class HostTrustCoordinatorTests: XCTestCase {
    private func host() -> Termo.Host {
        Termo.Host(id: "a", name: "fixture", addr: "a.invalid", group: "", status: .offline,
                   os: "linux", ssh: SSHConnection(host: "a.invalid"))
    }

    private var info: HostKeyInfo {
        HostKeyInfo(host: "a.invalid", port: 22, keyLine: "fixture", sha256: "fixture", md5: "")
    }

    private func expectPrompt(_ coordinator: HostTrustCoordinator) -> (XCTestExpectation, AnyCancellable) {
        let shown = expectation(description: "fingerprint prompt")
        let subscription = coordinator.$pending.compactMap { $0 }.prefix(1).sink { _ in shown.fulfill() }
        return (shown, subscription)
    }

    func testDecisionIsConsumedOnceAndTrustScopeIsPreserved() async throws {
        let machine = host(), fingerprint = info
        var writes: [Bool] = []
        let coordinator = HostTrustCoordinator(currentHost: { _ in machine }, isUnlocked: { true },
            preflight: { _ in .prompt(fingerprint) }, trust: { _, persist in writes.append(persist) })
        for (decision, persist) in [(HostKeyDecision.once, false), (.save, true)] {
            let (shown, subscription) = expectPrompt(coordinator)
            let task = Task { try await coordinator.verify(machine) }
            defer { task.cancel(); coordinator.cancelAll(); subscription.cancel() }
            await fulfillment(of: [shown], timeout: 2)
            let prompt = try XCTUnwrap(coordinator.pending)
            prompt.respond(decision)
            prompt.respond(.save)
            let result = try await task.value
            XCTAssertTrue(result)
            XCTAssertEqual(writes.last, persist)
            XCTAssertNil(coordinator.pending)
        }
        XCTAssertEqual(writes, [false, true])
    }

    func testTaskCancellationResumesWaiterAndOldPromptCannotResolveNextRequest() async throws {
        let machine = host(), fingerprint = info
        var writes = 0
        let coordinator = HostTrustCoordinator(currentHost: { _ in machine }, isUnlocked: { true },
            preflight: { _ in .prompt(fingerprint) }, trust: { _, _ in writes += 1 })
        let (firstShown, firstSubscription) = expectPrompt(coordinator)
        defer { firstSubscription.cancel(); coordinator.cancelAll() }
        let first = Task { try await coordinator.verify(machine) }
        await fulfillment(of: [firstShown], timeout: 2)
        let old = try XCTUnwrap(coordinator.pending)
        first.cancel()
        let cancelled = try await first.value
        XCTAssertFalse(cancelled)
        XCTAssertNil(coordinator.pending)

        let (nextShown, nextSubscription) = expectPrompt(coordinator)
        defer { nextSubscription.cancel() }
        let next = Task { try await coordinator.verify(machine) }
        defer { next.cancel() }
        await fulfillment(of: [nextShown], timeout: 2)
        let current = try XCTUnwrap(coordinator.pending)
        old.respond(.save)
        XCTAssertEqual(coordinator.pending?.id, current.id)
        XCTAssertEqual(writes, 0)
        current.respond(.cancel)
        let rejected = try await next.value
        XCTAssertFalse(rejected)
        XCTAssertEqual(writes, 0)
    }

    func testLateScanCannotPublishPromptAfterCancellationOrReplaceNewPrompt() async throws {
        let machine = host(), fingerprint = info
        let scanStarted = expectation(description: "first scan started")
        var scanReply: CheckedContinuation<HostKeyVerifier.Preflight, Never>?
        var scans = 0
        let coordinator = HostTrustCoordinator(currentHost: { _ in machine }, isUnlocked: { true },
            preflight: { _ in
                scans += 1
                if scans == 1 {
                    return await withCheckedContinuation {
                        scanReply = $0
                        scanStarted.fulfill()
                    }
                }
                return .prompt(fingerprint)
            }, trust: { _, _ in XCTFail("Cancelled scan granted trust") })
        let first = Task { try await coordinator.verify(machine) }
        await fulfillment(of: [scanStarted], timeout: 2)
        coordinator.cancelAll()
        let (shown, subscription) = expectPrompt(coordinator)
        defer { subscription.cancel(); coordinator.cancelAll(); first.cancel() }
        let second = Task { try await coordinator.verify(machine) }
        defer { second.cancel() }
        await fulfillment(of: [shown], timeout: 2)
        let prompt = try XCTUnwrap(coordinator.pending)
        scanReply?.resume(returning: .prompt(fingerprint))
        let oldResult = try await first.value
        XCTAssertFalse(oldResult)
        XCTAssertEqual(coordinator.pending?.id, prompt.id)
        prompt.respond(.cancel)
        let result = try await second.value
        XCTAssertFalse(result)
    }

    func testChangedHostCannotSaveDisplayedFingerprint() async throws {
        var machine = host()
        let original = machine, fingerprint = info
        let coordinator = HostTrustCoordinator(currentHost: { _ in machine }, isUnlocked: { true },
            preflight: { _ in .changed(fingerprint) }, trust: { _, _ in XCTFail("Trusted stale target") })
        let (shown, subscription) = expectPrompt(coordinator)
        defer { subscription.cancel(); coordinator.cancelAll() }
        let task = Task { try await coordinator.verify(original) }
        defer { task.cancel() }
        await fulfillment(of: [shown], timeout: 2)
        let prompt = try XCTUnwrap(coordinator.pending)
        machine.ssh?.port = 2222
        prompt.respond(.save) // Validate even if the host-change observer has not run yet.
        let result = try await task.value
        XCTAssertFalse(result)
        XCTAssertNil(coordinator.pending)
    }

    func testLockOrHostDeletionDismissesPromptAndRejectsNewVerification() async throws {
        let original = host(), fingerprint = info
        for locked in [false, true] {
            var current: Termo.Host? = original
            var unlocked = true
            let coordinator = HostTrustCoordinator(currentHost: { _ in current }, isUnlocked: { unlocked },
                preflight: { _ in .prompt(fingerprint) }, trust: { _, _ in XCTFail("Invalid request granted trust") })
            let (shown, subscription) = expectPrompt(coordinator)
            defer { subscription.cancel(); coordinator.cancelAll() }
            let task = Task { try await coordinator.verify(original) }
            defer { task.cancel() }
            await fulfillment(of: [shown], timeout: 2)
            if locked { unlocked = false } else { current = nil }
            coordinator.reconcile()
            XCTAssertNil(coordinator.pending)
            let result = try await task.value
            XCTAssertFalse(result)
            let retry = try await coordinator.verify(original)
            XCTAssertFalse(retry)
        }
    }

    func testWriteFailurePropagatesAndReleasesRequestForRetry() async throws {
        struct WriteFailure: Error {}
        let machine = host(), fingerprint = info
        var fail = true
        let coordinator = HostTrustCoordinator(currentHost: { _ in machine }, isUnlocked: { true },
            preflight: { _ in .prompt(fingerprint) }, trust: { _, _ in if fail { throw WriteFailure() } })
        for shouldFail in [true, false] {
            fail = shouldFail
            let (shown, subscription) = expectPrompt(coordinator)
            defer { subscription.cancel(); coordinator.cancelAll() }
            let task = Task { try await coordinator.verify(machine) }
            defer { task.cancel() }
            await fulfillment(of: [shown], timeout: 2)
            try XCTUnwrap(coordinator.pending).respond(.save)
            do {
                let result = try await task.value
                XCTAssertFalse(shouldFail)
                XCTAssertTrue(result)
            } catch {
                XCTAssertTrue(shouldFail)
                XCTAssertTrue(error is WriteFailure)
            }
            XCTAssertNil(coordinator.pending)
        }
    }
}
