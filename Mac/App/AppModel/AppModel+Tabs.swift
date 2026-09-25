import AppKit
import Foundation
import SwiftTerm

extension AppModel {
    func selectTab(_ id: Int) {
        activeTabId = id
    }

    /// Workspace 用 ZStack 全量保活后，切 tab 不再重建视图，makeNSView 也不再自动抢焦点。
    /// 这里在 activeTabId 变化时显式把键盘焦点交给当前 tab，并确保焦点不滞留在已隐藏的会话上（防止键盘打进隐藏的终端）。
    func focusActiveTab() {
        guard let id = activeTabId, let tab = tabs.first(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
            switch tab.kind {
            case .terminal:
                if let tv = self.terminals[id] { (tv.window ?? window)?.makeFirstResponder(tv) }
            default:
                self.resignTabResponderIfNeeded(window)
            }
        }
    }

    /// 仅当当前 first responder 落在某个 tab 视图（终端）里时收回焦点，避免键盘打进隐藏 tab；
    /// 不动侧栏搜索框等无关焦点。
    func resignTabResponderIfNeeded(_ window: NSWindow?) {
        guard let window, let fr = window.firstResponder as? NSView else { return }
        let inTerminal = terminals.values.contains { fr == $0 || fr.isDescendant(of: $0) }
        if inTerminal { window.makeFirstResponder(nil) }
    }

    func closeTab(_ id: Int) {
        if shouldConfirmClose(id) {
            pendingCloseTabId = id
        } else {
            performCloseTab(id)
        }
    }

    func confirmPendingClose() {
        if let id = pendingCloseTabId {
            performCloseTab(id)
        }
        pendingCloseTabId = nil
    }

    func cancelPendingClose() {
        pendingCloseTabId = nil
    }

    /// 在符合条件的现有标签标题内，为 base 取不重复标题：首个用 base，其后追加 " 2"、" 3"…
    func uniqueTabTitle(_ base: String, among predicate: (TabItem) -> Bool) -> String {
        let taken = Set(tabs.filter(predicate).map(\.title))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// 请求重命名标签（弹输入框）。
    func requestRenameTab(_ id: Int) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        pendingTabRename = TabRenameContext(id: id, currentTitle: tab.title)
    }

    /// 终端视图右键「重命名标签」：按视图找回标签再弹输入框。
    func requestRenameTab(terminalView tv: LocalProcessTerminalView) {
        guard let tabId = terminals.first(where: { $0.value === tv })?.key else { return }
        requestRenameTab(tabId)
    }

    /// 终端视图右键「复制会话」：同一主机再开一个终端（经共享连接秒开，不重新登录）。
    /// 本地终端无主机可复用，点了无效。
    func duplicateSession(terminalView tv: LocalProcessTerminalView) {
        guard let tabId = terminals.first(where: { $0.value === tv })?.key,
            let tab = tabs.first(where: { $0.id == tabId }),
            tab.kind == .terminal,
            let host = host(tab.hostId)
        else { return }
        openHostTerminal(host, forceNew: true)
    }

