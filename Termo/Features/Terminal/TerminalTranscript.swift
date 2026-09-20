import Foundation

/// 每终端一份的命令/输出记录（Transcript）：
/// - 输出：驱动泵线程把原始字节流 ANSI 剥离后按行入环（容量 1000 行——
///   远超 SwiftTerm 可见行数，滚出屏幕的输出也不丢）
/// - 命令：用户键击流经 send(source:) 重建出提交的行，以 "$ " 前缀标记
///   （注入流 sendText 不记录——避免 OSC7 钩子等技术命令污染日志）
/// AI 上下文按字符预算取尾部；读写在不同线程（泵线程写/主线程读），内部加锁。
final class TerminalTranscript {
    private static let maxLines = 1000

    private let lock = NSLock()
    private(set) var lines: [String] = []
    private var pending = ""     // 未成行的输出残段（跨 chunk 拼接）
    private var escCarry = ""    // 跨 chunk 的半截转义序列
    private var typed = ""       // 用户正在输入的行（回显重建，回车提交）

    // MARK: 输出记录（泵线程）

    func appendOutput(_ bytes: [UInt8]) {
        var str = escCarry + String(decoding: bytes, as: UTF8.self)
        escCarry = ""
        // 半截转义序列留到下个 chunk（粗判：末尾孤立 ESC）
        if str.hasSuffix("\u{1B}") {
            escCarry = "\u{1B}"
            str.removeLast()
        }
        str = Self.stripANSI(str)
        lock.lock()
        defer { lock.unlock() }
        pending += str
        var parts = pending.components(separatedBy: "\n")
        pending = parts.popLast() ?? ""
        // \r 造成的同行覆盖（进度条等）只保留最后一段，近似最终显示
        let cleaned = parts.map { $0.components(separatedBy: "\r").last ?? $0 }
        lines.append(contentsOf: cleaned)
        trimLocked()
    }

    // MARK: 输入记录（主线程，用户键击）

    func appendInput(_ bytes: [UInt8]) {
        let chunk = String(decoding: bytes, as: UTF8.self)
        lock.lock()
        defer { lock.unlock() }
        for ch in chunk {
            switch ch {
            case "\r":
                let cmd = typed
                typed = ""
                if !cmd.isEmpty {
                    lines.append("$ " + cmd)
                    trimLocked()
                }
            case "\u{7F}", "\u{08}":
                if !typed.isEmpty { typed.removeLast() }
            case "\u{03}":   // ^C：丢弃正在输入的行
                typed = ""
            default:
                // 控制字符不入记录（方向键/Ctrl 组合等），可打印字符（含中文）记录
                if !ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                    typed.append(ch)
                }
            }
        }
    }

    // MARK: 读取

    /// 按字符预算从尾部取记录（AI 上下文用）。
    func tail(maxChars: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        var out: [String] = []
        var total = 0
        for line in lines.reversed() {
            total += line.count + 1
            if total > maxChars, !out.isEmpty { break }
            out.append(line)
        }
        return out.reversed().joined(separator: "\n")
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lines.isEmpty
    }

    /// 当前行数（命令开始时记偏移用）。
    var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    /// 从偏移起到当前的行（切取某条命令的输出区间）。
    func lines(from offset: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard offset < lines.count else { return [] }
        return Array(lines[offset...])
    }

    // MARK: 私有

    private func trimLocked() {
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    private static let ansiRE: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]")

    static func stripANSI(_ s: String) -> String {
        guard let re = ansiRE else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}

/// 一条命令的完成结果：退出码 + 输出切片（由 OSC 133;D 标记驱动，见 SSHTerminalDriver）。
struct CommandResult {
    let output: String
    let exitCode: Int32
}

/// OSC 133;D 完成标记解析（纯函数，可单测）：输入累计文本与跨 chunk 缓存，
/// 返回 (净化文本, 退出码?)；半截标记留在 carry 里待下个 chunk 再判。
/// 钩子侧见 AppModel.osc7Hook；消费侧见 SSHTerminalDriver。
enum CommandCompletionParser {
    static func extract(text: inout String, carry: inout String) -> Int32? {
        text = carry + text
        carry = ""
        var exit: Int32? = nil
        let pattern = "\u{1B}\\]133;D;(\\d+)\u{1B}\\\\"
        if let re = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = re.matches(in: text, range: range)
            if let last = matches.last, let r = Range(last.range(at: 1), in: text) {
                exit = Int32(text[r])
            }
            text = re.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // 尾部疑似半截标记：留到下 chunk 再判
        if let idx = text.range(of: "\u{1B}]133;", options: .backwards)?.lowerBound {
            carry = String(text[idx...])
            text = String(text[..<idx])
        }
        return exit
    }
}

/// Transcript 注册表（Multiton）：按终端标签持有，关标签回收（与 AIChatStore 同型）。
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
