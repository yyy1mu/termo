import Foundation

/// 文件域状态：标签级浏览器/文件树缓存 + 主机级资源管理器树 + 网络重连联动。
/// 从 [[AppModel]] 拆出的第一步（文件域内聚）；AppModel 持有并转发，视图调用点零改动。
///
/// 缓存语义：
/// - `browserStates` / `fileTreeStates` 按**标签**独立（同主机多会话互不干扰，关标签即释放）；
/// - `hostExplorerTrees` 按**主机**（概览/编辑器侧栏共用的主机级树，随主机存活）。
/// 底层 SFTP 会话经 [[RemoteFS]] 各自懒建；网络切换由 [[AppModel]] 调 `reconnectAll` 联动重置。
@MainActor
final class FileWorkspaceModel {
    private var browserStates: [Int: BrowserState] = [:]
    private var fileTreeStates: [Int: FileTreeState] = [:]
    private var hostExplorerTrees: [String: FileTreeState] = [:]

    /// 伴随面板固定用一个负的伪 tabId 存 FileBrowser 状态（真实 tabId 从 1 递增，永不冲突）。
    static let companionTabId = -1

    /// 标签级 SFTP 浏览器状态。
    func browserState(for tabId: Int, host: Host) -> BrowserState {
        if let s = browserStates[tabId] { return s }
        let s = BrowserState(fs: RemoteFS(host.ssh ?? SSHConnection()))
        browserStates[tabId] = s
        return s
    }

    /// 标签级文件树（revealOnLoad 取该标签终端最近一次上报的 cwd）。
    func fileTreeState(forTab tabId: Int, host: Host, cwd: String?) -> FileTreeState {
        if let s = fileTreeStates[tabId] { return s }
        let s = FileTreeState(fs: RemoteFS(host.ssh ?? SSHConnection()), revealOnLoad: cwd)
        fileTreeStates[tabId] = s
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
        for (_, t) in fileTreeStates { t.reconnect() }
        for (_, t) in hostExplorerTrees { t.reconnect() }
    }

    /// 关闭标签：取消未完成的文件操作并释放浏览/树状态（按标签独立，关即释放）。
    func closeTab(_ tabId: Int) {
        browserStates[tabId]?.cancel()
        browserStates.removeValue(forKey: tabId)
        fileTreeStates.removeValue(forKey: tabId)
    }
}
