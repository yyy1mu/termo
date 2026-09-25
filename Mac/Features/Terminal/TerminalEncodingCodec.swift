import Foundation

/// One codec belongs to one terminal channel. Each direction has independent stream state.
final class TerminalEncodingCodec: @unchecked Sendable {
    struct UnsupportedEncoding: LocalizedError {
        let name: String
        var errorDescription: String? { String(localized: "当前系统不支持终端编码：\(name)") }
    }

    private let decoder: OpaquePointer?
    private let encoder: OpaquePointer?

    init(name: String) throws {
        let normalized = name.isEmpty ? "UTF-8" : name
        guard normalized.caseInsensitiveCompare("UTF-8") != .orderedSame else {
            decoder = nil
            encoder = nil
            return
        }
        decoder = normalized.withCString { termo_text_transcoder_new($0, "UTF-8") }
        encoder = normalized.withCString { termo_text_transcoder_new("UTF-8", $0) }
        guard decoder != nil, encoder != nil else {
            if let decoder { termo_text_transcoder_free(decoder) }
            if let encoder { termo_text_transcoder_free(encoder) }
            throw UnsupportedEncoding(name: normalized)
        }
    }

    func decode(_ bytes: [UInt8]) -> [UInt8] {
        transcode(bytes, using: decoder)
    }

    func encode(_ bytes: [UInt8]) -> [UInt8] {
        transcode(bytes, using: encoder)
    }

    private func transcode(_ bytes: [UInt8], using transcoder: OpaquePointer?) -> [UInt8] {
        guard let transcoder, !bytes.isEmpty else { return bytes }
        var output = [UInt8](repeating: 0, count: max(64, bytes.count * 4 + 32))
        let count = bytes.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                termo_text_transcoder_push(
                    transcoder, input.baseAddress, Int32(input.count),
                    destination.baseAddress, Int32(destination.count))
            }
        }
        guard count >= 0 else { return Array("�".utf8) }
        return Array(output.prefix(Int(count)))
    }

    deinit {
        if let decoder { termo_text_transcoder_free(decoder) }
        if let encoder { termo_text_transcoder_free(encoder) }
    }
}
