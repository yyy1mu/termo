import AppKit
import SwiftTerm

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

/// 用 russh 引擎的交互式 shell 驱动一个 SwiftTerm 终端视图：作为 `TerminalView` 的 `terminalDelegate`，
/// 把用户输入/尺寸变化写入远端 PTY，把远端输出 `feed` 回视图——替代 `LocalProcessTerminalView` 起的
/// `/usr/bin/ssh` 子进程（终端类型全仓不变，仅 SSH 终端换掉这条传输层）。
///
/// 一个驱动 = 共享会话（[[TerminalSessionHub]]，同主机终端复用一条连接）上的一个 shell 通道
/// + 一个 C 层非阻塞泵任务（读/写/resize 全在该任务，并发安全）。驱动只持有通道，连接生命周期归 hub。
/// 退出码：远端 shell 退出码；掉线=255，与 ssh 对齐以触发上层重连。
final class SSHTerminalDriver: NSObject, TerminalViewDelegate, @unchecked Sendable {
    private weak var tv: LocalProcessTerminalView?
    private let ssh: SSHConnection
    private let hub: TerminalSessionHub
    private var session: SSHSession?             // hub 的共享会话，close 时只 release 不 close
    private var shell: OpaquePointer?            // TermoSSHShell*
    private var closed = false
    private var terminatedReported = false

