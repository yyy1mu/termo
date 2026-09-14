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
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 30))
                .foregroundStyle(Pal.mauve)
                .frame(width: 72, height: 72)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 6) {
                Text("Termo").font(.system(size: 20, weight: .medium)).foregroundStyle(Pal.text)
                Text("高效的 SSH 终端管理工具")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            HStack(spacing: 10) {
                // 快速连接：聚焦主机面板（有主机直接选；无主机弹出添加表单）
                welcomeButton("magnifyingglass", String(localized: "快速连接"), primary: true) {
                    model.section = .hosts
                    if model.hosts.isEmpty { model.showAddHost = true }
                }
                if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
                    welcomeButton("terminal", String(localized: "新建本地终端"), primary: false) {
                        model.openLocalTerminal()
                    }
                }
            }
            .padding(.top, 6)
            Text("从左侧主机树双击主机开始连接，或点击 + 新建标签页")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .padding(.top, 10)
        }
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
