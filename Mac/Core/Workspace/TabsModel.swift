import Foundation

/// 中间工作区与右侧工具共同使用的目标解析。没有活动标签时没有隐式主机或终端。
struct WorkspaceContext: Hashable {
    enum Scope: Hashable {
        case host(String)
        case localTerminal(Int)
        case empty
    }

    let activeTabId: Int?
    let hostId: String?
    let terminalTabId: Int?
    let scope: Scope

    init(tabs: [TabItem], activeTabId: Int?, sshHostIds: Set<String>) {
        guard let active = tabs.first(where: { $0.id == activeTabId }),
              active.hostId.map(sshHostIds.contains) ?? true else {
            self.activeTabId = nil
            hostId = nil
            terminalTabId = nil
            scope = .empty
            return
        }
        self.activeTabId = active.id
        hostId = active.hostId
        if let hostId = active.hostId {
            scope = .host(hostId)
            let candidates = tabs.filter { $0.kind == .terminal && $0.hostId == hostId }
            terminalTabId = active.kind == .terminal ? active.id
                : (candidates.count == 1 ? candidates.first?.id : nil)
        } else if active.kind == .terminal {
            scope = .localTerminal(active.id)
            terminalTabId = active.id
        } else {
            scope = .empty
            terminalTabId = nil
        }
    }
}

/// 标签页状态（打开的标签 + 当前活动标签），从 `AppModel` 拆出独立成 ObservableObject。
///
/// 目的：让 `TabBar`/`Workspace` 这类重控件只在标签变化时重算，不再被 AppModel 上
/// hosts/query/弹窗等无关 @Published 牵动重渲染（同 [[LayoutModel]] 的解耦思路）。
///
/// AppModel 通过转发计算属性 `tabs`/`activeTabId` 读写本模型，内部逻辑零改动；
/// 仅视图层从观察 AppModel 改为观察 TabsModel。
@MainActor
final class TabsModel: ObservableObject {
    @Published var tabs: [TabItem] = []
    @Published var activeTabId: Int? = nil
}