    /// 重命名标签：与其它标签同名则拒绝（便于区分），否则原地改名。
    func renameTab(_ id: Int, to newName: String) {
        pendingTabRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.contains(where: { $0.id != id && $0.title == trimmed }) {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "名称已被占用"),
                message: String(localized: "已有标签使用「\(trimmed)」，换一个名称以便区分。"))
            return
        }
        tabs[idx].title = trimmed
    }

    /// 关闭其它标签 / 关闭全部：逐个走 performCloseTab 完成资源拆除；有需确认的（运行中会话/未保存）先聚合确认一次。
    func closeOtherTabs(keep id: Int) { requestMultiClose(tabs.filter { $0.id != id }.map(\.id)) }
    func closeAllTabs() { requestMultiClose(tabs.map(\.id)) }
    func closeOtherTerminalTabs(keep id: Int) {
        requestMultiClose(tabs.filter { $0.kind == .terminal && $0.id != id }.map(\.id))
    }
    func closeAllTerminalTabs() { requestMultiClose(tabs.filter { $0.kind == .terminal }.map(\.id)) }

    func requestMultiClose(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        if ids.contains(where: { shouldConfirmClose($0) }) {
            pendingMultiClose = MultiCloseContext(ids: ids)
        } else {
            ids.forEach { performCloseTab($0) }
        }
    }

    func confirmMultiClose() {
        pendingMultiClose?.ids.forEach { performCloseTab($0) }
        pendingMultiClose = nil
    }
    func cancelMultiClose() { pendingMultiClose = nil }

    func performCloseTab(_ id: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closedHostId = tabs[idx].hostId
        tabs.remove(at: idx)
        (terminals[id] as? PacedTerminalView)?.cancelPendingPaste()
        // 先清空代理回调，避免拆除触发的退出回调再次回调（重入 / 误触重连）
        if let d = termDelegates[id] { d.onTerminated = nil; d.onCwd = nil }
        // 立即停收，后台释放当前 shell 通道。
        if let drv = termDrivers[id] { drv.onTerminated = nil; drv.onCwd = nil; drv.close() }
        // 终止本地子进程（SIGTERM）并关闭 PTY fd；SSH 终端无子进程，terminate 为无害空操作
        if let tv = terminals[id] {
            tv.process.terminate()
        }
        terminals.removeValue(forKey: id)
        termDelegates.removeValue(forKey: id)
        termDrivers.removeValue(forKey: id)
        // 取消该标签未完成的文件操作并释放浏览/树状态（按标签独立，关即释放）
        fileWorkspace.closeTab(id)
        terminalConns.removeValue(forKey: id)  // 关标签即弃用其连接态
        terminalReconnectWork[id]?.cancel()  // 撤销该标签挂起的重连，避免关闭后仍唤醒
        terminalReconnectWork.removeValue(forKey: id)
        terminalCommands.removeValue(forKey: id)
        AIChatStore.shared.discard(tabId: id)  // 解绑终端；主机 AI 对话保留到删除主机或退出 App
        TerminalTranscriptStore.shared.discard(tabId: id)  // 命令/输出记录一并回收
        tabCwd.removeValue(forKey: id)
        if activeTabId == id {
            activeTabId = tabs.isEmpty ? nil : tabs[min(idx, tabs.count - 1)].id
        }
        if let hid = closedHostId, !tabs.contains(where: { $0.hostId == hid }) {
            fileWorkspace.closeCompanion(hostId: hid)
        }
        if let hid = closedHostId { stopMonitorIfUnused(hid) }
    }

    /// 该终端是否有正在运行的活跃进程，需要确认后再关闭。
    func shouldConfirmClose(_ id: Int) -> Bool {
        guard AppSettings.shared.closeConfirm else { return false }
        guard let tab = tabs.first(where: { $0.id == id }), tab.kind == .terminal else { return false }
        guard let tv = terminals[id] else { return false }

        // SSH 会话：关闭即断开远程连接，始终确认
        if let hid = tab.hostId, hosts.first(where: { $0.id == hid })?.ssh != nil {
            return true
        }
        // 本地终端：比较 PTY 前台进程组与 shell 自身，不同则说明有前台任务在跑
        let fd = tv.process.childfd
        let shellPid = tv.process.shellPid
        guard fd >= 0, shellPid > 0 else { return false }
        let fg = tcgetpgrp(fd)
        return fg > 0 && fg != shellPid
    }

    /// 待关闭标签的标题（用于确认弹窗文案）。
    var pendingCloseTitle: String {
        guard let id = pendingCloseTabId else { return "" }
        return tabs.first(where: { $0.id == id })?.title ?? ""
    }

    /// 关闭确认弹窗标题（按标签类型区分）。
    var pendingCloseDialogTitle: String {
        guard let id = pendingCloseTabId,
            let tab = tabs.first(where: { $0.id == id })
        else { return String(localized: "关闭此标签？") }
        switch tab.kind {
        default: return String(localized: "关闭此终端？")
        }
    }

    /// 关闭确认弹窗正文。
    var pendingCloseDialogMessage: String {
        guard let id = pendingCloseTabId,
            let tab = tabs.first(where: { $0.id == id })
        else { return "" }
        switch tab.kind {
        default: return String(localized: "「\(tab.title)」有正在运行的进程，关闭后进程将被终止。")
        }
    }
}
