import Foundation

/// 只过滤本次 shell 初始化命令的 TTY 回显；允许回显被分片、自动换行或 ANSI 重绘打断。
struct TerminalHookEchoFilter {
    private var expected: [UInt8] = []
    private var matched = 0
    private var armedAt = Date.distantPast
    private var escapeState = 0

    mutating func arm(_ line: String, now: Date = Date()) {
        expected = Array(line.trimmingCharacters(in: .newlines).utf8)
        matched = 0
        escapeState = 0
        armedAt = now
    }

    mutating func disarm() {
        expected = []
        matched = 0
        escapeState = 0
    }

    mutating func filter(_ input: [UInt8], now: Date = Date()) -> [UInt8] {
        guard !expected.isEmpty else { return input }
        guard now.timeIntervalSince(armedAt) < 30 else {
            disarm()
            return input
        }
        var output: [UInt8] = []
        for byte in input {
            if expected.isEmpty {
                output.append(byte)
                continue
            }
            // Readline 可能在长行回显中插入光标控制序列；这些不是命令内容。
            if escapeState != 0 {
                switch escapeState {
                case 1: escapeState = byte == 0x5B ? 2 : (byte == 0x5D ? 3 : 0)
                case 2: if (0x40...0x7E).contains(byte) { escapeState = 0 }
                case 3: if byte == 0x07 { escapeState = 0 } else if byte == 0x1B { escapeState = 4 }
                default: escapeState = byte == 0x5C ? 0 : 3
                }
                continue
            }
            if matched > 0, byte == 0x1B {
                escapeState = 1
                continue
            }
            if byte == expected[matched] {
                matched += 1
                if matched == expected.count { disarm() }
                continue
            }
            if matched > 0, byte == 0x08 || byte == 0x0D || byte == 0x0A { continue }
            if matched > 0 {
                output.append(contentsOf: expected[..<matched])
                matched = 0
            }
            if byte == expected[0] {
                matched = 1
                if matched == expected.count { disarm() }
            } else {
                output.append(byte)
            }
        }
        return output
    }
}

