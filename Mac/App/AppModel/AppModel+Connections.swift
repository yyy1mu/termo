import AppKit
import Foundation
import TermoEngine
import TermoCore

extension AppModel {
    func applyStartupIfNeeded() {
        guard !didApplyStartup else { return }
        didApplyStartup = true
        switch AppSettings.shared.startupBehavior {
        case .terminal:
            if AppEnv.localTerminalEnabled { openLocalTerminal() }  // MAS 沙盒下无本地终端 → 落欢迎页
        case .welcome:
            // 欢迎页为默认（标签为空时即显示）
            break
        }
    }

    /// 打开一个绑定 tmux 会话的终端标签：通道 PTY+exec `tmux attach -t =name`。
    /// 不注入文本到任何既有标签——不影响其它 tmux 会话的客户端、不经登录 shell（零 history 污染）。
    /// 掉线重连自动重进同一 tmux 会话；用户在 tmux 里 exit/detach → 通道结束 → 标签关闭（同 ssh 行为）。
    func openTmuxSessionTab(host: Host, sessionName: String) {
        requireAuth(host) { [weak self] in
            self?.addTmuxSessionTab(host: host, sessionName: sessionName)
        }
    }

    func addTmuxSessionTab(host: Host, sessionName: String) {
        let title = "tmux: \(sessionName)"
        // 命令必须先于标签发布：Workspace 看到标签后会立即懒创建终端视图。
        // 「=name」为 tmux 精确匹配；掉线重连沿用同一 PTY+exec 命令。
        addTab(
            .terminal, title: title, hostId: host.id,
            terminalCommand: "tmux attach -t \(Self.shellEscape("=" + sessionName))")
        recordSession(hostId: host.id, kind: .terminal, detail: "tmux: \(sessionName)")
    }

