import XCTest

@testable import Termo

@MainActor
final class TerminalSessionControllerTests: XCTestCase {
    func testClosingDuringOpenRejectsLateOutputAndReleasesReturnedChannelOffMain() async throws {
        let opened = expectation(description: "open started"), released = expectation(description: "released")
        let probe = Probe(opened: opened, released: released, blockOpen: true)
        let transcript = TerminalTranscript()
        let controller = TerminalSessionController(transcript: transcript)
        controller.onReady = { XCTFail("Cancelled channel became ready") }
        controller.onOutput = { _ in XCTFail("Cancelled channel displayed output") }
        controller.onTerminated = { _ in XCTFail("Explicit close triggered reconnect") }
        controller.start(open: { try probe.open($0) })
        defer { controller.close(); probe.unblock() }
        await fulfillment(of: [opened], timeout: 2)
        controller.close()
        let callbacks = try XCTUnwrap(probe.callbacks)
        XCTAssertFalse(callbacks.isActive())
        callbacks.output(Array("late secret-free fixture\n".utf8))
        callbacks.ended(255)
        probe.unblock()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(transcript.tail(maxChars: 100), "")
        XCTAssertEqual(probe.channel.closeCount, 1)
        XCTAssertFalse(probe.channel.closedOnMain)
    }

    func testQueuedDisplayCannotReachReplacementSessionButEarlierHistoryIsRetained() async throws {
        let ready = expectation(description: "ready"), released = expectation(description: "released")
        let probe = Probe(released: released)
        let transcript = TerminalTranscript()
        let controller = TerminalSessionController(transcript: transcript)
        controller.onReady = { ready.fulfill() }
        controller.onOutput = { _ in XCTFail("Queued output reached a replaced view") }
        controller.start(open: { try probe.open($0) })
        await fulfillment(of: [ready], timeout: 2)
        let callbacks = try XCTUnwrap(probe.callbacks)
        callbacks.output(Array("valid history\n".utf8))  // Display delivery is queued on the main actor.
        controller.close()
        transcript.beginSession()
        callbacks.output(Array("stale\n".utf8))
        transcript.appendOutput(Array("new session\n".utf8))
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(transcript.lines, ["valid history", "new session"])
    }

    func testRemoteExitBeforeOpenReturnsNeverReportsReadyAndReleasesOnce() async throws {
        let opened = expectation(description: "open started"), ended = expectation(description: "ended")
        let released = expectation(description: "released")
        let probe = Probe(opened: opened, released: released, blockOpen: true)
        let controller = TerminalSessionController()
        controller.onReady = { XCTFail("Ended channel became ready") }
        controller.onTerminated = { code in
            XCTAssertEqual(code, 255); ended.fulfill()
        }
        controller.start(open: { try probe.open($0) })
        defer { controller.close(); probe.unblock() }
        await fulfillment(of: [opened], timeout: 2)
        try XCTUnwrap(probe.callbacks).ended(255)
        await fulfillment(of: [ended], timeout: 2)
        probe.unblock()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(probe.channel.disconnectReports, [true])
        XCTAssertEqual(probe.channel.closeCount, 1)
    }

    func testFinalOutputPrecedesOneExitCallbackAndNaturalExitReleasesResources() async throws {
        let ready = expectation(description: "ready"), ended = expectation(description: "ended")
        let released = expectation(description: "released")
        let probe = Probe(released: released)
        let controller = TerminalSessionController()
        var events: [String] = []
        controller.onReady = { ready.fulfill() }
        controller.onOutput = { events.append(String(decoding: $0, as: UTF8.self)) }
        controller.onTerminated = { code in
            events.append("exit:\(code)"); ended.fulfill()
        }
        controller.start(open: { try probe.open($0) })
        await fulfillment(of: [ready], timeout: 2)
        let callbacks = try XCTUnwrap(probe.callbacks)
        callbacks.output(Array("final".utf8))
        callbacks.ended(0)
        callbacks.ended(255)
        await fulfillment(of: [ended, released], timeout: 2)
        controller.close()
        XCTAssertEqual(events, ["final", "exit:0"])
        XCTAssertEqual(probe.channel.disconnectReports, [false])
    }

    func testOpenFailureReportsDisconnectOnceAndClosedSessionCannotRestart() async {
        struct Failure: Error {}
        let ended = expectation(description: "failed")
        let controller = TerminalSessionController()
        controller.onTerminated = { code in
            XCTAssertEqual(code, 255); ended.fulfill()
        }
        controller.start { _ in throw Failure() }
        await fulfillment(of: [ended], timeout: 2)
        controller.close()
        controller.start { _ in
            XCTFail("Closed controller reopened"); throw Failure()
        }
        XCTAssertFalse(controller.isActive)
    }

