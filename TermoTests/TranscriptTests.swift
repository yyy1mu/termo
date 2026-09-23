import XCTest
@testable import Termo

/// 命令/输出记录：ANSI 剥离、跨 chunk 成行、\r 同行覆盖、命令重建、尾部预算。
final class TranscriptTests: XCTestCase {

    func test_output_stripsANSISequences() {
        let t = TerminalTranscript()
        t.appendOutput(Array("plain \u{1B}[31mred\u{1B}[0m end\n".utf8))
        XCTAssertEqual(t.lines.last, "plain red end")
    }

    func test_output_joinsAcrossChunksUntilNewline() {
        let t = TerminalTranscript()
        t.appendOutput(Array("hel".utf8))
        XCTAssertTrue(t.lines.isEmpty)          // 未成行不入列
        t.appendOutput(Array("lo\nworld\n".utf8))
        XCTAssertEqual(t.lines.suffix(2), ["hello", "world"])
    }

    func test_output_carriageReturnKeepsLastSegment() {
        // 进度条式同行覆盖：只保留 \r 后的最终段
        let t = TerminalTranscript()
        t.appendOutput(Array("downloading 10%\rdownloading 90%\rdone\n".utf8))
        XCTAssertEqual(t.lines.last, "done")
    }

    func test_input_rebuildsSubmittedCommand() {
        let t = TerminalTranscript()
        t.appendInput(Array("ls -l".utf8))
        t.appendInput(Array("a\r".utf8))
        XCTAssertEqual(t.lines.last, "$ ls -la")
    }

    func test_input_backspaceEditsPendingLine() {
        let t = TerminalTranscript()
        t.appendInput(Array("lss\u{7F}\r".utf8))   // "lss" + 退格 + 回车 = "ls"
        XCTAssertEqual(t.lines.last, "$ ls")
    }

    func test_input_ctrlCDiscardsPendingLine() {
        let t = TerminalTranscript()
        t.appendInput(Array("docker run".utf8))
        t.appendInput(Array("\u{03}".utf8))        // ^C：丢弃
        t.appendInput(Array("ls\r".utf8))
        XCTAssertEqual(t.lines.last, "$ ls")
        XCTAssertFalse(t.lines.contains { $0.contains("docker") })
    }

    func test_tail_respectsCharBudgetAndKeepsNewest() {
        let t = TerminalTranscript()
        for i in 1...20 { t.appendOutput(Array("line-\(i) filler-filler-filler\n".utf8)) }
        let tail = t.tail(maxChars: 60)
        XCTAssertTrue(tail.count <= 70)                     // 预算附近（含单行溢出）
        XCTAssertTrue(tail.contains("line-20"))             // 最新的一定在
        XCTAssertFalse(tail.contains("line-1\n"))           // 最旧的被裁掉
    }

    func test_linesFromOffsetSlicesCommandOutput() {
        let t = TerminalTranscript()
        t.appendOutput(Array("before\n".utf8))
        let start = t.lineCount
        t.appendOutput(Array("cmd-echo\nout1\nout2\n".utf8))
        XCTAssertEqual(t.lines(from: start), ["cmd-echo", "out1", "out2"])
    }

    func test_commandCaptureIncludesUnterminatedOutputWithoutOldPrompt() {
        let t = TerminalTranscript()
        t.appendOutput(Array("old output\nroot@host:~# ".utf8))
        let cursor = t.outputCursor()
        t.appendOutput(Array("READY\nuid=0(root)".utf8))
        XCTAssertEqual(t.output(since: cursor), "READY\nuid=0(root)")
    }

    func test_commandCaptureNeverReusesEarlierOutput() {
        let t = TerminalTranscript()
        t.appendOutput(Array("earlier command result\n".utf8))
        let cursor = t.outputCursor()
        XCTAssertEqual(t.output(since: cursor), "")
        t.appendOutput(Array("new result".utf8))
        XCTAssertEqual(t.output(since: cursor), "new result")
    }

    func test_commandCaptureIgnoresSyntheticInputBeforeOldPrompt() {
        let t = TerminalTranscript()
        t.appendOutput(Array("root# ".utf8))
        let cursor = t.outputCursor()
        t.appendInput(Array("id\r".utf8))
        t.appendOutput(Array("id\r\nuid=0(root)".utf8))
        XCTAssertEqual(t.output(since: cursor), "uid=0(root)")
    }

    func test_hookEchoFilterArmsAtInjectionAndHandlesWrappedChunks() {
        var filter = TerminalHookEchoFilter()
        let started = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(String(decoding: filter.filter(Array("Welcome\n".utf8), now: started), as: UTF8.self), "Welcome\n")
        // 模拟连接耗时很久：发送前才武装，不能让建连时间消耗过滤窗口。
        let injected = started.addingTimeInterval(40)
        filter.arm("internal-long-command\n", now: injected)
        let first = filter.filter(Array("user@host$ internal-l".utf8), now: injected)
        let second = filter.filter(Array("ong\r\n-command\r\nready".utf8), now: injected.addingTimeInterval(1))
        XCTAssertEqual(String(decoding: first + second, as: UTF8.self), "user@host$ \r\nready")
    }

    func test_hookEchoFilterPreservesUnrelatedOutputAndExpires() {
        var filter = TerminalHookEchoFilter()
        let now = Date(timeIntervalSince1970: 100)
        filter.arm("hook-command\n", now: now)
        let unrelated = filter.filter(Array("normal output\n".utf8), now: now)
        XCTAssertEqual(String(decoding: unrelated, as: UTF8.self), "normal output\n")
        let expired = filter.filter(Array("hook-command\n".utf8), now: now.addingTimeInterval(31))
        XCTAssertEqual(String(decoding: expired, as: UTF8.self), "hook-command\n")
    }
}
