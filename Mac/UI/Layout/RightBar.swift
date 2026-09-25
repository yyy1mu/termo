import AppKit
import SwiftUI

/// 右侧功能窄栏：功能入口与后台任务中控常驻可见。
/// 栏体只负责切换开合；面板内容见 [[CompanionPanel]]。
struct RightBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared

    static let width: CGFloat = 60
    private let groups: [[RightPanel]] = [
        [.monitor, .sftp, .ai], [.tmux, .forward, .snippets], [.services, .processes, .network, .docker],
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(groups, id: \.self) { group in
                        VStack(spacing: 3) {
                            ForEach(group, id: \.self) { panel in
                                RightBarButton(panel: panel, selected: layout.rightPanel == panel) {
                                    layout.rightPanel = layout.rightPanel == panel ? nil : panel
                                }
                            }
                        }
                        if group != groups.last { Rectangle().fill(Pal.border).frame(width: 22, height: 1) }
                    }
                }
                .padding(.vertical, 9)
            }
            Rectangle().fill(Pal.border).frame(height: 1)
            BackgroundCenterButton(model: model, arrowEdge: .leading)
                .frame(height: 48)
                .help(String(localized: "后台传输与隧道"))
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Pal.crust)
        .overlay(alignment: .leading) { Rectangle().fill(Pal.border).frame(width: 1) }
    }
}

private struct RightBarButton: View {
    let panel: RightPanel
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: panel.symbol).font(
                    .system(size: 15, weight: selected ? .semibold : .regular))
                Text(panel.shortTitle).font(.system(size: 9, weight: selected ? .semibold : .medium))
            }
            .foregroundStyle(selected ? Pal.mauve : (hover ? Pal.text : Pal.subtext))
            .frame(width: 48, height: 42)
            .background(
                selected ? Pal.mauve.opacity(0.12) : (hover ? Pal.fill(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(Pal.mauve).frame(width: 2, height: 16) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { hover = $0 }
        .help(panel.title).accessibilityLabel(panel.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    var body: some View {
        if let panel = layout.rightPanel {
            let context = model.workspaceContext
            VStack(spacing: 0) {
                header(panel, context: context)
                Rectangle().fill(Pal.fill(0.08)).frame(height: 1)
                content(panel, context: context)
                    .id(context.scope)
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
                        case .active: NSCursor.resizeLeftRight.set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                if dragBaseWidth == nil { dragBaseWidth = panelWidth }
                                if let base = dragBaseWidth {
                                    layout.rightPanelManualWidth = min(
                                        max(base - v.translation.width, 260), 560)
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

    private func header(_ panel: RightPanel, context: WorkspaceContext) -> some View {
        let host = model.host(context.hostId)
        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: panel.symbol).font(.system(size: 15))
                .foregroundStyle(Pal.mauve).frame(width: 28, height: 28)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.textBright)
                if panel != .snippets, let host {
                    Text(host.name).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle).help(host.name)
                } else {
                    Text(panel == .snippets ? "跨主机复用常用命令"
                         : (context.scope == .empty ? "未选择工作区" : "本地终端"))
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                layout.rightPanel = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Pal.subtext).frame(width: 28, height: 28)
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).pointerCursor().help(String(localized: "收起面板"))
            .accessibilityLabel("收起面板")
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
    }

    @ViewBuilder
    private func content(_ panel: RightPanel, context: WorkspaceContext) -> some View {
        let host = model.host(context.hostId)
        if panel.needsHost && host == nil {
            CompanionPlaceholder(
                symbol: panel.symbol,
                message: String(localized: "请先在终端或概览页选中一台 SSH 主机")
            )
        } else {
            switch panel {
            case .ai:
                // 同主机共享 AI 对话；.id(context) 刷新当前命令目标与上下文预览。
                AIPanel(model: model, chat: AIChatStore.shared.session(for: context))
                    .id(context)
            case .sftp:
                if let host {
                    FileBrowser(
                        state: model.browserState(for: FileWorkspaceModel.companionTabId, host: host),
                        host: host, model: model)
                        .id(host.id)
                }
            case .tmux:
                if let host { TmuxPanel(model: model, host: host).id(host.id) }
            case .services:
                if let host { ServicesPanel(model: model, host: host).id(host.id) }
            case .processes:
                if let host { ProcessesPanel(model: model, host: host).id(host.id) }
            case .network:
                if let host { NetworkPanel(model: model, host: host).id(host.id) }
            case .docker:
                if let host { DockerPanel(model: model, host: host).id(host.id) }
            case .monitor:
                if let host {
                    MonitorCompanionContent(model: model, host: host).id(host.id)
                }
            case .forward:
                if let host {
                    // 全功能转发管理（列表/新建/编辑/删除确认）直接入驻右侧面板
                    PortForwardView(model: model, host: host).id(host.id)
                }
            case .snippets:
                SnippetsPanel(model: model, tabs: tabs)
            }
        }
    }
}

/// 监控遵循终端设置；首次显示时按需启动，切走不停止共享连接上的采集。
private struct MonitorCompanionContent: View {
    @ObservedObject var model: AppModel
    let host: Host

    var body: some View {
        MonitorPanel(monitor: model.hostMonitor(for: host),
                     onVerifyHost: { model.verifyMonitorHost(host) })
            .task(id: host.id) { model.ensureHostMonitoring(host) }
    }
}

/// 无主机上下文时的占位提示。
private struct CompanionPlaceholder: View {
    let symbol: String
    let message: String

    var body: some View {
        PanelEmptyState(symbol: symbol, title: String(localized: "选择一台主机"), detail: message)
    }
}
