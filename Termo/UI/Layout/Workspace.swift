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
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(Pal.mauve)
                .frame(width: 64, height: 64)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            VStack(spacing: 6) {
                Text("Termo").font(.system(size: 18, weight: .medium)).foregroundStyle(Pal.text)
                Text(AppEnv.localTerminalEnabled ? "从左侧选择一台主机，或打开一个本地终端开始。" : "从左侧选择一台主机开始。")
                    .font(.system(size: 13)).foregroundStyle(Pal.overlay)
            }
            if AppEnv.localTerminalEnabled {   // MAS 沙盒下隐藏本地终端入口
                Button {
                    model.openLocalTerminal()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal").font(.system(size: 13))
                        Text("打开本地终端").font(.system(size: 13))
                    }
                    .foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9).stroke(Pal.mauve.opacity(0.25), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }
}
