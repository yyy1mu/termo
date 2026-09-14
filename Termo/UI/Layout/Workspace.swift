import SwiftUI

struct Workspace: View {
    // model 用纯 let 持有（只调方法、不订阅）：AppModel 的无关 @Published 变化不再触发 Workspace 重算。
    let model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared
    // 非活动编辑器的冻结尺寸：仅首次布局时定一次。缩放时只有活动编辑器随实时尺寸重排，隐藏编辑器尺寸不变、不触发 TextKit 重排。

    var body: some View {
        ZStack {
            Pal.base
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if tabs.tabs.isEmpty {
            WelcomeView(model: model)
        } else {
            // 只渲染活动 tab（终端视图由模型持有的裸 NSView 承载，detach/attach 不重建、PTY 后台不断）；
            // 这把"标签越多越卡"的大头（终端 reflow×N）压到 O(1)。
            GeometryReader { geo in
                if let active = tabs.tabs.first(where: { $0.id == tabs.activeTabId }) {
                    tabView(active)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .onChange(of: tabs.activeTabId) { _ in model.focusActiveTab() }
            .onAppear { model.focusActiveTab() }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: TabItem) -> some View {
        Group {
            switch tab.kind {
            case .terminal:
                TerminalDropArea(terminal: model.terminalView(for: tab.id),
                                 isActive: tab.id == tabs.activeTabId,
                                 model: model, tabId: tab.id,
                                 canUpload: model.host(tab.hostId)?.ssh != nil)
                    .overlay {
                        if let conn = model.terminalConn(for: tab.id) {
                            TerminalReconnectOverlay(conn: conn) { model.manualReconnectTerminal(tab.id) }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // 延迟徽章（对齐 Termark 常驻右上）：最近探测的 RTT，无探测结果不显示
                        if let ms = model.host(tab.hostId)?.latencyMs {
                            Text("\(ms)ms")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(Pal.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Pal.fill(0.3), in: RoundedRectangle(cornerRadius: 4))
                                .padding(14)
                        }
                    }
                    .padding(10)
            case .overview:
                if let host = model.host(tab.hostId) {
                    HostOverview(host: host, model: model)
                }
            case .files:
                if let host = model.host(tab.hostId) {
                    FileBrowser(state: model.browserState(for: tab.id, host: host),
                                host: host, model: model)
                } else {
                    Text("无主机").font(.system(size: 13)).foregroundStyle(Pal.overlay)
                }
            }
        }
        .id(tab.id)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 22))
                .foregroundStyle(Pal.mauve)
                .frame(width: 56, height: 56)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            Text("你的远程工作台")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Pal.textBright)
            Text("从左侧选择一台主机，或创建新的连接。终端、文件和系统状态将在这里持续工作。")
                .font(.system(size: 13))
                .foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                welcomeButton("plus", String(localized: "添加主机"), primary: true) {
                    model.showAddHost = true
                }
                if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
                    welcomeButton("terminal", String(localized: "新建本地终端"), primary: false) {
                        model.openLocalTerminal()
                    }
                }
            }
            .padding(.top, 8)
        }
        .padding(36)
        .frame(maxWidth: 500, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Pal.border, lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeButton(_ symbol: String, _ title: String, primary: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(primary ? .white : Pal.mauve)
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(primary ? Pal.mauve : Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
