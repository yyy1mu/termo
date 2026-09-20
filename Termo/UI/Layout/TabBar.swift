import SwiftUI

/// 工作台顶栏：左侧保留系统交通灯，中央是会话，右侧集中全局操作。
struct WorkbenchHeader: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Color.clear.frame(width: 72)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 25, height: 25)
                    .background(Pal.mauve.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                Text("TERMO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(Pal.textBright)
                Spacer(minLength: 0)
                headerButton("sidebar.left", help: String(localized: "切换侧栏")) {
                    layout.sidebarWidth = layout.sidebarWidth < 10 ? 252 : 0
                }
            }
            .padding(.trailing, 8)
            .frame(width: max(layout.sidebarWidth, 220))

            Rectangle().fill(Pal.border).frame(width: 1, height: 24)
            Spacer(minLength: 0)

            HStack(spacing: 3) {
                headerButton("plus", help: String(localized: "添加主机")) { model.showAddHost = true }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 52)
        .background(Pal.crust)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}

struct TabBar: View {
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var frames: [Int: CGRect] = [:]   // 各标签 chip 在内容坐标系的位置，供“点击边缘标签露出相邻标签”

    var body: some View {
        let active = tabs.activeTabId.flatMap { frames[$0] }
        HStack(alignment: .center, spacing: 6) {
            TabStrip(
                newKey: tabs.tabs.count,
                activeKey: tabs.activeTabId ?? 0,
                activeMinX: active?.minX ?? 0,
                activeMaxX: active?.maxX ?? 0
            ) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(tab: tab, model: model, tabs: tabs)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: TabFramesKey.self,
                                                       value: [tab.id: g.frame(in: .named("tabstrip"))])
                            })
                    }
                }
                .coordinateSpace(.named("tabstrip"))
                .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            }
            if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
                Button {
                    model.openLocalTerminal()
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .frame(width: 30, height: 30)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(String(localized: "新建本地终端"))
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
    }
}

/// 收集各标签 chip 在内容坐标系的布局框，供“点击边缘标签时滚动露出相邻标签”定位。
private struct TabFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TabChip: View {
    let tab: TabItem
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hover = false

    private var symbol: String {
        switch tab.kind {
        case .overview: return "square.grid.2x2"
        case .terminal: return "terminal"
        case .files: return "folder"
        }
    }

    /// tab 图标：主机概览 tab 用该主机的发行版 logo（单色、不带品牌色）；其余用功能符号。
    @ViewBuilder
    private func tabIcon(active: Bool) -> some View {
        let fg = active ? Pal.text : Pal.overlay
        if tab.kind == .overview, let host = model.host(tab.hostId), let fontName = OSLogo.fontName,
           let logo = OSLogo.info(for: host.specs?.os ?? host.os) {
            // 固定宽度：标签行宽度不足时图标不会被当成唯一柔性元素压扁（标题已 fixedSize、关闭按钮已定宽）。
            Text(logo.glyph).font(.custom(fontName, size: 12)).foregroundStyle(fg).frame(width: 12)
        } else {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(fg).frame(width: 12)
        }
    }

    var body: some View {
        let active = tabs.activeTabId == tab.id
        HStack(spacing: 7) {
            Button { model.selectTab(tab.id) } label: {
                HStack(spacing: 7) {
                    tabIcon(active: active)
                    Text(tab.title).font(.system(size: 12))
                        .foregroundStyle(active ? Pal.text : Pal.subtext)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Button {
                model.closeTab(tab.id)
            } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 16, height: 16)
                        .background(
                            hover ? Pal.fill(0.1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
                .opacity(active || hover ? 1 : 0)
                .help(String(localized: "关闭标签"))
        }
        .padding(.leading, 11).padding(.trailing, 7).padding(.vertical, 7)
        .background(
            active ? Pal.card : (hover ? Pal.fill(0.07) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityIdentifier(String(tab.id))
    }
}
