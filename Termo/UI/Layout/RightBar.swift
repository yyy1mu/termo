import AppKit
import SwiftUI

/// 右侧功能窄栏：功能入口与后台任务中控常驻可见。
/// 栏体只负责切换开合；面板内容见 [[CompanionPanel]]。
struct RightBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(RightPanel.allCases, id: \.self) { panel in
                        RightBarButton(symbol: panel.symbol,
                                       selected: layout.rightPanel == panel,
                                       help: panel.title) {
                            layout.rightPanel = layout.rightPanel == panel ? nil : panel
                        }
                    }
                }
                .padding(.top, 14)
            }
            Rectangle().fill(Pal.border).frame(height: 1)
            BackgroundCenterButton(model: model, arrowEdge: .leading)
                .frame(height: 48)
        }
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background(Pal.mantle)
        .overlay(alignment: .leading) { Rectangle().fill(Pal.border).frame(width: 1) }
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
                .frame(width: 34, height: 34)
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
        .accessibilityLabel(help)
    }
}

/// 右侧伴随面板：跟随当前活动标签的主机展开。
/// - SFTP：复用 FileBrowser（同主机共享配置与连接池，且自带连接流程）
/// - 监控：复用 MonitorPanel（仪表盘卡片）
/// - 转发/片段：复用各自面板
struct CompanionPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject var tabs: TabsModel
    let panelWidth: CGFloat
    @ObservedObject private var theme = ThemeManager.shared
    @State private var dragBaseWidth: CGFloat? = nil

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
            .frame(width: panelWidth)
            .background(Pal.mantle)
            // 左缘拖宽手柄：宽度写入 LayoutModel，对所有功能面板统一生效（260~560pt）
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.resizeLeftRight.push()
                        case .ended: NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if dragBaseWidth == nil { dragBaseWidth = panelWidth }
                                if let base = dragBaseWidth {
                                    layout.rightPanelManualWidth = min(max(base - v.translation.width, 260), 560)
                                }
                            }
                            .onEnded { _ in dragBaseWidth = nil }
                    )
                    .help(String(localized: "拖动调整功能面板宽度"))
            }
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
            case .ai:
                // 会话按终端标签绑定（Multiton）：切标签 = 换会话实例；
                // .id 驱动 SwiftUI 重建视图并切换被观察的 chat 对象。
                AIPanel(model: model, chat: AIChatStore.shared.session(for: model.activeTabId))
                    .id(model.activeTabId)
            case .sftp:
                if let host {
                    FileBrowser(
                        state: model.browserState(for: FileWorkspaceModel.companionTabId, host: host),
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
                    // 必须滚动承载：多 GPU/多磁盘时内容超出右栏高度；
                    // 且要顶对齐——裸放会在剩余高度里垂直居中，顶部留出大片死白。
                    ScrollView(.vertical) {
                        MonitorPanel(monitor: model.hostMonitor(for: host))
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .forward:
                if let host {
                    // 全功能转发管理（列表/新建/编辑/删除确认）直接入驻右侧面板
                    PortForwardView(model: model, host: host)
                }
            case .snippets:
                SnippetsPanel(model: model, tabs: tabs)
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

/// 窄栏只呈现隧道概况；需要编辑时打开完整管理窗口，避免 560pt 表单被挤进 280–360pt。
