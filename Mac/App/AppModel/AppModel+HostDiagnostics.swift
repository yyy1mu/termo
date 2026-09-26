import Foundation
import TermoEngine

// 在线探测的并发队列与上限（最多 6 个并发 TCP 探测，控制线程/CPU，主机多时不会线程爆炸）。
// 置于文件作用域而非 @MainActor 的 AppModel 内：DispatchQueue/Semaphore 本身线程安全且非 actor 隔离，
// 可在后台 Sendable 闭包里直接使用，不触发「主actor隔离静态属性不可在 Sendable 闭包引用」告警。
private let reachQueue = DispatchQueue(label: "termo.reach", qos: .utility, attributes: .concurrent)
private let reachLimit = DispatchSemaphore(value: 6)

extension AppModel {
    /// 打开主机概览时调用：后台 SSH 跑一次探测脚本，取真实系统信息并缓存。
    /// 已有未过期的缓存则跳过——系统信息变化慢，无需每次打开都重探。
    func probeHostIfNeeded(_ host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, ssh.hasUsableCredentials,
            !probingHosts.contains(host.id)
        else { return }
        if let probedAt = host.specs?.probedAt,
            Date().timeIntervalSince(probedAt) < HostSystemProbe.cacheTTL
        {
            return
        }
        probingHosts.insert(host.id)
        let id = host.id

        // [SSH 引擎] 进程内会话（替换旧 spawn /usr/bin/ssh）：经会话池借暖连接→exec 探测脚本→解析。
        // 会话池保活连接，下次探测复用、不重复认证（替代 ControlMaster）。
        let conn = ssh
        let script = HostSystemProbe.script
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let output = (try? SSHSessionPool.shared.withSession(conn) { try $0.exec(script).output }) ?? ""
            Task { @MainActor in self?.applyProbe(id: id, output: output) }
        }
    }

    func applyProbe(id: String, output: String) {
        probingHosts.remove(id)
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        guard let specs = HostSystemProbe.parse(output) else { return }
        hosts[idx].specs = specs
        hosts[idx].status = .online  // 探测成功 ⇒ 一定在线
        persistHosts(hosts)
    }

    /// 对所有主机做一次轻量 TCP 可达性检测（启动/刷新/定时调用）。
    func refreshAllStatuses() {
        for host in hosts { checkReachability(host) }
    }

    /// 定时扫描在线状态/延迟；仅在 App 处于活动状态时运行（失焦即暂停，省 CPU）。
    func startStatusTimer() {
        guard statusTimer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllStatuses() }
        }
        t.tolerance = 5  // 允许系统合并定时器触发，进一步省电
        statusTimer = t
    }

    func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// 轻量在线/延迟探测（不登录）：应用层测真实 RTT，成功=在线+延迟，失败/超时=离线。
    func checkReachability(_ host: Host) {
        let id = host.id
        guard let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let h = ssh.host, p = ssh.port
        reachQueue.async { [weak self] in
            reachLimit.wait()
            defer { reachLimit.signal() }
            let (ok, ms) = HostReachabilityProbe.measure(host: h, port: p)
            Task { @MainActor in self?.setStatus(id, ok ? .online : .offline, latencyMs: ms) }
        }
    }

    func setStatus(_ id: String, _ status: HostStatus, latencyMs: Int? = nil) {
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return }
        // 运行时状态，不持久化（下次启动重新检测）
        if hosts[idx].status != status { hosts[idx].status = status }
        if hosts[idx].latencyMs != latencyMs { hosts[idx].latencyMs = latencyMs }
    }

}
