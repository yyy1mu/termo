import XCTest
@testable import Termo

/// OSC 133;D 完成标记解析：完整/半截/多标记/无标记。
final class CompletionMarkerTests: XCTestCase {

    func test_fullMarker_extractedAndStripped() {
        var carry = ""
        var text = "abc\u{1B}]133;D;42\u{1B}\\def"
        let exit = CommandCompletionParser.extract(text: &text, carry: &carry)
        XCTAssertEqual(exit, 42)
        XCTAssertEqual(text, "abcdef")
        XCTAssertTrue(carry.isEmpty)
    }

    func test_markerSplitAcrossChunks() {
        var carry = ""
        var c1 = "out\u{1B}]133;D;"
        XCTAssertNil(CommandCompletionParser.extract(text: &c1, carry: &carry))
        XCTAssertEqual(c1, "out")
        XCTAssertEqual(carry, "\u{1B}]133;D;")          // 半截留待下 chunk

        var c2 = "7\u{1B}\\prompt"
        let exit = CommandCompletionParser.extract(text: &c2, carry: &carry)
        XCTAssertEqual(exit, 7)
        XCTAssertEqual(c2, "prompt")
    }

    func test_multipleMarkers_lastWins() {
        var carry = ""
        var text = "\u{1B}]133;D;1\u{1B}\\x\u{1B}]133;D;0\u{1B}\\"
        let exit = CommandCompletionParser.extract(text: &text, carry: &carry)
        XCTAssertEqual(exit, 0)
        XCTAssertEqual(text, "x")
    }

    func test_noMarker_textUntouched() {
        var carry = ""
        var text = "plain output\n"
        XCTAssertNil(CommandCompletionParser.extract(text: &text, carry: &carry))
        XCTAssertEqual(text, "plain output\n")
    }

    func test_partialMarkerAtEndNotMistakenAsPlainText() {
        // 尾部出现 \e]133; 但未成完整标记：不得显示，不得吞后续文本
        var carry = ""
        var text = "data\u{1B}]133;"
        XCTAssertNil(CommandCompletionParser.extract(text: &text, carry: &carry))
        XCTAssertEqual(text, "data")
    }
}
