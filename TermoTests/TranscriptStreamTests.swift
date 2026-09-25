import XCTest

@testable import Termo

final class TranscriptStreamTests: XCTestCase {
    func testUnicodeAndControlSequencesSurviveEveryPacketBoundary() {
        let wire = Array("开始 \u{1B}[31m中文🖥️\u{1B}[0m\u{1B}]7;file://host/private\u{1B}\\ 结束\n".utf8)
        for split in 0...wire.count {
            let transcript = TerminalTranscript()
            transcript.appendOutput(Array(wire[..<split]))
            transcript.appendOutput(Array(wire[split...]))
            XCTAssertEqual(transcript.tail(maxChars: 100), "开始 中文🖥️ 结束", "split at byte \(split)")
        }
    }

    func testByteAtATimeNeverLeaksControlPayloadIntoSnapshot() {
        let transcript = TerminalTranscript()
        for byte in Array("before\u{1B}]0;hidden title\u{07}\u{1B}[32mafter\u{1B}[0m".utf8) {
            transcript.appendOutput([byte])
            XCTAssertFalse(transcript.tail(maxChars: 100).contains("hidden"))
        }
        XCTAssertEqual(transcript.tail(maxChars: 100), "beforeafter")
    }

    func testCarriageReturnNewlinePreservesOutputAcrossPackets() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("first\r".utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "first")
        transcript.appendOutput(Array("\nsecond\r\n".utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "first\nsecond")
    }

