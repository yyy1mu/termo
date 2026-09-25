import Foundation

/// Incremental text projection for transcripts, not a terminal emulator.
/// Keeps at most one unfinished UTF-8 scalar; control-string payloads are discarded without buffering.
struct TerminalTextDecoder {
    private enum EscapeState { case text, escape, intermediate, csi, osc, oscEscape, string, stringEscape }
    private var escape: EscapeState = .text
    private var utf8: [UInt8] = []
    private var scalarLength = 0

    mutating func decode(_ bytes: [UInt8]) -> String {
        var output = ""
        for byte in bytes {
            if !utf8.isEmpty {
                if (0x80...0xBF).contains(byte) {
                    utf8.append(byte)
                    if utf8.count == scalarLength { flushScalar(into: &output) }
                    continue
                }
                // Invalid continuation: emit replacement text, then process this byte normally.
                flushScalar(into: &output)
            }
            switch byte {
            case 0x00...0x7F:
                consume(Unicode.Scalar(byte), into: &output)
            case 0xC2...0xDF:
                utf8 = [byte]; scalarLength = 2
            case 0xE0...0xEF:
                utf8 = [byte]; scalarLength = 3
            case 0xF0...0xF4:
                utf8 = [byte]; scalarLength = 4
            default:
                consume("\u{FFFD}", into: &output)
            }
        }
        return output
    }

    private mutating func flushScalar(into output: inout String) {
        // The standard decoder rejects overlong, surrogate and out-of-range sequences.
        for scalar in String(decoding: utf8, as: UTF8.self).unicodeScalars { consume(scalar, into: &output) }
        utf8.removeAll(keepingCapacity: true)
    }

    private mutating func consume(_ scalar: Unicode.Scalar, into output: inout String) {
        let value = scalar.value
        // CAN/SUB abort any unfinished escape sequence.
        if value == 0x18 || value == 0x1A { escape = .text; return }
        switch escape {
        case .text:
            switch value {
            case 0x1B: escape = .escape
            case 0x9B: escape = .csi
            case 0x9D: escape = .osc
            case 0x90, 0x98, 0x9E, 0x9F: escape = .string
            case 0x03, 0x08, 0x09, 0x0A, 0x0D, 0x15, 0x7F:
                output.unicodeScalars.append(scalar)  // Line editing is handled by the transcript.
            case 0x00...0x1F, 0x80...0x9F: break
            default: output.unicodeScalars.append(scalar)
            }
        case .escape:
            switch value {
            case 0x1B: break
            case 0x5B, 0x4F: escape = .csi  // CSI and SS3 (cursor/function keys).
            case 0x5D: escape = .osc
            case 0x50, 0x58, 0x5E, 0x5F: escape = .string  // DCS, SOS, PM, APC.
            case 0x20...0x2F: escape = .intermediate
            default: escape = .text
            }
        case .intermediate, .csi:
            if value == 0x1B {
                escape = .escape
            } else if (escape == .csi ? 0x40...0x7E : 0x30...0x7E).contains(value) {
                escape = .text
            } else if value == 0x0A || value == 0x0D {
                output.unicodeScalars.append(scalar)
            }
        case .osc, .string:
            if value == 0x9C || (escape == .osc && value == 0x07) {
                escape = .text
            } else if value == 0x1B {
                escape = escape == .osc ? .oscEscape : .stringEscape
            }
        case .oscEscape, .stringEscape:
            if value == 0x5C || value == 0x9C || (escape == .oscEscape && value == 0x07) {
                escape = .text
            } else if value != 0x1B {
                escape = escape == .oscEscape ? .osc : .string
            }
        }
    }
}
