import AppKit
import SwiftTerm
import SwiftUI
import TermoEngine
import TermoCore

extension AppModel {
    // ---------- 终端 ----------
    func terminalView(for tabId: Int) -> LocalProcessTerminalView {
        if let tv = terminals[tabId] { return tv }
        let hostId = tabs.first(where: { $0.id == tabId })?.hostId
        // .ask 的本会话密码已在 host.ssh 内。
        let conn = hostId.flatMap { hid in hosts.first(where: { $0.id == hid })?.ssh }
        let tv = makeTerminal(ssh: conn, hostId: hostId, tabId: tabId)
        terminals[tabId] = tv
        return tv
    }

    func handleTerminalCwd(tabId: Int, path: String) {
        // 收到 OSC 7 说明登录后提示符已就绪，是最可靠的「已连上」信号：断线态据此即时恢复。
        if let c = terminalConns[tabId], c.phase == .dropped { c.phase = .live; c.attempt = 0 }
        guard tabCwd[tabId] != path else { return }  // 去重：同一目录不重复更新（OSC 7 每次提示符都会发）
        tabCwd[tabId] = path
    }

    /// 当前终端字体（按设置；空名或找不到则回退到预置等宽字体）。
    func currentTerminalFont() -> NSFont {
        let size = CGFloat(AppSettings.shared.termFontSize)
        let name = AppSettings.shared.termFont
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        for n in [
            "JetBrainsMono Nerd Font", "MesloLGM Nerd Font", "MesloLGS Nerd Font",
            "Hack Nerd Font", "FiraCode Nerd Font", "FiraCode Nerd Font Mono",
        ] {
            if let f = NSFont(name: n, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 按设置（形状 + 闪烁）得到 SwiftTerm 光标样式。
    func currentCursorStyle() -> CursorStyle {
        let blink = AppSettings.shared.termCursorBlink
        switch AppSettings.shared.termCursorStyle {
        case "bar": return blink ? .blinkBar : .steadyBar
        case "underline": return blink ? .blinkUnderline : .steadyUnderline
        default: return blink ? .blinkBlock : .steadyBlock
        }
    }

    /// 应用光标样式与滚动缓冲到某终端。
    func applyTerminalConfig(to tv: LocalProcessTerminalView) {
        let term = tv.getTerminal()
        term.setCursorStyle(currentCursorStyle())
        term.changeScrollback(AppSettings.shared.termScrollback)
    }

    /// 设置变化时刷新所有终端的字体/光标/滚动缓冲。
    func applyTerminalSettings() {
        let font = currentTerminalFont()
        for tv in terminals.values {
            tv.font = font
            applyTerminalConfig(to: tv)
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    func applyTheme(to tv: LocalProcessTerminalView) {
        let t = ThemeManager.shared.colors
        tv.installColors(TerminalPalette.colors(isDark: ThemeManager.shared.isDark))
        tv.nativeBackgroundColor = NSColor(hex: t.termBg)
        tv.nativeForegroundColor = NSColor(hex: t.termFg)
        tv.selectedTextBackgroundColor = NSColor(hex: t.termSelection)
        tv.caretColor = NSColor(hex: t.termCaret)
        tv.caretTextColor = NSColor(hex: t.termBg)
    }

    func applyThemeToTerminals() {
        for tv in terminals.values {
            applyTheme(to: tv)
            // 强制全屏重绘，清掉旧的不透明像素
            tv.getTerminal().updateFullScreen()
            tv.setNeedsDisplay(tv.bounds)
        }
    }

    func makeTerminal(
        ssh: SSHConnection? = nil, hostId: String? = nil, tabId: Int
    ) -> LocalProcessTerminalView {
        // PacedTerminalView：重写粘贴为分片限速 + 括号粘贴，根治粘贴长命令被远端 tty 灌爆而截断/错行。
        let tv = PacedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        // SwiftTerm 内建 legacy 滚动条；改成覆盖式并在滚动停止后自动淡出。
        tv.configureTransientScroller()
        tv.font = currentTerminalFont()
        applyTheme(to: tv)
        applyTerminalConfig(to: tv)

        if let ssh {
            terminalConns[tabId] = TerminalConn()  // Register state before any driver can report ready.
            // SSH 终端：引擎驱动接管输入/输出/cwd/退出（见 startTerminalProcess），不起本地子进程。
            startTerminalProcess(
                tv: tv, ssh: ssh, tabId: tabId, hostId: hostId,
                command: terminalCommands[tabId])
        } else {
            // 本地终端：仍走 LocalProcessTerminalView 的本地 shell 子进程（仅 Dev ID 构建启用）。
            let d = TerminalSessionDelegate()
            d.onTerminated = { [weak self] code in
                Task { @MainActor in self?.handleTerminalExit(tabId: tabId, hostId: nil, exitCode: code) }
            }
            tv.processDelegate = d
            termDelegates[tabId] = d
            var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
            let lang = ProcessInfo.processInfo.environment["LANG"] ?? ""
            if !lang.uppercased().contains("UTF-8") { env.append("LANG=en_US.UTF-8") }
            // 在用户家目录启动（与系统终端一致）；否则会继承 App 进程的工作目录——
            // Xcode 调试时是 .../Build/Products/Debug（提示符里冒出 "Debug"），打包运行时是 "/"。
            tv.startProcess(
                executable: AppSettings.shared.resolvedShell, args: ["-l"], environment: env,
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        return tv
    }

    /// 在给定终端视图上（重新）发起 SSH 连接：驱动经该主机的 [[SSHConnectionHub]] 取共享会话
    /// （已有存活连接则只开新 shell 通道，不再登录）。普通连接不向交互 shell 的 stdin 注入任何内容；
    /// 用户配置的默认目录/初始命令通过 PTY+exec 执行，然后切换到交互式登录 shell。
    /// 重连复用同一终端视图，滚动历史得以保留——先关旧驱动（停 pump + 释放通道）再建新驱动。
    func startTerminalProcess(tv: LocalProcessTerminalView, ssh: SSHConnection, tabId: Int, hostId: String?) {
        startTerminalProcess(tv: tv, ssh: ssh, tabId: tabId, hostId: hostId, command: nil)
    }

    /// command 非空 → 该标签的通道走 PTY+exec（tmux 接入），不经登录 shell（无 history 污染、
    /// 不影响同主机其它标签里的 tmux 客户端）；重连时沿用同一命令（掉线重进同一 tmux 会话）。
    func startTerminalProcess(
        tv: LocalProcessTerminalView, ssh: SSHConnection, tabId: Int, hostId: String?, command: String?
    ) {
        (tv as? PacedTerminalView)?.cancelPendingPaste()
        termDrivers[tabId]?.onTerminated = nil  // 旧驱动退出回调失效，避免拆除时误触重连
        termDrivers[tabId]?.close()
        let term = tv.getTerminal()
        let hub = SSHSessionPool.shared.connectionHub(for: ssh)
        let driver = SSHTerminalDriver(
            tv: tv, ssh: ssh, hub: hub,
            transcript: TerminalTranscriptStore.shared.transcript(for: tabId))
        driver.onCwd = { [weak self, weak driver] path in
            Task { @MainActor in
                guard let self, let driver, self.termDrivers[tabId] === driver else { return }
                self.handleTerminalCwd(tabId: tabId, path: path)
            }
        }
        driver.onReady = { [weak self, weak driver] in
            guard let self, let driver, self.termDrivers[tabId] === driver,
                let conn = self.terminalConns[tabId]
            else { return }
            conn.phase = .live
            conn.attempt = 0
            if let hostId, let host = self.host(hostId) { self.ensureHostMonitoring(host) }
        }
        driver.onTerminated = { [weak self, weak driver] code in
            Task { @MainActor in
                guard let self, let driver, self.termDrivers[tabId] === driver else { return }
                self.handleTerminalExit(tabId: tabId, hostId: hostId, exitCode: code)
            }
        }
        tv.terminalDelegate = driver  // 接管输入/resize/cwd（替代 LocalProcessTerminalView 自身）
        termDrivers[tabId] = driver
        let startupCommand = command ?? TerminalShellIntegration.startupCommand(for: ssh)
        driver.connect(cols: term.cols, rows: term.rows, command: startupCommand)
    }

    /// 视图层取某终端标签的连接态（断线覆盖层观察它）。
    func terminalConn(for tabId: Int) -> TerminalConn? { terminalConns[tabId] }

    func handleTerminalExit(tabId: Int, hostId: String?, exitCode: Int32?) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        // 仅在「SSH 终端 + 连接断开（255）」时保留标签重连。退出码非 255（含用户 exit、被信号杀）一律关闭，
        // 不以离线状态判定，否则离线时主动 exit 会被误当掉线。本地终端无 TerminalConn，落到关闭分支。
        if let hostId, let conn = terminalConns[tabId], exitCode == 255,
            hosts.contains(where: { $0.id == hostId })
        {
            conn.phase = .dropped
            conn.reconnectStatus = NetworkMonitor.shared.isOnline ? .scheduled : .waitingForNetwork
            scheduleTerminalReconnect(tabId: tabId, hostId: hostId)
            return
        }
        performCloseTab(tabId)
        if let hostId, let host = hosts.first(where: { $0.id == hostId }) {
            let stillUsed = tabs.contains {
                ($0.kind == .terminal || $0.kind == .files) && $0.hostId == hostId
            }
            // 注：「每次询问」的本会话密码保留在 host.ssh 内、整个 App 运行期有效（冷启动才清），关标签不清除。
            // 工作区不再使用时请求回收；连接层仍会保护其他功能持有的操作。
            if !stillUsed, !hostHasRunningTransfer(hostId) {
                SSHSessionPool.shared.closeIdleConnection(for: host.ssh ?? SSHConnection())
            }
        }
    }

    /// 退避重连：离线时不试（等网络恢复回调触发），在线时按失败次数递增延迟（封顶 15 秒）后重连。
    /// 先撤销该标签已挂起的重连，确保同一时刻只排一个，避免反复掉线时叠加多次并发重连。
    func scheduleTerminalReconnect(tabId: Int, hostId: String) {
        guard let conn = terminalConns[tabId] else { return }
        guard NetworkMonitor.shared.isOnline else {
            conn.reconnectStatus = .waitingForNetwork
            return
        }
        conn.reconnectStatus = .scheduled
        terminalReconnectWork[tabId]?.cancel()
        let delay = min(15.0, 2.0 * Double(conn.attempt + 1))
        let work = DispatchWorkItem { [weak self] in
            self?.terminalReconnectWork[tabId] = nil
            self?.reconnectTerminal(tabId: tabId, hostId: hostId)
        }
        terminalReconnectWork[tabId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 在原终端视图上重发 SSH 连接。只有 shell 通道打开或收到 OSC 7 才确认已连；
    /// 单纯等待一段时间不能证明重连成功。
    func reconnectTerminal(tabId: Int, hostId: String) {
        terminalReconnectWork[tabId]?.cancel()  // 立即重连（手动/网络恢复）撤销可能挂起的退避重连
        terminalReconnectWork[tabId] = nil
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
            tabs.contains(where: { $0.id == tabId }),
            let tv = terminals[tabId],
            let host = hosts.first(where: { $0.id == hostId }), let ssh = host.ssh
        else { return }
        guard NetworkMonitor.shared.isOnline else {
            conn.reconnectStatus = .waitingForNetwork
            return
        }
        conn.attempt += 1
        conn.reconnectStatus = .connecting
        startTerminalProcess(
            tv: tv, ssh: ssh, tabId: tabId, hostId: hostId,
            command: terminalCommands[tabId])  // 重连沿用同一命令（tmux 接入掉线重进同一会话）
    }

    /// 网络恢复时立即重连所有断开的终端（清零退避）。先快照，避免重连过程中字典被改动。
    func reconnectDroppedTerminals() {
        let dropped = terminalConns.filter { $0.value.phase == .dropped }
        for (tabId, conn) in dropped {
            conn.attempt = 0
            if let hostId = tabs.first(where: { $0.id == tabId })?.hostId {
                reconnectTerminal(tabId: tabId, hostId: hostId)
            }
        }
    }

    /// 断线覆盖层「立即重连」按钮。
    func manualReconnectTerminal(_ tabId: Int) {
        guard let conn = terminalConns[tabId], conn.phase == .dropped,
            let hostId = tabs.first(where: { $0.id == tabId })?.hostId
        else { return }
        conn.attempt = 0
        reconnectTerminal(tabId: tabId, hostId: hostId)
    }

}