    var onCwd: ((String) -> Void)?
    /// 认证和 shell 通道均已成功；不依赖远端 shell 是否支持 OSC 7。
    var onReady: (() -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    /// 该终端的命令/输出记录（见 TerminalTranscript）；nil=不记录。
    var transcript: TerminalTranscript?
    /// 命令完成事件（OSC 133;D 驱动）：携带退出码与输出切片，主线程回调。
    var onCommandCompleted: ((CommandResult) -> Void)?
    /// 命令开始时记录的 transcript 游标（输出切片起点）。
    private var pendingCmdStart: TerminalTranscript.OutputCursor? = nil
    private let echoLock = NSLock()
    private var hookEchoFilter = TerminalHookEchoFilter()

    init(tv: LocalProcessTerminalView, ssh: SSHConnection, hub: TerminalSessionHub,
         transcript: TerminalTranscript? = nil) {
        self.tv = tv
        self.ssh = ssh
        self.hub = hub
        self.transcript = transcript
        super.init()
    }

    // MARK: 连接 / 关闭

    /// 后台取共享会话（无则新建登录）+ 开通道 + 启泵；失败按掉线(255)上报以触发重连。
    /// `initialLine` 在登录后注入（OSC7 钩子 + 可选 cd/初始命令）——仅交互 shell 有效。
    /// `command` 非空 → PTY+exec 该命令（tmux 接入等），不经登录 shell、无 history 污染，initialLine 被忽略。
    func connect(cols: Int, rows: Int, initialLine: String, command: String? = nil) {
        let conn = ssh
        let hub = self.hub
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            guard let session = try? hub.acquire(conn), let raw = session.rawHandle else {
                DispatchQueue.main.async { self.reportClosed(255) }   // 连接失败 → 当掉线触发重连
                return
            }
            let box = Unmanaged.passRetained(self).toOpaque()         // pump 持一份强引用，on_closed 时释放
            var err = [CChar](repeating: 0, count: 256)
            let cmd = command.flatMap { $0.isEmpty ? nil : $0 } ?? nil
            guard let sh = termo_ssh_shell_open(raw, Int32(cols), Int32(rows), cmd,
                                                Self.onData, Self.onClosed, box, &err, 256) else {
                Unmanaged<SSHTerminalDriver>.fromOpaque(box).release()
                hub.invalidate(session)     // 开通道失败：连接多半已死（或不可再用），作废让下次重新登录
                hub.release(session)
                DispatchQueue.main.async { self.reportClosed(255) }
                return
            }
            DispatchQueue.main.async {
                if self.closed || self.terminatedReported { // 建连期间已关闭或通道已掉线
                    termo_ssh_shell_close(sh)
                    if self.terminatedReported { hub.invalidate(session) }
                    hub.release(session)
                    return
                }
                self.session = session
                self.shell = sh
                self.onReady?()
                if command == nil, !initialLine.isEmpty {
                    // 等远端 shell 的 rc 文件加载完，再注入 OSC7 钩子（否则可能被 .bashrc 覆盖）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        guard let self, !self.closed, !self.terminatedReported else { return }
                        // 必须紧贴真正写入的时刻武装；SSH 连接和 shell 启动可能超过过滤超时。
                        self.armEchoSuppression(initialLine)
                        if !self.sendText(initialLine) { self.disarmEchoSuppression() }
                    }
                }
            }
        }
    }

    /// 停泵 + 释放通道 + 归还共享会话引用（连接本身由 hub 在最后一个标签关闭时回收）。幂等。
    func close() {
        guard !closed else { return }
        closed = true
        let sh = shell; shell = nil
        let sess = session; session = nil
        if let sh { termo_ssh_shell_close(sh) }     // 停 pump（join）→ 触发 on_closed 释放 box
        if let sess { hub.release(sess) }
    }

    /// 写入一段文本（初始命令注入用）。
    @discardableResult
    func sendText(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard let shell, !bytes.isEmpty else { return false }
        let previousStart = pendingCmdStart
        if text.hasSuffix("\n") { markCommandStarted() }
        let written = bytes.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                termo_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
        guard written == bytes.count else {
            pendingCmdStart = previousStart
            return false
        }
        return true
    }

    private func reportClosed(_ code: Int32) {
        guard !terminatedReported else { return }
        terminatedReported = true
        // 连接断开（255）且非主动关闭 → 作废共享会话：其上其余 shell 随之断开，各标签重连合并为一次登录。
        if code == 255, !closed, let session { hub.invalidate(session) }
        onTerminated?(code)
    }

    // MARK: 注入行回显抑制
    // 泵回调与主线程写入并行，锁保护状态；只遮盖本次注入的命令回显，不吞正常终端输出。

    private func armEchoSuppression(_ line: String) {
        echoLock.lock()
        hookEchoFilter.arm(line)
        echoLock.unlock()
    }

    private func disarmEchoSuppression() {
        echoLock.lock()
        hookEchoFilter.disarm()
        echoLock.unlock()
    }

    private func filterEcho(_ input: [UInt8]) -> [UInt8] {
        echoLock.lock()
        defer { echoLock.unlock() }
        return hookEchoFilter.filter(input)
    }

    // MARK: OSC 133;D 完成标记（仅泵线程访问）
    // shell 在每次提示符前发出 \e]133;D;<exit>\e\（钩子见 AppModel.osc7Hook）。
    // 命令「开始」不需 shell 钩子：客户端键击/注入时刻已知（markCommandStarted）。
    private var markerCarry = ""

    /// 从 chunk 中剥出完成标记：返回 (净化字节, 退出码?)。半截标记留给下个 chunk。
    private func extractCompletion(_ bytes: [UInt8]) -> ([UInt8], Int32?) {
        var text = markerCarry + String(decoding: bytes, as: UTF8.self)
        markerCarry = ""
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
            markerCarry = String(text[idx...])
            text = String(text[..<idx])
        }
        return (Array(text.utf8), exit)
    }

    private func markCommandStarted() {
        pendingCmdStart = transcript?.outputCursor()
    }

    /// 完成标记到达：从 [命令开始, 完成) 切出输出，去命令行自身，主线程上报。
    private func finishPendingCommand(exitCode: Int32) {
        let start = pendingCmdStart
        pendingCmdStart = nil
        let output = start.flatMap { transcript?.output(since: $0) } ?? ""
        let result = CommandResult(output: output, exitCode: exitCode)
        DispatchQueue.main.async { [weak self] in self?.onCommandCompleted?(result) }
    }

    // MARK: C 回调（pump 线程）

    private static let onData: TermoSSHDataCallback = { ud, bytes, len in
        guard let ud, let bytes, len > 0 else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeUnretainedValue()
        let slice = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(len)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(len)))
        }
        // 1) 先剥 OSC 133;D 完成标记（不进显示/记录）：取出退出码
        let (noMarker, exit) = driver.extractCompletion(slice)
        // 2) 注入行回显抑制（泵线程顺序保证）
        let clean = driver.filterEcho(noMarker)
        if !clean.isEmpty {
            driver.transcript?.appendOutput(clean)   // 输出记录（含滚出屏幕的部分）
            DispatchQueue.main.async { driver.tv?.feed(byteArray: clean[...]) }
        }
        // 3) 完成标记到达 → 切片输出并上报（即使本 chunk 无可见输出也要上报）
        if let exit { driver.finishPendingCommand(exitCode: exit) }
    }

    private static let onClosed: TermoSSHClosedCallback = { ud, code in
        guard let ud else { return }
        let driver = Unmanaged<SSHTerminalDriver>.fromOpaque(ud).takeRetainedValue()   // 平衡 connect 的 passRetained
        DispatchQueue.main.async { driver.reportClosed(code) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let shell, !data.isEmpty else { return }
        transcript?.appendInput(Array(data))   // 用户键击 → 重建命令行记录
        if data.contains(0x0D) { markCommandStarted() }   // 回车 = 命令开始
        data.withUnsafeBufferPointer { bp in
            guard let base = bp.baseAddress else { return }
            _ = base.withMemoryRebound(to: CChar.self, capacity: bp.count) {
                termo_ssh_shell_write(shell, $0, Int32(bp.count))
            }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let shell else { return }
        _ = termo_ssh_shell_resize(shell, Int32(newCols), Int32(newRows))
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        if let p = TerminalSessionDelegate.parsePath(directory) { onCwd?(p) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