    func testWritesAndResizeStopAtCloseAndOnlyAcceptedInputIsRecorded() async {
        let ready = expectation(description: "ready"), released = expectation(description: "released")
        let probe = Probe(released: released)
        let transcript = TerminalTranscript()
        let controller = TerminalSessionController(transcript: transcript)
        controller.onReady = { ready.fulfill() }
        controller.start(open: { try probe.open($0) })
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(controller.send(Array("echo fixture\r".utf8), recordInput: true))
        controller.resize(cols: 120, rows: 40)
        probe.channel.acceptWrites = false
        XCTAssertFalse(controller.send(Array("rejected\r".utf8), recordInput: true))
        controller.close()
        XCTAssertFalse(controller.send(Array("late\r".utf8), recordInput: true))
        controller.resize(cols: 1, rows: 1)
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(transcript.lines, ["$ echo fixture"])
        XCTAssertEqual(probe.channel.resizeCount, 1)
    }

    func testSuccessfulOpenCannotBeDuplicatedAndWritesNoProgramInput() async {
        let ready = expectation(description: "ready")
        let released = expectation(description: "released")
        let probe = Probe(released: released)
        let controller = TerminalSessionController()
        controller.onReady = { ready.fulfill() }
        controller.start(open: { try probe.open($0) })
        controller.start { _ in
            XCTFail("Duplicate open"); return probe.channel
        }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(probe.channel.writes.isEmpty)
        controller.close()
        await fulfillment(of: [released], timeout: 2)
    }

    func testDroppingOwnerWhileOpeningDiscardsCallbacksAndCleansUpReturnedChannel() async throws {
        let opened = expectation(description: "open started"), released = expectation(description: "released")
        let probe = Probe(opened: opened, released: released, blockOpen: true)
        var controller: TerminalSessionController? = TerminalSessionController()
        weak var weakController = controller
        controller?.start(open: { try probe.open($0) })
        defer { probe.unblock() }
        await fulfillment(of: [opened], timeout: 2)
        controller = nil
        XCTAssertNil(weakController)
        XCTAssertFalse(try XCTUnwrap(probe.callbacks).isActive())
        probe.unblock()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(probe.channel.closeCount, 1)
    }

    private final class Probe: @unchecked Sendable {
        let channel: ChannelSpy
        private let opened: XCTestExpectation?
        private let gate = DispatchSemaphore(value: 0)
        private let blockOpen: Bool
        private let lock = NSLock()
        private var storedCallbacks: TerminalSessionController.Callbacks?
        var callbacks: TerminalSessionController.Callbacks? {
            lock.lock(); defer { lock.unlock() }; return storedCallbacks
        }

        init(opened: XCTestExpectation? = nil, released: XCTestExpectation, blockOpen: Bool = false) {
            self.opened = opened
            self.blockOpen = blockOpen
            channel = ChannelSpy(released: released)
        }
        func open(_ callbacks: TerminalSessionController.Callbacks) throws -> any TerminalChannel {
            lock.lock(); storedCallbacks = callbacks; lock.unlock()
            opened?.fulfill()
            if blockOpen { _ = gate.wait(timeout: .now() + 5) }
            return channel
        }
        func unblock() { gate.signal() }
    }

    private final class ChannelSpy: TerminalChannel, @unchecked Sendable {
        private let lock = NSLock()
        private let released: XCTestExpectation
        private var accepted = true
        private var storedWrites: [[UInt8]] = []
        private var storedResizes = 0
        private var storedReports: [Bool] = []
        private var mainClose = false

        init(released: XCTestExpectation) { self.released = released }
        var writes: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return storedWrites }
        var resizeCount: Int { lock.lock(); defer { lock.unlock() }; return storedResizes }
        var disconnectReports: [Bool] { lock.lock(); defer { lock.unlock() }; return storedReports }
        var closeCount: Int { disconnectReports.count }
        var closedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainClose }
        var acceptWrites: Bool {
            get { lock.lock(); defer { lock.unlock() }; return accepted }
            set { lock.lock(); accepted = newValue; lock.unlock() }
        }
        func write(_ bytes: [UInt8]) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard accepted else { return false }
            storedWrites.append(bytes)
            return true
        }
        func resize(cols: Int, rows: Int) { lock.lock(); storedResizes += 1; lock.unlock() }
        func close(reportingDisconnect: Bool) {
            lock.lock()
            storedReports.append(reportingDisconnect)
            mainClose = Thread.isMainThread
            lock.unlock()
            released.fulfill()
        }
    }
}
