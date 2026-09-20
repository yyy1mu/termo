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
    /// 侧栏内容分段：服务器（主机树）/ 会话（当前全部 SSH 终端）/ 同步。
    @State private var segment: SidebarSegment = .servers

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
            case .servers: return String(localized: "服务器")
            case .sessions: return String(localized: "会话")
            }
        }
    }

    private var filteredHosts: [Host] {
        let sshHosts = model.hosts
        guard !model.query.isEmpty else { return sshHosts }
        let q = model.query.lowercased()
        return sshHosts.filter {
            $0.name.lowercased().contains(q) || $0.addr.lowercased().contains(q)
        }
    }

    private var groups: [String] {
        var seen: [String] = []
        for h in filteredHosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主区域负责主机导航；跨设备同步入口固定在底部全局区。
            HStack(spacing: 8) {
                // 添加主机按钮放最前（用户习惯从左起操作）
                Button { model.showAddHost = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.mauve)
                        .frame(width: 28, height: 28)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).pointerCursor().help(String(localized: "添加主机"))
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接空间")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(segmentSubtitle)
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                Spacer()
                segmentSwitcher
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            switch segment {
            case .servers:
                searchBox()
                if filteredHosts.isEmpty {
                    hostEmptyState
                } else {
                    ScrollView { hostList }.padding(.top, 6)
                }
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
        .onChange(of: tabs.activeTabId) { _ in searchFocused = false }
    }

    /// 头部右侧的三段切换（图标 + tooltip，宽度受限不摆文字标签）。
    private var segmentSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(SidebarSegment.allCases, id: \.self) { seg in
                Button { segment = seg } label: {
                    Image(systemName: seg.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(segment == seg ? Pal.mauve : Pal.overlay)
                        .frame(width: 26, height: 24)
                        .background(segment == seg ? Pal.mauve.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help(seg.label)
            }
        }
        .padding(2)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var segmentSubtitle: String {
        switch segment {
        case .servers: return String(localized: "\(model.hosts.count) 台主机")
        case .sessions: return String(localized: "\(sshTabs.count) 个 SSH 会话")
        }
    }

    /// 当前全部 SSH 会话 = 打开中的 SSH 终端标签（排除本地终端与概览/文件页）。
    private var sshTabs: [TabItem] {
        model.tabs.filter { $0.kind == .terminal && $0.hostId != nil }
    }

    private var sessionsList: some View {
        Group {
            if sshTabs.isEmpty {
                VStack(spacing: 10) {
                    Spacer().frame(height: 40)
                    Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(Pal.overlay)
                    Text("还没有 SSH 会话").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Text("打开一台主机的终端后会出现在这里")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sshTabs) { tab in
                            sessionRow(tab)
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 6)
                }
            }
        }
    }

    /// 单个 SSH 会话行：终端图标 + 标签标题 + 主机名 + 连接状态点；点击切换到该标签。
    private func sessionRow(_ tab: TabItem) -> some View {
        let isActive = model.activeTabId == tab.id
        let hostName = model.host(tab.hostId)?.name ?? ""
        // 连接状态：live 绿 / dropped 黄 / 无记录灰
        let phase = model.terminalConn(for: tab.id)?.phase
        let statusColor: Color = phase == .live ? Pal.green : (phase == .dropped ? Pal.yellow : Pal.overlay)
        return Button {
            model.activeTabId = tab.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1).truncationMode(.middle)
                    if !hostName.isEmpty {
                        Text(hostName).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).privacyBlur(model.privacyMode)
                    }
                }
                Spacer()
                Circle().fill(statusColor).frame(width: 7, height: 7)
                    .help(phase == .live ? "已连接" : (phase == .dropped ? "断线" : "未连接"))
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
        // 会话右键与服务器右键职责分离：这里管会话本身；主机级操作在「服务器」列表右键。
        // 原顶部标签页右键的有用功能全部收拢到这里（复制会话/重命名/关闭三件套）。
        .contextMenu {
            Button("切换到会话") { model.activeTabId = tab.id }
            // 复制会话：同主机再开一个终端（经共享连接，不重新登录）；仅 SSH 会话显示。
            if tab.kind == .terminal, let host = model.host(tab.hostId) {
                Button("复制会话") { model.openHostTerminal(host, forceNew: true) }
            }
            Button("重命名") { model.requestRenameTab(tab.id) }
            Divider()
            Button("关闭会话") { model.closeTab(tab.id) }
            Button("关闭其他会话") { model.closeOtherTabs(keep: tab.id) }
            Button("关闭所有会话") { model.closeAllTabs() }
        }
    }


    /// 主机面板底部角标行（对齐 Termark 底栏）：设置 / 主题切换 / 脱敏。
    private var hostsBottomBar: some View {
        HStack(spacing: 8) {
            cornerIcon("gearshape", help: String(localized: "设置")) { model.showSettings = true }
            cornerIcon(theme.isDark ? "sun.max" : "moon", help: String(localized: "切换主题")) {
                theme.mode = theme.isDark ? .light : .dark
            }
            cornerIcon(model.privacyMode ? "eye.slash" : "eye", help: String(localized: "脱敏显示")) {
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
    }

    private func searchBox(_ placeholder: String = String(localized: "搜索主机…")) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Pal.overlay)
            TextField(placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Pal.text)
                .focused($searchFocused)
            // 脱敏开关：开启后隐藏列表/概览中的 IP、主机名（便于截图或共享屏幕）。
            Button { model.privacyMode.toggle() } label: {
                Image(systemName: model.privacyMode ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(model.privacyMode ? Pal.mauve : Pal.overlay)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(model.privacyMode ? String(localized: "显示真实信息") : String(localized: "脱敏显示(隐藏 IP / 主机名)"))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Pal.base, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.border, lineWidth: 1))
        .padding(.horizontal, 14)
    }

    /// 活动栏「文件」面板：有活动主机时显示其文件树，否则提示。
    @ViewBuilder


    private var hostEmptyState: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 40)
            Image(systemName: model.hosts.isEmpty ? "server.rack" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(model.hosts.isEmpty ? "还没有主机" : "无匹配主机")
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
                if !collapsedGroups.contains(group) {
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
        let collapsed = collapsedGroups.contains(group)
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
                Text(group.isEmpty ? String(localized: "未分组") : group)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .animation(.easeOut(duration: 0.15), value: collapsed)
    }

    private var localTerminalButton: some View {
        Button {
            model.openLocalTerminal()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "terminal")
                    .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                    .frame(width: 22, height: 22)
                    .background(Pal.mauve.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                Text("本地终端").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(8)
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
            HStack(spacing: 9) {
                HostLeadingIcon(host: host)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 13)).foregroundStyle(Pal.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(host.ipOrHost)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1)
                        .privacyBlur(model.privacyMode)
                }
                Spacer()
                // 延迟值统一右对齐到行末，多主机竖排时对齐整齐
                if host.status == .online, let ms = host.latencyMs {
                    Text("\(ms) ms").font(.system(size: 11)).foregroundStyle(LatencyLevel(ms: ms).color)
                }
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
        .contextMenu {
            Button("打开终端") { model.openHostTerminal(host) }
            Button("新建终端") { model.openHostTerminal(host, forceNew: true) }
            Button("打开文件") { model.openHostFiles(host) }
            Button("编辑主机") { model.beginEditHost(host) }
            Divider()
            Button("删除主机", role: .destructive) { model.requestDeleteHost(host) }
        }
    }
}
