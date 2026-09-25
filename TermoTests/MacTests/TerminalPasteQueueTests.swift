import XCTest

@testable import Termo

@MainActor
final class TerminalPasteQueueTests: XCTestCase {
    func testSuccessivePastesStayOrderedAndMarkersStayWithTheirContent() {
        let clock = Scheduler()
        let queue = TerminalPasteQueue(chunkSize: 3, schedule: clock.schedule)
        var sent: [[UInt8]] = []
        queue.enqueue("abcdef", bracketed: true) {
            sent.append($0); return true
        }
        queue.enqueue("第二条\r\n末行", bracketed: true) {
            sent.append($0); return true
        }
        XCTAssertEqual(sent.count, 1)
        clock.drain()
        XCTAssertEqual(
            String(decoding: sent.flatMap { $0 }, as: UTF8.self),
            "\u{1B}[200~abcdef\u{1B}[201~\u{1B}[200~第二条\n末行\u{1B}[201~")
        XCTAssertTrue(sent[0].starts(with: Array("\u{1B}[200~abc".utf8)))
        XCTAssertEqual(sent[1], Array("def\u{1B}[201~".utf8))
    }

    func testCancelClosesBracketedPasteOnceAndStaleTimerCannotAdvanceNewPaste() {
        let clock = Scheduler()
        let queue = TerminalPasteQueue(chunkSize: 2, schedule: clock.schedule)
        var sent: [String] = []
        queue.enqueue("abcdef", bracketed: true) {
            sent.append(String(decoding: $0, as: UTF8.self)); return true
        }
        queue.cancel()
        queue.cancel()
        queue.enqueue("1234", bracketed: false) {
            sent.append(String(decoding: $0, as: UTF8.self)); return true
        }
        XCTAssertEqual(sent, ["\u{1B}[200~ab", "\u{1B}[201~", "12"])
        clock.runNext()  // Old paste's already-enqueued timer.
        XCTAssertEqual(sent.last, "12")
        clock.drain()
        XCTAssertEqual(sent, ["\u{1B}[200~ab", "\u{1B}[201~", "12", "34"])
    }

    func testChangedConnectionRejectsOldRemainderAndClosingMarker() {
        let clock = Scheduler()
        let queue = TerminalPasteQueue(chunkSize: 2, schedule: clock.schedule)
        var originalConnected = true
        var original: [[UInt8]] = []
        var replacement: [[UInt8]] = []
        queue.enqueue("abcdef", bracketed: true) {
            guard originalConnected else { return false }
            original.append($0)
            return true
        }
        originalConnected = false
        queue.cancel()  // The end marker must not be rerouted to a replacement connection.
        queue.enqueue("new", bracketed: false) {
            replacement.append($0); return true
        }
        clock.drain()
        XCTAssertEqual(original, [Array("\u{1B}[200~ab".utf8)])
        XCTAssertEqual(replacement.flatMap { $0 }, Array("new".utf8))
    }

    func testFailedWriteDropsThatPasteWithoutRetryingItsRemainder() {
        let clock = Scheduler()
        let queue = TerminalPasteQueue(chunkSize: 2, schedule: clock.schedule)
        var attempts = 0
        var sent: [UInt8] = []
        queue.enqueue("abcdef", bracketed: false) { _ in
            attempts += 1; return attempts == 1
        }
        queue.enqueue("next", bracketed: false) {
            sent += $0; return true
        }
        clock.drain()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(String(decoding: sent, as: UTF8.self), "next")
    }

    func testEmptyAndSingleChunkPastesDoNotScheduleWork() {
        let clock = Scheduler()
        let queue = TerminalPasteQueue(schedule: clock.schedule)
        var sent: [[UInt8]] = []
        queue.enqueue("", bracketed: true) { _ in
            XCTFail("Empty paste was sent"); return true
        }
        queue.enqueue("a\rb\r\nc", bracketed: false) {
            sent.append($0); return true
        }
        XCTAssertEqual(sent, [Array("a\nb\nc".utf8)])
        XCTAssertTrue(clock.pending.isEmpty)
    }

    @MainActor
    private final class Scheduler {
        var pending: [@MainActor () -> Void] = []
        func schedule(_ action: @escaping @MainActor () -> Void) { pending.append(action) }
        func runNext() { if !pending.isEmpty { pending.removeFirst()() } }
        func drain() { while !pending.isEmpty { runNext() } }
    }
}
