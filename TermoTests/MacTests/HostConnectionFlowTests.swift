import XCTest
@testable import Termo

@MainActor
final class HostConnectionFlowTests: XCTestCase {
    private func host(_ id: String = "a") -> Termo.Host {
        Termo.Host(id: id, name: id, addr: "\(id).invalid", group: "", status: .offline,
                   os: "linux", ssh: SSHConnection(host: "\(id).invalid"))
    }

    func testLateConnectionCallbacksCannotCompleteOrCancelReplacement() throws {
        let a = host(), b = host("b")
        let flow = HostConnectionFlow(currentHost: { $0 == a.id ? a : b }, isUnlocked: { true })
        var completed: [String] = []
        flow.connect(to: a, hint: "") { completed.append(a.id) }
        let old = try XCTUnwrap(flow.request)
        XCTAssertEqual(flow.cancel(id: old.id)?.id, a.id)
        flow.connect(to: b, hint: "") { completed.append(b.id) }
        let next = try XCTUnwrap(flow.request)
        flow.finishConnection(id: old.id)
        XCTAssertNil(flow.cancel(id: old.id))
        XCTAssertEqual(flow.request?.id, next.id)
        XCTAssertEqual(completed, [])
        flow.finishConnection(id: next.id)
        flow.finishConnection(id: next.id)
        XCTAssertEqual(completed, [b.id])
    }

    func testPasswordRetryForSameHostHasNewIdentityAndRejectsOldSubmission() throws {
        let machine = host()
        let flow = HostConnectionFlow(currentHost: { _ in machine }, isUnlocked: { true })
        flow.askPassword(for: machine, error: nil) { XCTFail("Cancelled request ran") }
        let old = try XCTUnwrap(flow.request)
        flow.cancel(id: old.id)
        flow.askPassword(for: machine, error: "read failed") {}
        let next = try XCTUnwrap(flow.request)
        XCTAssertNotEqual(old.id, next.id)
        XCTAssertFalse(flow.submitPassword(id: old.id, password: "") { _ in
            XCTFail("Stale request wrote credentials"); return true
        })
        flow.reportPasswordError("stale", id: old.id)
        XCTAssertEqual(flow.passwordError, "read failed")
        XCTAssertEqual(flow.request?.id, next.id)
    }

    func testFailedPasswordSaveKeepsPromptAndContinuationForRetry() throws {
        let machine = host()
        let flow = HostConnectionFlow(currentHost: { _ in machine }, isUnlocked: { true })
        var completions = 0
        flow.askPassword(for: machine, error: nil) { completions += 1 }
        let id = try XCTUnwrap(flow.request?.id)
        XCTAssertFalse(flow.submitPassword(id: id, password: "fixture") { _ in
            flow.reportPasswordError("storage unavailable", id: id)
            return false
        })
        XCTAssertEqual(flow.request?.id, id)
        XCTAssertEqual(flow.passwordError, "storage unavailable")
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(flow.submitPassword(id: id, password: "fixture") { _ in true })
        XCTAssertNil(flow.request)
        XCTAssertNil(flow.passwordError)
        XCTAssertEqual(completions, 1)
    }

    func testPasswordCompletionCanStartConnectionWithNewCredentialSnapshot() throws {
        var machine = host()
        let flow = HostConnectionFlow(currentHost: { _ in machine }, isUnlocked: { true })
        var connections = 0
        flow.askPassword(for: machine, error: nil) {
            flow.connect(to: machine, hint: "terminal") { connections += 1 }
        }
        let id = try XCTUnwrap(flow.request?.id)
        XCTAssertTrue(flow.submitPassword(id: id, password: "fixture") { _ in
            machine.ssh?.password = "fixture"
            return true
        })
        let connection = try XCTUnwrap(flow.request)
        XCTAssertEqual(connection.kind, .connection)
        XCTAssertEqual(connection.host.ssh?.password, "fixture")
        XCTAssertFalse(flow.submitPassword(id: id, password: "duplicate") { _ in
            XCTFail("Duplicate write"); return true
        })
        flow.finishConnection(id: connection.id)
        XCTAssertEqual(connections, 1)
    }

    func testChangedOrDeletedTargetCannotSavePasswordOrFinishConnecting() throws {
        let original = host()
        var current: Termo.Host? = original
        let flow = HostConnectionFlow(currentHost: { _ in current }, isUnlocked: { true })
        flow.askPassword(for: original, error: nil) { XCTFail("Changed target ran") }
        let id = try XCTUnwrap(flow.request?.id)
        current?.ssh?.host = "replacement.invalid"
        XCTAssertFalse(flow.submitPassword(id: id, password: "fixture") { _ in
            XCTFail("Password sent to changed target"); return true
        })
        XCTAssertNil(flow.request)
        current = original
        flow.connect(to: original, hint: "") { XCTFail("Deleted target ran") }
        let connection = try XCTUnwrap(flow.request)
        current = nil
        flow.finishConnection(id: connection.id)
        XCTAssertNil(flow.request)
    }

    func testCancelDoesNotReturnHostWhoseCredentialsWereReplaced() throws {
        var current = host()
        let flow = HostConnectionFlow(currentHost: { _ in current }, isUnlocked: { true })
        flow.connect(to: current, hint: "") {}
        let id = try XCTUnwrap(flow.request?.id)
        current.ssh?.password = "new credential"
        XCTAssertNil(flow.cancel(id: id)) // AppModel must not clear the new password.
        XCTAssertNil(flow.request)
    }

    func testBusyRequestCannotBeOverwrittenAndRenameDoesNotInvalidateConnection() throws {
        var current = host()
        let flow = HostConnectionFlow(currentHost: { _ in current }, isUnlocked: { true })
        var completions = 0
        flow.connect(to: current, hint: "terminal") { completions += 1 }
        let id = try XCTUnwrap(flow.request?.id)
        flow.askPassword(for: current, error: nil) { XCTFail("Overwrote active request") }
        current = Termo.Host(id: current.id, name: "renamed", addr: current.addr,
                             group: current.group, status: current.status, os: current.os, ssh: current.ssh)
        flow.reconcile()
        XCTAssertEqual(flow.request?.id, id)
        flow.finishConnection(id: id)
        XCTAssertEqual(completions, 1)
    }

    func testLockRejectsCallbacksAndNewRequests() throws {
        let current = host()
        var unlocked = true
        let flow = HostConnectionFlow(currentHost: { _ in current }, isUnlocked: { unlocked })
        flow.askPassword(for: current, error: nil) { XCTFail("Locked request ran") }
        let id = try XCTUnwrap(flow.request?.id)
        unlocked = false
        XCTAssertFalse(flow.submitPassword(id: id, password: "fixture") { _ in
            XCTFail("Locked request saved a password"); return true
        })
        flow.connect(to: current, hint: "") { XCTFail("Started while locked") }
        XCTAssertNil(flow.request)
    }
}
