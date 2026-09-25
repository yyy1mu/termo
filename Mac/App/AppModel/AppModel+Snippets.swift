import AppKit
import SwiftUI

extension AppModel {
    // ---------- 代码片段（Snippets）----------
    /// 已有片段分组名（去重、保序），供分组 select 取已有项。
    var snippetGroupNames: [String] {
        var seen: [String] = []
        for s in snippets {
            let g = s.group.trimmingCharacters(in: .whitespaces)
            if !g.isEmpty && !seen.contains(g) { seen.append(g) }
        }
        return seen
    }

    func addSnippet(name: String, content: String, group: String) {
        snippets.append(
            Snippet(name: name.isEmpty ? String(localized: "未命名片段") : name, content: content, group: group))
        SnippetStore.save(snippets)
    }

    func updateSnippet(_ id: String, name: String, content: String, group: String) {
        guard let i = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[i].name = name.isEmpty ? snippets[i].name : name
        snippets[i].content = content
        snippets[i].group = group
        snippets[i].updatedAt = Date()
        SnippetStore.save(snippets)
    }

    func deleteSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        SnippetStore.save(snippets)
        if editingSnippet?.id == snippet.id { editingSnippet = nil }
    }

    /// 复制片段正文到剪贴板。
    func copySnippet(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.content, forType: .string)
    }

    /// 片段的「默认动作」入口（▶ 按钮 / 双击）：按设置决定直接运行 / 仅插入 / 弹框询问。
    /// 右键菜单的「运行」「插入」是显式直达，不走这里。
    func triggerSnippet(_ snippet: Snippet) {
        switch AppSettings.shared.snippetAction {
        case .insert: sendSnippet(snippet, run: false)
        case .run: sendSnippet(snippet, run: true)
        case .ask: pendingSnippetAction = snippet
        }
    }

    /// 「插入/运行」选择弹窗的结果：remember=true 时把选择写入设置（之后不再询问），再发送。
    func resolveSnippetAction(_ snippet: Snippet, run: Bool, remember: Bool) {
        pendingSnippetAction = nil
        if remember { AppSettings.shared.snippetAction = run ? .run : .insert }
        sendSnippet(snippet, run: run)
    }

    func cancelSnippetAction() { pendingSnippetAction = nil }

    /// 发送片段到当前终端：含 {{变量}} 则先弹填值框，否则直接发送。
    /// run=true 末尾补换行（直接执行）；run=false 仅打到提示符（用户确认后自行回车）。
    func sendSnippet(_ snippet: Snippet, run: Bool) {
        let vars = Snippet.variableNames(in: snippet.content)
        if vars.isEmpty {
            deliverSnippet(snippet.content, run: run)
        } else {
            pendingSnippetRun = SnippetRunRequest(snippet: snippet, variables: vars, run: run)
        }
    }

    func submitSnippetRun(_ values: [String: String]) {
        guard let req = pendingSnippetRun else { return }
        pendingSnippetRun = nil
        deliverSnippet(Snippet.substitute(req.snippet.content, values: values), run: req.run)
    }

    func cancelSnippetRun() { pendingSnippetRun = nil }

    /// 当前是否存在可发送片段的终端标签（供片段面板显示运行按钮）。
    /// 只看「标签」是否存在——由 TabsModel 驱动，面板观察它故能随开/关终端即时刷新；
    /// 不依赖 terminals 字典里终端视图是否已实例化（该字典非 @Published，依赖它会导致
    /// 「先进片段模块、再开终端」时按钮不刷新，须重进模块才出现）。
    var hasSnippetTarget: Bool { snippetTargetTabId() != nil }

    /// 仅向当前工作区的终端投递；概览/文件页可以使用同主机唯一打开的终端。
    func snippetTargetTabId() -> Int? {
        workspaceContext.terminalTabId
    }

    /// AI 面板用公开包装：目标终端标签 id（优先当前活动的终端）。
    func snippetTargetTabIdPublic() -> Int? { snippetTargetTabId() }
    /// AI 投递固定绑定终端，不随前台标签变化重新选择目标；返回通道是否接受文本。
    @discardableResult
    func deliverSnippetPublic(_ text: String, run: Bool, tabId: Int) -> Bool {
        guard tabs.contains(where: { $0.id == tabId && $0.kind == .terminal }),
            let tv = terminals[tabId]
        else { return false }
        let line = run ? text.trimmingCharacters(in: .newlines) + "\n" : text
        if let driver = termDrivers[tabId] { return driver.sendText(line) }
        tv.send(txt: line)
        return true
    }

    func deliverSnippet(_ text: String, run: Bool) {
        guard let id = snippetTargetTabId(), let tv = terminals[id] else {
            snippetNotice = String(localized: "请先打开并切到一个终端，再运行片段。")
            return
        }
        // run=末行自动回车；先归一化掉命令自带的尾部换行，保证恰好补一个 \n（防双回车空行）
        let line = run ? text.trimmingCharacters(in: .newlines) + "\n" : text
        // SSH 终端经引擎驱动注入；本地终端走 LocalProcessTerminalView 自身。
        if let driver = termDrivers[id] { driver.sendText(line) } else { tv.send(txt: line) }
    }

}
