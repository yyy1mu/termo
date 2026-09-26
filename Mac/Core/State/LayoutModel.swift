import SwiftUI

/// 侧栏宽度独立成一个极小的 ObservableObject —— 故意从 [[AppModel]] 拆出来。
///
/// 原因:`AppModel` 被 ContentView / Sidebar / TabBar / Workspace 等几乎所有视图共同
/// 观察。若把 `sidebarWidth` 放在它身上,任何一次宽度变化(尤其拖动分隔条时每帧一次)都会
/// 触发 `objectWillChange`,使所有持有 `@ObservedObject var model` 的视图同帧重算 body
/// —— 标签越多、文件树行越多就越卡。
///
/// 把宽度放进本对象后,只有真正参与缩放的视图(Sidebar 的 frame、SidebarDivider)订阅它,
/// TabBar / Workspace 的 `model` 入参不变 → SwiftUI 跳过它们的 body 重算,拖动只剩侧栏自身
/// 这点开销。右栏伴随面板同理：只有 RightBar / CompanionPanel 观察它。
@MainActor
final class LayoutModel: ObservableObject {
    /// 左侧栏宽度(像素)。0 视为折叠。
    @Published var sidebarWidth: CGFloat = 252
    /// 右侧功能面板手动宽度（nil=按窗口自适应）；对所有功能面板统一生效。
    @Published var rightPanelManualWidth: CGFloat? = nil
    /// 右侧伴随面板；nil = 收起。
    @Published var rightPanel: RightPanel? = nil

}

/// 右侧功能栏条目：以当前主机与终端上下文为中心；全局同步位于设置。
enum RightPanel: String, CaseIterable, Hashable {
    // 声明顺序即右侧栏按钮顺序：高频核心功能（监控/文件/tmux/转发/片段）在前，主机巡检工具在后。
    case monitor, ai, sftp, tmux, forward, snippets, services, processes, network, docker

    var shortTitle: String {
        switch self {
        case .monitor: return String(localized: "监控", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .ai: return String(localized: "助手", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .sftp: return String(localized: "文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .tmux: return "tmux"
        case .forward: return String(localized: "转发", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .snippets: return String(localized: "片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .services: return String(localized: "服务", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .processes: return String(localized: "进程", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .network: return String(localized: "网络", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .docker: return "Docker"
        }
    }

    var symbol: String {
        switch self {
        case .sftp: return "folder"
        case .ai: return "sparkles"
        case .tmux: return "rectangle.split.2x2"
        case .services: return "gearshape.2"
        case .processes: return "chart.bar"
        case .network: return "network"
        case .monitor: return "waveform.path.ecg"
        case .docker: return "shippingbox"
        case .forward: return "arrow.left.arrow.right"
        case .snippets: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var title: String {
        switch self {
        case .sftp: return String(localized: "文件 (SFTP)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .ai: return String(localized: "AI 助手", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .tmux: return "tmux"
        case .services: return String(localized: "系统服务", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .processes: return String(localized: "进程管理", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .network: return String(localized: "网络连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .monitor: return String(localized: "监控", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .docker: return "Docker"
        case .forward: return String(localized: "端口转发", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .snippets: return String(localized: "代码片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    /// 是否需要一台已选中的 SSH 主机（否则显示占位提示）。
    var needsHost: Bool {
        switch self {
        case .ai, .snippets: return false
        default: return true
        }
    }
}
