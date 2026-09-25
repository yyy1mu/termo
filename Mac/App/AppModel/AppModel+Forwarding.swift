import Combine
import Foundation

extension AppModel {
    /// 取得（或惰性创建）某主机的端口转发管理器。
    func forwardManager(for host: Host) -> ForwardManager {
        if let m = forwardManagers[host.id] { return m }
        let m = ForwardManager(ssh: host.ssh ?? SSHConnection())
        forwardCancellables[host.id] = m.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        forwardManagers[host.id] = m
        return m
    }

    /// 全部进行中的后台活动（端口转发运行中的隧道 + 当前传输 + 当前解压），供左下角统一中控。
    /// 携带活动对象本身，使中控各行可直接观察其实时状态/进度；分组与命名由视图按 hostId 解析。
    var backgroundActivities: [BackgroundActivity] {
        var out: [BackgroundActivity] = []
        for rule in forwards {
            if let m = forwardManagers[rule.hostId], m.status(rule.id) != .stopped {
                out.append(
                    BackgroundActivity(
                        id: "fwd-\(rule.id.uuidString)", hostId: rule.hostId,
                        fallbackHostName: "", isFinished: !m.isEnabled(rule.id),
                        payload: .forward(rule: rule, manager: m)))
            }
        }
        for t in transfers {
            let finished = (t.phase == .done || t.phase == .cancelled)
            out.append(
                BackgroundActivity(
                    id: "xfer-\(t.id.uuidString)", hostId: t.hostId,
                    fallbackHostName: t.hostName, isFinished: finished,
                    payload: .transfer(t)))
        }
        if let e = extractTask {
            let finished: Bool = {
                switch e.phase {
                case .done, .failed: return true;
                default: return false
                }
            }()
            out.append(
                BackgroundActivity(
                    id: "ext-\(e.id.uuidString)", hostId: e.hostId,
                    fallbackHostName: e.hostName, isFinished: finished,
                    payload: .extract(e)))
        }
        return out
    }

    /// 清除已结束的传输记录（从后台中控移除）。未结束的（进行中/排队/暂停）会先取消。
    func removeTransfer(_ id: UUID) {
        transferCoordinator.remove(id)
        if focusedTransferId == id { focusedTransferId = nil }
    }
    /// 清除已结束的解压记录。
    func clearExtract() { extractTask = nil; showExtractDialog = false }

    /// 解压是否处于终态（完成/失败）。
    var isExtractFinished: Bool {
        guard let e = extractTask else { return false }
        switch e.phase {
        case .done, .failed: return true;
        default: return false
        }
    }
    /// 后台中控里是否有「已完成」的任务可清理（已完成/已取消的传输，或终态的解压）。
    var hasFinishedBackground: Bool {
        transfers.contains { $0.phase == .done || $0.phase == .cancelled } || isExtractFinished
            || forwardManagers.values.contains { $0.hasStoppedFailure }
    }
    /// 一键清理所有已结束的后台任务记录（不影响进行中/排队的传输与运行中的转发）。
    func clearFinishedBackground() {
        for manager in forwardManagers.values { manager.clearStoppedFailures() }
        let removed = transferCoordinator.clearFinished()
        if let id = focusedTransferId, removed.contains(id) { focusedTransferId = nil }
        if isExtractFinished { extractTask = nil; showExtractDialog = false }
    }

    /// 进行中的后台活动数（用于中控按钮角标）：运行中的转发 + 进行中/排队的传输 + 进行中的解压。
    var activeBackgroundCount: Int {
        var n = 0
        for rule in forwards where forwardManagers[rule.hostId]?.isEnabled(rule.id) == true { n += 1 }
        n += transfers.filter { $0.phase == .running || $0.phase == .queued || $0.phase == .paused }.count
        if extractTask?.phase == .running { n += 1 }
        return n
    }

    /// 是否存在未处理的后台失败：传输有失败文件 / 解压失败 / 端口转发致命失败。供托盘红色呼吸灯。
    /// 失败记录停留在后台中控里直到用户清理或重试 → 红灯随之熄灭（自然的「已知晓」时机）。
    var hasBackgroundFailure: Bool {
        if transfers.contains(where: { $0.hasFailure }) { return true }
        if case .failed = extractTask?.phase { return true }
        if forwardManagers.values.contains(where: { $0.hasFatalFailure }) { return true }
        return false
    }

    /// 是否有运行中的端口转发隧道（任意主机）。常驻后台任务，用图标中心的绿色呼吸点表示，不计入数字角标。
    var hasRunningForward: Bool {
        forwards.contains { forwardManagers[$0.hostId]?.status($0.id).isRunning == true }
    }

    /// 非转发的进行中后台任务数（进行中/排队/暂停的传输 + 进行中的解压），用于数字角标。
    var nonForwardActiveCount: Int {
        var n = transfers.filter { $0.phase == .running || $0.phase == .queued || $0.phase == .paused }.count
        if extractTask?.phase == .running { n += 1 }
        return n
    }

    /// 某主机的全部转发规则（按创建顺序）。
    func forwardRules(for hostId: String) -> [ForwardRule] {
        forwards.filter { $0.hostId == hostId }
    }

    /// 某主机是否有运行中的转发隧道（只读，不会惰性创建管理器，可安全在视图 body 中调用）。
    func hasRunningForward(hostId: String) -> Bool {
        guard let m = forwardManagers[hostId] else { return false }
        return forwards.contains { $0.hostId == hostId && m.status($0.id).isRunning }
    }

    /// 打开某主机的端口转发管理面板。
    func openForwardPanel(_ host: Host) {
        requireAuth(host) { [weak self] in self?.proceedForward(host.id) }
    }

    /// 认证确认后再切换主机，取消询问时保留原工作区；复用已有标签，避免为管理隧道新建终端。
    func proceedForward(_ hostId: String) {
        guard let host = hosts.first(where: { $0.id == hostId }) else { return }
        if companionHost()?.id != hostId {
            if let existing = tabs.first(where: { $0.hostId == hostId }) {
                selectTab(existing.id)
            } else {
                openHost(host)
            }
        }
        layoutModel.rightPanel = .forward
    }

    /// 关闭所有打开的 sheet（设置/添加主机/端口转发等）。退出/隐藏前调用：
    /// 退出确认弹窗是 ContentView 的 overlay，会被 sheet 盖在下面；sheet 还是窗口级模态、可能阻塞退出。
    func dismissAllSheets() {
        showSettings = false
        showAddHost = false
        editingHost = nil
    }

    /// 启停一条规则：启动时记一条「端口转发」会话。
    func toggleForward(_ rule: ForwardRule) {
        guard let host = hosts.first(where: { $0.id == rule.hostId }) else { return }
        let m = forwardManager(for: host)
        if m.isEnabled(rule.id) {
            m.stop(rule.id)
        } else {
            m.start(rule)
            recordSession(hostId: host.id, kind: .portForward, detail: rule.summary)
        }
    }

    /// 新增或更新一条规则（按 id 匹配）。
    func saveForwardRule(_ rule: ForwardRule) {
        if let i = forwards.firstIndex(where: { $0.id == rule.id }) {
            forwards[i] = rule
        } else {
            forwards.append(rule)
        }
        HostStore.saveForwards(forwards)
    }

    /// 删除一条规则：先停掉其运行中的隧道，再移除并落盘。
    func deleteForwardRule(_ rule: ForwardRule) {
        if let host = hosts.first(where: { $0.id == rule.hostId }) {
            forwardManager(for: host).stop(rule.id)
        }
        forwards.removeAll { $0.id == rule.id }
        HostStore.saveForwards(forwards)
    }

}
