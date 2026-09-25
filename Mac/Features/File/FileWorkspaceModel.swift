import Foundation

/// 文件浏览器缓存与网络重连联动，由 AppModel 持有。
/// 标签浏览器随标签释放；右侧伴随浏览器按主机隔离，避免切主机时复用其他连接。
/// 底层 SFTP 会话由 RemoteFS 按需建立。
@MainActor
final class FileWorkspaceModel {
    private var browserStates: [Int: BrowserState] = [:]
    private var browserHostIds: [Int: String] = [:]
    private var companionBrowserStates: [String: BrowserState] = [:]

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

    /// 只重载目标主机正在显示的目录，不为刷新创建新的浏览器或连接。
    func refreshBrowsers(host: Host, dir: String) {
        for (tabId, browser) in browserStates where browserHostIds[tabId] == host.id && browser.path == dir {
            browser.reload()
        }
        if let browser = companionBrowserStates[host.id], browser.path == dir {
            browser.reload()
        }
    }

    /// 网络恢复后重置所有文件视图的底层连接，使下次操作自动重建 SFTP（而非一直降级为 shell）。
    /// 按主机请求空闲连接回收，再重置各视图的 SFTP 操作并重载；传输作废由上层统一负责。
    /// `tabHostPairs` 由调用方从当前标签列表提供；`sshByHostId` 取各主机当前连接配置。
    func reconnectAll(tabHostPairs: [(Int, String?)], sshByHostId: [String: SSHConnection]) {
        var done = Set<String>()
        for (_, hid) in tabHostPairs {
            guard let hid, !done.contains(hid), let ssh = sshByHostId[hid] else { continue }
            done.insert(hid)
            SSHSessionPool.shared.closeIdleConnection(for: ssh)
        }
        for (_, b) in browserStates { b.reconnect() }
        for (_, b) in companionBrowserStates { b.reconnect() }
    }

    /// 关闭标签：取消未完成的文件操作并释放浏览状态（按标签独立，关即释放）。
    func closeTab(_ tabId: Int) {
        browserStates[tabId]?.cancel()
        browserStates.removeValue(forKey: tabId)
        browserHostIds.removeValue(forKey: tabId)
    }

    /// 主机最后一个标签关闭后，释放伴随浏览器及其尚未完成的目录请求。
    func closeCompanion(hostId: String) {
        companionBrowserStates.removeValue(forKey: hostId)?.cancel()
    }

    /// 删除主机时清除全部文件缓存；同名路径不会被新主机或剩余标签复用。
    func removeHost(_ hostId: String) {
        closeCompanion(hostId: hostId)
        for tabId in browserHostIds.filter({ $0.value == hostId }).map(\.key) { closeTab(tabId) }
    }
}
