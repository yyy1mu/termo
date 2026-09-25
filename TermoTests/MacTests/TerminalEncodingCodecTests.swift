import XCTest

@testable import Termo

final class TerminalEncodingCodecTests: XCTestCase {
    func testEveryPresentedEncodingIsSupportedByTheRuntime() throws {
        for option in SSHOptions.encodings {
            XCTAssertNoThrow(try TerminalEncodingCodec(name: option.value), option.value)
        }
    }

    func testLegacyMultibyteTextSurvivesOneByteNetworkChunks() throws {
        let codec = try TerminalEncodingCodec(name: "GB18030")
        let encoded = codec.encode(Array("你好，Termo".utf8))
        XCTAssertFalse(encoded.isEmpty)
        let decoded = encoded.flatMap { codec.decode([$0]) }
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "你好，Termo")
    }

    func testTerminalControlBytesRemainUnchanged() throws {
        let codec = try TerminalEncodingCodec(name: "Big5")
        let control = Array("\u{1B}[31mred\u{1B}[0m\r\n".utf8)
        XCTAssertEqual(codec.decode(codec.encode(control)), control)
    }

    func testUTF8ConfigurationIsAnExactPassThrough() throws {
        let codec = try TerminalEncodingCodec(name: "UTF-8")
        let bytes: [UInt8] = [0, 3, 27, 0xF0, 0x9F, 0x98, 0x80]
        XCTAssertEqual(codec.encode(bytes), bytes)
        XCTAssertEqual(codec.decode(bytes), bytes)
    }
}
