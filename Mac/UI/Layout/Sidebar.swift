import SwiftUI

struct Sidebar: View {
    @ObservedObject var model: AppModel
    // 切换 tab 时侧栏需重算（主机行高亮随活动标签变化），故一并观察 TabsModel。
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared
    @FocusState private var searchFocused: Bool
    // 已折叠的分组名集合（仅本次运行有效，重启不保留）
    @State private var collapsedGroups: Set<String> = []
    /// 主机资料与已打开的终端会话使用独立搜索，互不影响。
    @State private var segment: SidebarSegment = .servers
    @State private var sessionQuery = ""

    enum SidebarSegment: String, CaseIterable {
        case servers, sessions
        var symbol: String {
            switch self {
            case .servers: return "server.rack"
            case .sessions: return "terminal"
            }
        }
        var label: String {
            switch self {
            case .servers: return String(localized: "服务器", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .sessions: return String(localized: "会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
        }
    }

    private var filteredHosts: [Host] {
        guard !hostQuery.isEmpty else { return model.hosts }
        return model.hosts.filter {
            [$0.name, $0.addr, $0.group].contains { $0.localizedStandardContains(hostQuery) }
        }
    }

    private var hostQuery: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [String] {
        var seen: [String] = []
        for h in filteredHosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接空间")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(segmentSubtitle)
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                segmentSwitcher
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            searchBox

            switch segment {
            case .servers:
                if filteredHosts.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList }.padding(.top, 6)
                }
                // 服务器段底部固定入口：添加主机 + 本地终端（本地在服务器之下）
                VStack(alignment: .leading, spacing: 2) {
                    sidebarActionRow("plus.square", "添加主机") { model.showAddHost = true }
                    if AppEnv.localTerminalEnabled {
                        sidebarActionRow("terminal", "本地终端") { model.openLocalTerminal() }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            case .sessions:
                sessionsList
            }

            Rectangle().fill(Pal.border).frame(height: 1)
            hostsBottomBar
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: layout.sidebarWidth, alignment: .leading)
        .background(Pal.mantle)
        .clipped()
        .onChange(of: tabs.activeTabId) { _, _ in searchFocused = false }
    }

    /// 侧栏动作行：图标 + 文字，主机列表同款行高。
    private func sidebarActionRow(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Text(title).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private var segmentSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(SidebarSegment.allCases, id: \.self) { seg in
                Button { segment = seg } label: {
                    Label(seg.label, systemImage: seg.symbol)
                        .font(.system(size: 11, weight: segment == seg ? .semibold : .medium))
                        .foregroundStyle(segment == seg ? Pal.text : Pal.subtext)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(segment == seg ? Pal.mauve.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(seg.label)
                .accessibilityAddTraits(segment == seg ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var segmentSubtitle: String {
        switch segment {
        case .servers:
            return hostQuery.isEmpty ? String(localized: "\(model.hosts.count) 台主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                : String(localized: "找到 \(filteredHosts.count) / \(model.hosts.count) 台主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .sessions: return String(localized: "\(workspaceTabs.count) 个已打开的工作区", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private var workspaceTabs: [TabItem] {
        tabs.tabs.filter { $0.kind != .overview }
    }

    private var filteredSessions: [TabItem] {
        let query = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspaceTabs }
        return workspaceTabs.filter { tab in
            let host = model.host(tab.hostId)
            return [tab.title, host?.name ?? (tab.hostId == nil ? String(localized: "本地终端", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : ""), host?.addr ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
    }

    private var sessionsList: some View {
        Group {
            if filteredSessions.isEmpty {
                VStack(spacing: 10) {
                    Spacer().frame(height: 40)
                    Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                    Text(workspaceTabs.isEmpty ? String(localized: "还没有打开的会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "无匹配会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Text(workspaceTabs.isEmpty
                         ? String(localized: "终端和文件工作区都会出现在这里", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                         : String(localized: "试试会话名称、主机名或地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button(workspaceTabs.isEmpty ? String(localized: "查看服务器", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "清除搜索", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                        if workspaceTabs.isEmpty { segment = .servers } else { sessionQuery = "" }
                    }
                    .buttonStyle(.plain).foregroundStyle(Pal.mauve).font(.system(size: 11))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredSessions) { tab in
                            sessionRow(tab)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 6)
                }
            }
        }
    }

    /// 远程会话显示主机名，本地会话只留标题；点击切换到对应标签。
    private func sessionRow(_ tab: TabItem) -> some View {
        let isActive = model.activeTabId == tab.id
        let isLocal = tab.hostId == nil
        let hostName = model.host(tab.hostId)?.name ?? String(localized: "主机不可用", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        return Button {
            model.selectTab(tab.id)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.kind == .files ? "folder" : "terminal")
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(2).truncationMode(.middle)
                        .privacyBlur(model.privacyMode && !isLocal)
                    if !isLocal {
                        Text(hostName).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).privacyBlur(model.privacyMode && !isLocal)
                            .help(model.privacyMode ? "" : hostName)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(isActive ? Pal.mauve.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(isActive ? Pal.mauve.opacity(0.24) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // 会话右键与服务器右键职责分离：这里管会话本身；主机级操作在「服务器」列表右键。
        // 原顶部标签页右键的有用功能全部收拢到这里（复制会话/重命名/关闭三件套）。
        .contextMenu {
            Button("切换到会话") { model.selectTab(tab.id) }
            // 复制会话：同主机再开一个终端（经共享连接，不重新登录）；仅 SSH 会话显示。
            if tab.kind == .terminal, let host = model.host(tab.hostId) {
                Button("复制会话") { model.openHostTerminal(host, forceNew: true) }
            }
            Button("重命名") { model.requestRenameTab(tab.id) }
            Divider()
            Button("关闭会话") { model.closeTab(tab.id) }
            if tab.kind == .terminal {
                Button("关闭其他会话") { model.closeOtherTerminalTabs(keep: tab.id) }
                Button("关闭所有会话") { model.closeAllTerminalTabs() }
            }
        }
    }


    /// 主机面板底部角标行（对齐 Termark 底栏）：设置 / 主题切换 / 脱敏。
    private var hostsBottomBar: some View {
        HStack(spacing: 8) {
            cornerIcon("gearshape", help: String(localized: "设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { model.showSettings = true }
            cornerIcon(theme.isDark ? "sun.max" : "moon", help: String(localized: "切换主题", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                theme.mode = theme.isDark ? .light : .dark
            }
            cornerIcon(model.privacyMode ? "eye.slash" : "eye", help: model.privacyMode
                ? String(localized: "显示主机信息", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "隐藏主机名称和地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                model.privacyMode.toggle()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Pal.mantle)
    }

    private func cornerIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Pal.overlay)
                .frame(width: 26, height: 26)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    private var searchBox: some View {
        let query = segment == .servers ? $model.query : $sessionQuery
        return HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField(segment == .servers ? String(localized: "搜索主机或分组…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "搜索会话…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), text: query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
            if !query.wrappedValue.isEmpty {
                Button { query.wrappedValue = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .help("清除搜索").accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Pal.base, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.border, lineWidth: 1))
        .padding(.horizontal, 14)
    }

    private var hostEmptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: model.hosts.isEmpty ? "server.rack" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(model.hosts.isEmpty ? String(localized: "还没有主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "无匹配主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            if model.hosts.isEmpty {
                Button { model.showAddHost = true } label: {
                    Text("添加主机").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else {
                Text("试试名称、地址或分组")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Button("清除搜索") { model.query = "" }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.mauve)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups, id: \.self) { group in
                groupHeader(group)
                if !hostQuery.isEmpty || !collapsedGroups.contains(group) {
                    ForEach(filteredHosts.filter { $0.group == group }) { host in
                        HostRow(host: host, model: model, isActive: model.activeHostId == host.id)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupHeader(_ group: String) -> some View {
        let collapsed = hostQuery.isEmpty && collapsedGroups.contains(group)
        return Button {
            if collapsed { collapsedGroups.remove(group) } else { collapsedGroups.insert(group) }
        } label: {
            HStack(spacing: 4) {
                // 折叠图标与分组名同字号等宽，展开向下、折叠向右
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 11)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(verbatim: group.isEmpty ? String(localized: "未分组", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : group)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(filteredHosts.filter { $0.group == group }.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!hostQuery.isEmpty)
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

}

struct HostRow: View {
    let host: Host
    @ObservedObject var model: AppModel
    let isActive: Bool   // 由父级 Sidebar（观察 TabsModel）下传，确保切主机时高亮即时刷新
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    var body: some View {
        Button {
            model.openHost(host)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                HostLeadingIcon(host: host)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(2).truncationMode(.middle)
                        .privacyBlur(model.privacyMode)
                    HStack(spacing: 6) {
                        Text(host.ipOrHost)
                            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).truncationMode(.middle)
                            .privacyBlur(model.privacyMode)
                        Spacer(minLength: 0)
                        if host.status == .online, let ms = host.latencyMs {
                            Text("\(ms) ms").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(LatencyLevel(ms: ms).color).fixedSize()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(
                isActive ? Pal.mauve.opacity(0.12) : (hover ? Pal.fill(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(alignment: .leading) {
                if isActive {
                    // 选中标识：左侧 2px 主色条（对齐主流终端管理器的选中语言）
                    RoundedRectangle(cornerRadius: 1).fill(Pal.mauve)
                        .frame(width: 2, height: 22).padding(.leading, 2)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9).stroke(isActive ? Pal.mauve.opacity(0.24) : Color.clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.18), value: isActive)   // 选中高亮丝滑淡入淡出
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(model.privacyMode ? "" : "\(host.name)\n\(host.ipOrHost)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            Button("打开终端") { model.openHostTerminal(host) }
            Button("新建终端") { model.openHostTerminal(host, forceNew: true) }
            Button("编辑主机") { model.beginEditHost(host) }
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}
