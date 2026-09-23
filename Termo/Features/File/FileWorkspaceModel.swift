import Foundation

/// 文件域状态：标签级浏览器/文件树缓存 + 主机级资源管理器树 + 网络重连联动。
/// 从 [[AppModel]] 拆出的第一步（文件域内聚）；AppModel 持有并转发，视图调用点零改动。
///
/// 缓存语义：
/// - `browserStates` / `fileTreeStates` 按**标签**独立（同主机多会话互不干扰，关标签即释放）；
/// - `companionBrowserStates` 按**主机**隔离，右侧切主机不能复用另一台的连接与文件；
/// - `hostExplorerTrees` 按**主机**（概览/编辑器侧栏共用的主机级树，随主机存活）。
/// 底层 SFTP 会话经 [[RemoteFS]] 各自懒建；网络切换由 [[AppModel]] 调 `reconnectAll` 联动重置。
@MainActor
final class FileWorkspaceModel {
    private var browserStates: [Int: BrowserState] = [:]
    private var browserHostIds: [Int: String] = [:]
    private var companionBrowserStates: [String: BrowserState] = [:]
    private var fileTreeStates: [Int: FileTreeState] = [:]
    private var fileTreeHostIds: [Int: String] = [:]
    private var hostExplorerTrees: [String: FileTreeState] = [:]

    /// 兼容浏览器调用入口的标记；伴随状态实际按主机缓存，不共用一个伪标签状态。
    static let companionTabId = -1

    /// 标签级 SFTP 浏览器状态。
    func browserState(for tabId: Int, host: Host) -> BrowserState {
        if tabId == Self.companionTabId {
            if let state = companionBrowserStates[host.id] { return state }
            let state = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
            companionBrowserStates[host.id] = state
            return state
        }
        if let s = browserStates[tabId], browserHostIds[tabId] == host.id { return s }
        browserStates[tabId]?.cancel()
        let s = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
        browserStates[tabId] = s
        browserHostIds[tabId] = host.id
        return s
    }

    /// 标签级文件树（revealOnLoad 取该标签终端最近一次上报的 cwd）。
    func fileTreeState(forTab tabId: Int, host: Host, cwd: String?) -> FileTreeState {
        if let s = fileTreeStates[tabId], fileTreeHostIds[tabId] == host.id { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: cwd)
        fileTreeStates[tabId] = s
        fileTreeHostIds[tabId] = host.id
        return s
    }

    /// 主机级资源管理器树（概览/编辑器侧栏共用）。
    func explorerTree(for host: Host) -> FileTreeState {
        if let s = hostExplorerTrees[host.id] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: nil)
        hostExplorerTrees[host.id] = s
        return s
    }

    /// 主机级树里展开并选中某文件（不存在则以该路径初始化树）。
    func revealInExplorer(_ path: String, host: Host) {
        if let tree = hostExplorerTrees[host.id] {
            tree.reveal(path)
        } else {
            hostExplorerTrees[host.id] = FileTreeState(
                fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: path)
        }
    }

    /// 终端 cwd 变化联动：文件树跟随定位到当前目录。
    func revealInFileTree(tabId: Int, path: String) {
        fileTreeStates[tabId]?.reveal(path)
    }

    /// 文件变更后（上传落地 / 解压完成）局部刷新该主机各缓存树/浏览器的指定目录层——
    /// 重列该目录、保留其余展开；树中未加载该目录的直接跳过（无网络开销）。
    /// `tabHostPairs` 由调用方从活动标签列表取（本类不持有标签模型）。
    func refreshTrees(host: Host, dir: String, tabHostPairs: [(Int, String?)]) {
        Task { @MainActor in
            if let t = hostExplorerTrees[host.id] { _ = await t.refreshDir(dir) }   // 主机级树
            for (tabId, t) in fileTreeStates where tabHostPairs.first(where: { $0.0 == tabId })?.1 == host.id {
                _ = await t.refreshDir(dir)
            }
            for (tabId, b) in browserStates where tabHostPairs.first(where: { $0.0 == tabId })?.1 == host.id && b.path == dir {
                b.reload()
            }
            if let browser = companionBrowserStates[host.id], browser.path == dir {
                browser.reload()
            }
        }
    }

    /// 网络恢复后重置所有文件视图的底层连接，使下次操作自动重建 SFTP（而非一直降级为 shell）。
    /// 先按主机各清一次 stale ControlMaster（去重），再重置各视图 SFTP 会话并重载。
    /// `tabHostPairs` 同上由调用方提供；`sshByHostId` 取各主机当前连接配置。
    func reconnectAll(tabHostPairs: [(Int, String?)], sshByHostId: [String: SSHConnection]) {
        var done = Set<String>()
        for (_, hid) in tabHostPairs {
            guard let hid, !done.contains(hid), let ssh = sshByHostId[hid] else { continue }
            done.insert(hid)
            RemoteFS(ssh).closeMaster()
        }
        for (_, b) in browserStates { b.reconnect() }
        for (_, b) in companionBrowserStates { b.reconnect() }
        for (_, t) in fileTreeStates { t.reconnect() }
        for (_, t) in hostExplorerTrees { t.reconnect() }
    }

    /// 关闭标签：取消未完成的文件操作并释放浏览/树状态（按标签独立，关即释放）。
    func closeTab(_ tabId: Int) {
        browserStates[tabId]?.cancel()
        browserStates.removeValue(forKey: tabId)
        browserHostIds.removeValue(forKey: tabId)
        fileTreeStates.removeValue(forKey: tabId)
        fileTreeHostIds.removeValue(forKey: tabId)
    }

    /// 主机最后一个标签关闭后，释放伴随浏览器及其尚未完成的目录请求。
    func closeCompanion(hostId: String) {
        companionBrowserStates.removeValue(forKey: hostId)?.cancel()
    }

    /// 删除主机时清除全部文件缓存；同名路径不会被新主机或剩余标签复用。
    func removeHost(_ hostId: String) {
        closeCompanion(hostId: hostId)
        for tabId in browserHostIds.filter({ $0.value == hostId }).map(\.key) { closeTab(tabId) }
        for tabId in fileTreeHostIds.filter({ $0.value == hostId }).map(\.key) { closeTab(tabId) }
        hostExplorerTrees.removeValue(forKey: hostId)
    }
}
