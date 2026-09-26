import SwiftUI

/// 全局片段库；搜索独立于主机列表，执行目标跟随终端标签。
struct SnippetsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var query = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var pendingDelete: Snippet?

    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.snippets }
        return model.snippets.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.content.localizedCaseInsensitiveContains(q)
                || $0.displayGroup.localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for snippet in filtered where !seen.contains(snippet.displayGroup) {
            seen.append(snippet.displayGroup)
        }
        return seen
    }

    private var targetTitle: String? {
        guard let id = model.snippetTargetTabIdPublic() else { return nil }
        return tabs.tabs.first { $0.id == id }?.title
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Pal.border)
            if model.snippets.isEmpty {
                PanelEmptyState(
                    symbol: "curlybraces", title: String(localized: "保存常用命令", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    detail: String(localized: "片段可在不同主机间复用，也支持填入变量。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    actionTitle: String(localized: "新建片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: { model.showCreateSnippet = true })
            } else if filtered.isEmpty {
                PanelEmptyState(
                    symbol: "magnifyingglass", title: String(localized: "没有匹配的片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    detail: String(localized: "试试命令、名称或分组。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    actionTitle: String(localized: "清除搜索", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: { query = "" })
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups, id: \.self) { group in
                            groupHeader(group)
                            if !collapsedGroups.contains(group) || !query.isEmpty {
                                ForEach(filtered.filter { $0.displayGroup == group }) { snippet in
                                    SnippetRow(
                                        snippet: snippet, model: model, canRun: targetTitle != nil,
                                        onDelete: { pendingDelete = snippet })
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .alert(
            "删除片段？",
            isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete
        ) { snippet in
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                model.deleteSnippet(snippet); pendingDelete = nil
            }
        } message: { snippet in
            Text("「\(snippet.name)」将从片段库移除。")
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Pal.overlay)
                    TextField("搜索片段", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(Pal.overlay).help("清除搜索")
                    }
                }
                .font(.system(size: 12)).padding(8)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    model.showCreateSnippet = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).foregroundStyle(Pal.mauve).help("新建片段")
                .accessibilityLabel("新建片段")
            }
            Label {
                Text(
                    targetTitle.map { String(localized: "发送到：\($0)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
                        ?? String(localized: "先切到终端，再插入或运行片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                )
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: targetTitle == nil ? "terminal" : "arrow.turn.down.right")
            }
            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
        }
        .padding(12)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = collapsedGroups.contains(group) && query.isEmpty
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 10)
                Text(group).lineLimit(1)
                Spacer(minLength: 0)
                Text(filtered.filter { $0.displayGroup == group }.count, format: .number)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!query.isEmpty)
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    @ObservedObject var model: AppModel
    let canRun: Bool
    let onDelete: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    private var variableCount: Int { Snippet.variableNames(in: snippet.content).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    model.editingSnippet = snippet
                } label: {
                    Text(snippet.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("编辑片段")
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Pal.subtext).help("片段操作")
            }
            Text(snippet.preview)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if variableCount > 0 {
                    Label("\(variableCount) 个变量", systemImage: "curlybraces")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                Spacer(minLength: 4)
                Button {
                    model.triggerSnippet(snippet)
                } label: {
                    Label("使用片段", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).foregroundStyle(canRun ? Pal.mauve : Pal.overlay)
                .disabled(!canRun)
            }
        }
        .padding(12)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("插入到终端") { model.sendSnippet(snippet, run: false) }.disabled(!canRun)
        Button("运行到终端") { model.sendSnippet(snippet, run: true) }.disabled(!canRun)
        Divider()
        Button("编辑") { model.editingSnippet = snippet }
        Button("复制正文") { model.copySnippet(snippet) }
        Divider()
        Button("删除", role: .destructive, action: onDelete)
    }
}
