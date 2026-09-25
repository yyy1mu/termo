import XCTest

@testable import Termo

final class RemoteSFTPStoreTests: XCTestCase {
    func testLazyAcquisitionReusesOneSessionAndCloseAllowsFreshSession() throws {
        let probe = Probe(), store = makeStore(probe)
        XCTAssertEqual(probe.snapshot.created, 0)
        let first = try XCTUnwrap(store.acquire())
        XCTAssertTrue(store.acquire() === first)
        XCTAssertEqual(probe.snapshot.created, 1)
        store.close()
        store.close()
        XCTAssertEqual(probe.snapshot.retired, [first.id])
        let next = try XCTUnwrap(store.acquire())
        XCTAssertFalse(next === first)
        XCTAssertEqual(probe.snapshot.created, 2)
    }

    func testFailureKeepsFallbackUntilExplicitReset() throws {
        let probe = Probe(), store = makeStore(probe)
        let failed = try XCTUnwrap(store.acquire())
        XCTAssertTrue(store.markUnavailable(ifCurrent: failed))
        XCTAssertFalse(store.markUnavailable(ifCurrent: failed))
        XCTAssertNil(store.acquire())
        store.close()
        XCTAssertNil(store.acquire(), "Releasing resources must not clear fallback policy")
        XCTAssertEqual(probe.snapshot.created, 1)
        store.reset()
        XCTAssertFalse(store.acquire() === failed)
        XCTAssertNotNil(store.acquire())
        XCTAssertEqual(probe.snapshot.retired, [failed.id])
    }

    func testLateFailureAfterReconnectDoesNotRetireReplacement() throws {
        let probe = Probe(), store = makeStore(probe)
        let old = try XCTUnwrap(store.acquire())
        store.reset()
        let current = try XCTUnwrap(store.acquire())
        XCTAssertFalse(store.markUnavailable(ifCurrent: old))
        XCTAssertTrue(store.acquire() === current)
        XCTAssertEqual(probe.snapshot.retired, [old.id])
        XCTAssertTrue(store.markUnavailable(ifCurrent: current))
        XCTAssertEqual(probe.snapshot.retired, [old.id, current.id])
    }

    func testLateFailureAfterCloseCannotPoisonAnEmptyAvailableStore() throws {
        let probe = Probe(), store = makeStore(probe)
        let old = try XCTUnwrap(store.acquire())
        store.close()
        XCTAssertFalse(store.markUnavailable(ifCurrent: old))
        let current = try XCTUnwrap(store.acquire())
        XCTAssertFalse(current === old)
        XCTAssertEqual(probe.snapshot.retired, [old.id])
    }

    func testUnusedStoreAndRepeatedResetNeverCreateConnections() {
        let probe = Probe()
        var store: RemoteSFTPStore<Session>? = makeStore(probe)
        store?.reset()
        store?.close()
        store?.reset()
        store = nil
        XCTAssertEqual(probe.snapshot.created, 0)
        XCTAssertEqual(probe.snapshot.retired, [])
    }

    func testDeinitializationRetiresOnlyTheCurrentlyOwnedSession() throws {
        for markFailed in [false, true] {
            let probe = Probe()
            var store: RemoteSFTPStore<Session>? = makeStore(probe)
            let session = try XCTUnwrap(store?.acquire())
            if markFailed { store?.markUnavailable(ifCurrent: session) }
            store = nil
            XCTAssertEqual(probe.snapshot.retired, [session.id])
        }
    }

    func testConcurrentAcquisitionCreatesExactlyOneSession() {
        let probe = Probe(), store = makeStore(probe)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            guard let session = store.acquire() else { return XCTFail("Unexpected unavailable state") }
            XCTAssertEqual(session.id, 0)
        }
        XCTAssertEqual(probe.snapshot.created, 1)
        store.close()
        XCTAssertEqual(probe.snapshot.retired, [0])
    }

    func testConcurrentCloseResetAndFailureRetireEachCreatedSessionOnce() {
        let probe = Probe(), store = makeStore(probe)
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            let captured = store.acquire()
            switch index % 3 {
            case 0: store.reset()
            case 1: store.close()
            default: if let captured { store.markUnavailable(ifCurrent: captured) }
            }
        }
        store.close()
        let snapshot = probe.snapshot
        XCTAssertGreaterThan(snapshot.created, 0)
        XCTAssertEqual(snapshot.retired.sorted(), Array(0..<snapshot.created))
    }

    func testDelayedMutationErrorAfterReconnectDoesNotDisableNewFileOperations() async throws {
        let gate = PendingFailure(), probe = Probe(gate: gate), store = makeStore(probe)
        let old = try XCTUnwrap(store.acquire())
        let pending = Task {
            await RemoteFileMutation.remove("/old", recursive: false).perform(
                using: old,
                shell: { _ in
                    XCTFail("Old mutation replayed through shell"); return Self.shellResult
                },
                didLoseSFTP: { store.markUnavailable(ifCurrent: old) })
        }
        await gate.waitUntilStarted()
        store.reset()
        let current = try XCTUnwrap(store.acquire())
        await gate.finish()
        guard case .failure = await pending.value else { return XCTFail("Old error was lost") }
        XCTAssertTrue(store.acquire() === current)
        XCTAssertEqual(probe.snapshot.retired, [old.id])
        let result = await RemoteFileMutation.createDirectory("/new").perform(
            using: current,
            shell: { _ in
                XCTFail("New operation lost its SFTP connection"); return Self.shellResult
            },
            didLoseSFTP: { store.markUnavailable(ifCurrent: current) })
        try result.get()
    }

    private static var shellResult: RemoteFS.OpResult { .init(data: Data(), stderr: Data(), code: 0) }

    private func makeStore(_ probe: Probe) -> RemoteSFTPStore<Session> {
        RemoteSFTPStore(create: { probe.create() }, retire: { probe.retire($0) })
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var created = 0
        private var retired: [Int] = []
        private let gate: PendingFailure?
        init(gate: PendingFailure? = nil) { self.gate = gate }

        func create() -> Session {
            lock.lock(); defer { lock.unlock() }
            let id = created
            created += 1
            return Session(id: id, gate: id == 0 ? gate : nil)
        }
        func retire(_ session: Session) {
            lock.lock(); defer { lock.unlock() }
            retired.append(session.id)
        }
        var snapshot: (created: Int, retired: [Int]) {
            lock.lock(); defer { lock.unlock() }
            return (created, retired)
        }
    }

    private final class Session: FileMutationSession, Sendable {
        let id: Int
        let gate: PendingFailure?
        init(id: Int, gate: PendingFailure?) { self.id = id; self.gate = gate }
        func lstat(_ path: String) async throws -> SFTPAttrs { throw SFTPError(code: 2, message: "missing") }
        func mkdir(_ path: String) async throws { try await gate?.run() }
        func remove(_ path: String) async throws { try await gate?.run() }
        func rename(from: String, to: String) async throws { try await gate?.run() }
        func setPermissions(_ path: String, _ mode: UInt32) async throws { try await gate?.run() }
    }

    private actor PendingFailure {
        private var pending: CheckedContinuation<Void, Error>?
        private var observer: CheckedContinuation<Void, Never>?
        private var started = false

        func run() async throws {
            try await withCheckedThrowingContinuation {
                pending = $0; started = true
                observer?.resume(); observer = nil
            }
        }
        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { observer = $0 }
        }
        func finish() {
            pending?.resume(throwing: SFTPError(code: 0xF001, message: "late failure", isTransport: true))
            pending = nil
        }
    }
}
