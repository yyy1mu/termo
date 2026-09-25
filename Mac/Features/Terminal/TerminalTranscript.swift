import Foundation

/// Bounded, best-effort terminal text for an explicitly attached Chat snapshot.
/// Output and user input have separate stream decoders; all parser and storage state shares one lock.
/// Cursor-addressed screen contents remain SwiftTerm's responsibility, not this transcript's.
final class TerminalTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLineBytes: Int
    private var history: History
    private var outputDecoder = TerminalTextDecoder()
    private var inputDecoder = TerminalTextDecoder()
    private var pending = ""
    private var typed = ""
    private var outputCarriageReturn = false
    private var inputCarriageReturn = false

    /// Retained text: at most 256 KiB of completed lines plus two 16 KiB current lines.
    /// Byte limits also bound unusually long Unicode grapheme clusters and newline-free output.
    init(maxLines: Int = 1000, maxHistoryBytes: Int = 256 * 1024, maxLineBytes: Int = 16 * 1024) {
        precondition(maxLines > 0 && maxLineBytes >= 4 && maxHistoryBytes >= maxLineBytes)
        self.maxLineBytes = maxLineBytes
        history = History(maxLines: maxLines, maxBytes: maxHistoryBytes)
    }

    /// A snapshot, never a reference to mutable storage accessed outside the lock.
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return history.lines
    }

    /// A reconnect keeps history but cannot complete an old partial escape, scalar or input command.
    func beginSession() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { history.append(pending) }
        pending = ""
        typed = ""
        outputDecoder = TerminalTextDecoder()
        inputDecoder = TerminalTextDecoder()
        outputCarriageReturn = false
        inputCarriageReturn = false
    }

    func appendOutput(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let text = outputDecoder.decode(bytes)
        var start = text.startIndex
        for index in text.unicodeScalars.indices {
            let scalar = text.unicodeScalars[index]
            guard scalar.value < 0x20 && scalar != "\t" || scalar.value == 0x7F else { continue }
            appendOutputText(text[start..<index])
            switch scalar {
            case "\r": outputCarriageReturn = true
            case "\n":
                history.append(pending)
                pending = ""
                outputCarriageReturn = false
            case "\u{08}", "\u{7F}":
                if !outputCarriageReturn, !pending.isEmpty { pending.removeLast() }
            default: break
            }
            start = text.unicodeScalars.index(after: index)
        }
        appendOutputText(text[start...])
    }

    private func appendOutputText(_ text: Substring) {
        guard !text.isEmpty else { return }
        // A CR followed by LF commits the line; CR followed by text is a progress-line replacement.
        if outputCarriageReturn { pending = ""; outputCarriageReturn = false }
        pending = Self.appending(text, to: pending, maxBytes: maxLineBytes)
    }

    /// Input is approximate: editable text and submitted lines, without arrow-key/paste control payloads.
    func appendInput(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        let text = inputDecoder.decode(bytes)
        var start = text.startIndex
        for index in text.unicodeScalars.indices {
            let scalar = text.unicodeScalars[index]
            guard scalar.value < 0x20 || scalar.value == 0x7F else { continue }
            appendInputText(text[start..<index])
            switch scalar {
            case "\r", "\n":
                if !(scalar == "\n" && inputCarriageReturn), !typed.isEmpty { history.append("$ " + typed) }
                typed = ""
                inputCarriageReturn = scalar == "\r"
            case "\u{7F}", "\u{08}":
                if !typed.isEmpty { typed.removeLast() }
                inputCarriageReturn = false
            case "\u{03}", "\u{15}":
                typed = ""
                inputCarriageReturn = false
            default: break
            }
            start = text.unicodeScalars.index(after: index)
        }
        appendInputText(text[start...])
    }

    private func appendInputText(_ text: Substring) {
        guard !text.isEmpty else { return }
        typed = Self.appending(text, to: typed, maxBytes: maxLineBytes - 2)  // Reserve the "$ " prefix.
        inputCarriageReturn = false
    }

    /// Exact character budget, including separators. Never returns a broken grapheme or oversized single line.
    func tail(maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        lock.lock()
        defer { lock.unlock() }
        let visible = pending.isEmpty ? history.lines : history.lines + [pending]
        var parts: [String] = []
        var remaining = maxChars
        for line in visible.reversed() {
            if !parts.isEmpty {
                guard remaining > 0 else { break }
                remaining -= 1  // The separator before the newer line.
            }
            let part = String(line.suffix(remaining))
            parts.append(part)
            remaining -= part.count
            if part.count < line.count { break }
        }
        return parts.reversed().joined(separator: "\n")
    }

    private static func appending(_ text: Substring, to previous: String, maxBytes: Int) -> String {
        let value = text.utf8.count >= maxBytes ? String(text) : previous + text
        guard value.utf8.count > maxBytes else { return value }
        // The input ends on a scalar boundary. Skip any continuation bytes at the new beginning.
        let suffix = value.utf8.suffix(maxBytes).drop(while: { $0 & 0xC0 == 0x80 })
        return String(decoding: suffix, as: UTF8.self)
    }

    /// Fixed-capacity ring: evicted strings are released immediately, without shifting the whole history.
    private struct History {
        private var slots: [String?]
        private let maxBytes: Int
        private var head = 0
        private var count = 0
        private var bytes = 0

        init(maxLines: Int, maxBytes: Int) {
            slots = Array(repeating: nil, count: maxLines)
            self.maxBytes = maxBytes
        }

        var lines: [String] { (0..<count).compactMap { slots[(head + $0) % slots.count] } }

        mutating func append(_ line: String) {
            let size = line.utf8.count
            while count > 0 && (count == slots.count || bytes + size > maxBytes) {
                bytes -= slots[head]?.utf8.count ?? 0
                slots[head] = nil
                head = (head + 1) % slots.count
                count -= 1
            }
            slots[(head + count) % slots.count] = line
            count += 1
            bytes += size
        }
    }
}

/// Transcript 注册表（Multiton）：按终端标签持有，关标签即回收；AI 对话另按主机作用域保存。
@MainActor
final class TerminalTranscriptStore {
    static let shared = TerminalTranscriptStore()
    private init() {}

    private var items: [Int: TerminalTranscript] = [:]

    /// 终端启动时获取/创建。
    func transcript(for tabId: Int) -> TerminalTranscript {
        if let t = items[tabId] { return t }
        let t = TerminalTranscript()
        items[tabId] = t
        return t
    }

    /// 读取（不创建）：AI 上下文用，没记录过则 nil。
    func existing(_ tabId: Int) -> TerminalTranscript? { items[tabId] }

    func discard(tabId: Int) { items.removeValue(forKey: tabId) }
}