    /// 单引号 shell 转义（' → '\''）：会话名可含空格/$/反引号等，拼进命令前必须转义。
    static func shellEscape(_ name: String) -> String {
        "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 指定终端的命令/输出记录尾部（AI 上下文用）；无记录返回 nil。
    func transcriptTail(tabId: Int, maxChars: Int = 4000) -> String? {
        TerminalTranscriptStore.shared.existing(tabId)?.tail(maxChars: maxChars)
    }

    // ---------- 标签操作 ----------
    func openLocalTerminal() {
        let title = uniqueTabTitle(String(localized: "终端", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { $0.kind == .terminal && $0.hostId == nil }
        addTab(.terminal, title: title, hostId: nil)
    }

    func openHost(_ host: Host) {
        if activeHostId == host.id,
            tabs.contains(where: { $0.id == activeTabId && $0.kind == .terminal })
        {
            layoutModel.rightPanel = .monitor
            return
        }
        if let terminal = tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id }) {
            activeTabId = terminal.id
            layoutModel.rightPanel = .monitor
            return
        }
        if let existing = tabs.first(where: { $0.kind == .overview && $0.hostId == host.id }) {
            activeTabId = existing.id
            layoutModel.rightPanel = .monitor
            return
        }
        addTab(.overview, title: host.name, hostId: host.id)
        layoutModel.rightPanel = .monitor
    }

    /// 打开终端：默认复用该主机已打开的终端标签（不新建）；forceNew=true 则强制新建（右键「新建终端」）。
    /// 该身份已有存活 SSH 连接时，新建走通道复用：跳过密码/连接验证弹窗，不重新 SSH 登录。
    func openHostTerminal(_ host: Host, forceNew: Bool = false) {
        if !forceNew, let existing = tabs.first(where: { $0.kind == .terminal && $0.hostId == host.id }) {
            activeTabId = existing.id
            return
        }
        if let ssh = self.host(host.id)?.ssh, SSHSessionPool.shared.hasLiveSession(ssh) {
            openTerminalTab(host.id)
            return
        }
        requireAuth(host) { [weak self] in
            self?.connectThen(host.id, hint: String(localized: "正在进入终端…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { self?.openTerminalTab(host.id) }
        }
    }

    /// 闸门：若是「每次询问」且本会话还没输入过密码 → 先弹密码框（确认后执行 action）；否则直接执行。
    /// 适用于终端 / 文件 / 端口转发等所有需要 SSH 凭证的入口。
    /// **始终按 id 取最新 host 判断**：调用方常传旧快照（不含本会话已缓存的密码），用快照判断会重复弹框。
    func requireAuth(_ host: Host, _ action: @escaping () -> Void) {
        guard !AppLockManager.shared.isLocked, !connectionFlow.isBusy,
            let idx = hosts.firstIndex(where: { $0.id == host.id }), let ssh = hosts[idx].ssh
        else { return }
        var errorMessage: String?
        if ssh.authMethod == .password, ssh.password.isEmpty {
            do {
                if let saved = try HostStore.savedPasswords(for: [hosts[idx]])[host.id] {
                    hosts[idx].ssh?.password = saved
                    sessionOnlyHostPasswords.remove(host.id)
                }
            } catch {
                errorMessage = String(localized: "已保存的密码暂时无法读取：\(error.localizedDescription)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
        }
        let live = hosts[idx]
        if live.ssh?.authMethod != .key, (live.ssh?.password ?? "").isEmpty {
            connectionFlow.askPassword(for: live, error: errorMessage, then: action)
            return
        }
        action()
    }

    /// Open the existing credential prompt only after the user asks to approve an AI action.
    func prepareAIAuthentication(hostID: String, completion: @escaping () -> Void) {
        guard !AppLockManager.shared.isLocked, !connectionFlow.isBusy, let host = host(hostID) else { return }
        requireAuth(host, completion)
    }

    /// Assistant execution never opens a terminal and never sends credentials to the LLM.
    func aiExecutionConnection(hostID: String) throws -> SSHConnection {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }), var ssh = hosts[index].ssh else {
            throw AICommandService.ApprovalError(message: String(localized: "主机已删除。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        if ssh.authMethod != .key, ssh.password.isEmpty {
            if let saved = try HostStore.savedPasswords(for: [hosts[index]])[hostID] {
                ssh.password = saved
                hosts[index].ssh?.password = saved
            }
            guard !ssh.password.isEmpty else {
                throw AICommandService.ApprovalError(
                    message: String(localized: "请先在主机设置中保存登录凭证，或连接一次主机后再确认。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            }
        }
        return ssh
    }

    /// 用户显式选择保存才写钥匙串并改为密码认证；临时值只在当前会话内使用。
    @discardableResult
    func submitAskAuth(requestID: UUID, password: String, remember: Bool = false) -> Bool {
        connectionFlow.submitPassword(id: requestID, password: password) { host in
            guard let idx = hosts.firstIndex(where: { $0.id == host.id }) else { return false }
            if remember {
                var saved = hosts
                saved[idx].ssh?.password = password
                saved[idx].ssh?.authMethod = .password
                let temporary = sessionOnlyHostPasswords.subtracting([host.id])
                guard persistHosts(saved, temporary: temporary) else {
                    connectionFlow.reportPasswordError(hostSaveError, id: requestID)
                    return false
                }
                hosts = saved
                sessionOnlyHostPasswords = temporary
                hostCredentialNotice = String(localized: "密码已保存，下次自动登录，并随加密备份同步。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            } else {
                hosts[idx].ssh?.password = password
                sessionOnlyHostPasswords.insert(host.id)
                hostSaveError = nil
                hostCredentialNotice = String(localized: "密码仅用于本次会话，不会保存或同步。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
            return true
        }
    }

    /// ConnectionTester owns fingerprint verification and authentication; one request owns the dialog.
    func connectThen(
        _ hostId: String, hint: String = String(localized: "正在进入终端…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), _ then: @escaping () -> Void
    ) {
        guard let host = host(hostId) else { return }
        connectionFlow.connect(to: host, hint: hint, then: then)
    }

    /// 打开终端标签（连接验证成功后调用）。
    func openTerminalTab(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        let title = uniqueTabTitle(host.name) { $0.kind == .terminal && $0.hostId == host.id }
        addTab(.terminal, title: title, hostId: host.id)
        recordSession(hostId: host.id, kind: .terminal, detail: String(localized: "终端会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }

    /// 清掉「每次询问」主机的本会话密码（连接失败/取消时）：下次操作重新询问，并停掉用错误密码的监控。
    func clearAskPassword(_ hostId: String) {
        guard let i = hosts.firstIndex(where: { $0.id == hostId }),
            hosts[i].ssh?.authMethod == .ask || sessionOnlyHostPasswords.contains(hostId)
        else { return }
        hosts[i].ssh?.password = ""
        sessionOnlyHostPasswords.remove(hostId)
        monitoring.stop(hostID: hostId)
    }

    func cancelConnecting(requestID: UUID) {
        if let host = connectionFlow.cancel(id: requestID) { clearAskPassword(host.id) }
    }

    func reconcileConnectionRequests() {
        connectionFlow.reconcile()
        hostTrust.reconcile()
    }

    /// 文件浏览改走右侧伴随面板（SFTP），不再开独立文件标签。
    func openCompanionFiles() {
        layoutModel.rightPanel = .sftp
    }

    /// 首次连接验证主机指纹：已知 → 直接放行；未知 → 弹窗让用户核对后决定。返回是否继续连接。
    func verifyHostKey(_ host: Host) async -> Bool {
        do { return try await hostTrust.verify(host) } catch {
            hostSaveError = String(localized: "主机信任记录未能保存：\(error.localizedDescription)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            return false
        }
    }

}