    func testSnapshotBudgetIsStrictEvenForOneVeryLongLine() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array((String(repeating: "中", count: 20_000) + "tail").utf8))
        XCTAssertEqual(transcript.tail(maxChars: 8), "中中中中tail")
        XCTAssertEqual(transcript.tail(maxChars: 0), "")
        XCTAssertEqual(transcript.tail(maxChars: -1), "")
    }

    func testInputAndOutputKeepSeparateUnicodeState() {
        let transcript = TerminalTranscript()
        let input = Array("echo 中文🖥️\r".utf8)
        let output = Array("服务就绪\n".utf8)
        for index in 0..<max(input.count, output.count) {
            if index < input.count { transcript.appendInput([input[index]]) }
            if index < output.count { transcript.appendOutput([output[index]]) }
        }
        XCTAssertEqual(Set(transcript.lines), ["$ echo 中文🖥️", "服务就绪"])
    }

    func testInputOmitsArrowAndBracketedPasteControlSequences() {
        let transcript = TerminalTranscript()
        for byte in Array("\u{1B}[200~echo 中文\r\necho second\u{1B}[201~\u{1B}[A\u{1B}OD\r".utf8) {
            transcript.appendInput([byte])
        }
        XCTAssertEqual(transcript.lines, ["$ echo 中文", "$ echo second"])
    }

    func testProgressUpdatesAreVisibleBeforeNewlineAndCRLFDoesNotEraseThem() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("progress 10%\r".utf8))
        transcript.appendOutput(Array("done".utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "done")
        transcript.appendOutput([0x0D])
        transcript.appendOutput([0x0A])
        XCTAssertEqual(transcript.lines, ["done"])
    }

    func testBackspaceRemovesWholeGraphemeAndControlUClearsInput() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("状态🖥️\u{08}好\n".utf8))
        transcript.appendInput(Array("discard\u{15}echo 🖥️\u{7F}好\r".utf8))
        XCTAssertEqual(transcript.lines, ["状态好", "$ echo 好"])
    }

    func testControlStringsDoNotAccumulatePayloadAndRecoverAtTerminator() {
        let transcript = TerminalTranscript(maxLines: 3, maxHistoryBytes: 64, maxLineBytes: 16)
        transcript.appendOutput(Array("start\u{1B}]52;c;".utf8))
        transcript.appendOutput(Array(String(repeating: "hidden clipboard", count: 10_000).utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "start")
        transcript.appendOutput(Array("\u{07}\u{1B}Pignored\u{1B}\\\u{1B}_also hidden\u{1B}\\end".utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "startend")
    }

    func testIncompleteControlSequenceCanBeCancelledWithoutHidingLaterText() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("left\u{1B}[123;".utf8))
        transcript.appendOutput(Array("\u{18}right\u{1B}(B!".utf8))
        XCTAssertEqual(transcript.tail(maxChars: 100), "leftright!")
    }

    func testMalformedUnicodeIsReplacedConsistentlyAtEveryPacketBoundary() {
        let bytes: [UInt8] = [0xC0, 0xAF, 0xED, 0xA0, 0x80, 0xF4, 0x90, 0x80, 0x80, 0xE2, 0x41]
        let expected = String(decoding: bytes, as: UTF8.self)
        for split in 0...bytes.count {
            let transcript = TerminalTranscript()
            transcript.appendOutput(Array(bytes[..<split]))
            transcript.appendOutput(Array(bytes[split...]))
            XCTAssertEqual(transcript.tail(maxChars: 100), expected)
        }
    }

    func testReconnectRetainsHistoryButDiscardsPartialControlAndInputState() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("old\nlast\u{1B}]0;unfinished".utf8))
        transcript.appendInput(Array("stale command".utf8))
        transcript.beginSession()
        transcript.appendOutput(Array("new\n".utf8))
        transcript.appendInput(Array("fresh\r".utf8))
        XCTAssertEqual(transcript.lines, ["old", "last", "new", "$ fresh"])

        transcript.appendOutput([0xE4, 0xB8])  // Partial old UTF-8 scalar must not join the new stream.
        transcript.beginSession()
        transcript.appendOutput(Array("ready".utf8))
        XCTAssertTrue(transcript.tail(maxChars: 100).hasSuffix("ready"))
        XCTAssertFalse(transcript.tail(maxChars: 100).contains("\u{FFFD}"))
    }

    func testVeryLongUnterminatedOutputAndInputStayWithinByteLimits() {
        let transcript = TerminalTranscript(maxLines: 3, maxHistoryBytes: 64, maxLineBytes: 16)
        transcript.appendOutput(Array((String(repeating: "😀", count: 25_000) + "Z").utf8))
        let output = transcript.tail(maxChars: 100_000)
        XCTAssertLessThanOrEqual(output.utf8.count, 16)
        XCTAssertEqual(transcript.tail(maxChars: 2), "😀Z")
        XCTAssertFalse(output.contains("\u{FFFD}"))
        transcript.appendOutput([0x0A])
        transcript.appendInput(Array((String(repeating: "x", count: 100_000) + "中文\r").utf8))
        XCTAssertLessThanOrEqual(transcript.lines.last?.utf8.count ?? 0, 16)
        XCTAssertTrue(transcript.lines.last?.hasPrefix("$ ") == true)
        XCTAssertTrue(transcript.lines.last?.hasSuffix("中文") == true)
    }

    func testHistoryEvictsOldestLinesByBothCountAndBytes() {
        let transcript = TerminalTranscript(maxLines: 3, maxHistoryBytes: 20, maxLineBytes: 16)
        for value in ["1234567890", "abcdefghij", "new"] {
            transcript.appendOutput(Array((value + "\n").utf8))
        }
        XCTAssertEqual(transcript.lines, ["abcdefghij", "new"])
        for index in 0..<1000 { transcript.appendOutput(Array("\(index)\n".utf8)) }
        XCTAssertEqual(transcript.lines, ["997", "998", "999"])
        XCTAssertLessThanOrEqual(transcript.lines.reduce(0) { $0 + $1.utf8.count }, 20)
    }

    func testSnapshotBudgetIncludesSeparatorsAndDoesNotSplitEmoji() {
        let transcript = TerminalTranscript()
        transcript.appendOutput(Array("older\n👨‍👩‍👧‍👦🖥️Z".utf8))
        let whole = transcript.tail(maxChars: 100)
        for budget in 0...whole.count {
            XCTAssertEqual(transcript.tail(maxChars: budget), String(whole.suffix(budget)))
            XCTAssertLessThanOrEqual(transcript.tail(maxChars: budget).count, budget)
        }
    }

    func testConcurrentWritersAndReadersGetCoherentBoundedSnapshots() {
        let transcript = TerminalTranscript()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            transcript.appendOutput(Array("output-\(index)\n".utf8))
            transcript.appendInput(Array("input-\(index)\r".utf8))
            XCTAssertLessThanOrEqual(transcript.tail(maxChars: 40).count, 40)
        }
        let expected = Set((0..<200).flatMap { ["output-\($0)", "$ input-\($0)"] })
        XCTAssertEqual(transcript.lines.count, 400)
        XCTAssertEqual(Set(transcript.lines), expected)
    }
}
