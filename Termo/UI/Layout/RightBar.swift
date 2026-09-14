import AppKit
import SwiftUI

/// 右侧功能窄栏（对齐 Termark）：40px 图标列，点开伴随面板（跟随当前主机）。
/// 栏体只负责切换开合；面板内容见 [[CompanionPanel]]。
struct RightBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 4) {
            ForEach(RightPanel.allCases, id: \.self) { panel in
                RightBarButton(symbol: panel.symbol,
                               selected: layout.rightPanel == panel,
                               help: panel.title) {
                    layout.rightPanel = layout.rightPanel == panel ? nil : panel
                }
            }
            Spacer()
        }
        .padding(.top, 52)
        .padding(.bottom, 10)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .background(Pal.crust)
    }
}

private struct RightBarButton: View {
    let symbol: String
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Pal.mauve : (hover ? Pal.subtext : Pal.overlay))
                .frame(width: 30, height: 30)
                .background(
                    selected ? Pal.mauve.opacity(0.16) : (hover ? Pal.fill(0.08) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hover = $0 }
        .help(help)
    }
}

/// 右侧伴随面板（对齐 Termark 功能面板）：跟随当前活动标签的主机展开。
/// - SFTP：复用 FileBrowser（同主机共享配置与连接池，且自带连接流程）
/// - 监控：复用 MonitorPanel（仪表盘卡片）
/// - 转发/片段/同步：复用各自面板
struct CompanionPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject private var theme = ThemeManager.shared

    /// 伴随面板固定用一个负的伪 tabId 存 FileBrowser 状态（真实 tabId 从 1 递增，永不冲突）。
    private static let companionTabId = -1

    var body: some View {
        if let panel = layout.rightPanel {
            VStack(spacing: 0) {
                header(panel)
                Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
                content(panel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: LayoutModel.rightPanelWidth)
            .background(Pal.base)
            .overlay(alignment: .leading) {
                Rectangle().fill(Pal.border).frame(width: 1)
            }
        }
    }

    private func header(_ panel: RightPanel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: panel.symbol).font(.system(size: 12)).foregroundStyle(Pal.mauve)
            Text(panel.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            if let host = model.companionHost() {
                Text("· \(host.name)")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .lineLimit(1)
            }
            Spacer()
            Button { layout.rightPanel = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 22, height: 22)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ panel: RightPanel) -> some View {
        let host = model.companionHost()
        if panel.needsHost && host == nil {
            CompanionPlaceholder(
                symbol: panel.symbol,
                message: String(localized: "请先在终端或概览页选中一台 SSH 主机")
            )
        } else {
            switch panel {
            case .sftp:
                if let host {
                    FileBrowser(
                        state: model.browserState(for: Self.companionTabId, host: host),
                        host: host, model: model)
                }
            case .tmux:
                if let host { TmuxPanel(model: model, host: host) }
            case .services:
                if let host { ServicesPanel(model: model, host: host) }
            case .processes:
                if let host { ProcessesPanel(model: model, host: host) }
            case .network:
                if let host { NetworkPanel(model: model, host: host) }
            case .docker:
                if let host { DockerPanel(model: model, host: host) }
            case .monitor:
                if let host {
                    MonitorPanel(monitor: model.hostMonitor(for: host))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }
            case .forward:
                if let host {
                    PortForwardView(model: model, host: host)
                }
            case .snippets:
                SnippetsPanel(model: model, tabs: tabs)
            case .sync:
                SyncPanel(model: model)
            }
        }
    }
}

/// 无主机上下文时的占位提示。
private struct CompanionPlaceholder: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Pal.overlay)
            Text(message)
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 端口转发伴随面板：复用 ForwardManager 的规则列表（跟随主机上下文）。
/// 退出时恢复进入前的面板主机，避免清掉概览页正在使用的转发面板。
private struct ForwardCompanion: View {
    @ObservedObject var model: AppModel
    let host: Host
    @State private var prev: Host? = nil

    var body: some View {
        PortForwardView(model: model, host: host)
    }
}
