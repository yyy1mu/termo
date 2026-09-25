import Foundation

extension AppModel {
    // ---------- 会话历史 ----------
    /// 记录一条会话事件并持久化。
    func recordSession(hostId: String, kind: SessionKind, detail: String) {
        sessions.append(SessionEvent(hostId: hostId, kind: kind, detail: detail, timestamp: Date()))
        // 每台主机最多保留 50 条，避免无限增长
        let perHost = Dictionary(grouping: sessions, by: \.hostId)
        var trimmed: [SessionEvent] = []
        for (_, evs) in perHost {
            trimmed += evs.sorted { $0.timestamp > $1.timestamp }.prefix(50)
        }
        sessions = trimmed
        HostStore.saveSessions(sessions)
    }

    /// 某主机最近的会话（倒序，最多 limit 条）。
    func recentSessions(for hostId: String, limit: Int = 6) -> [SessionEvent] {
        sessions
            .filter { $0.hostId == hostId }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    func hostMonitor(for host: Host) -> HostMonitor { monitoring.monitor(for: host) }

    /// 由用户在监控错误卡片中主动核对，不在后台循环弹出信任请求。
    func verifyMonitorHost(_ host: Host) {
        Task {
            guard await verifyHostKey(host), let current = self.host(host.id),
                current.ipOrHost == host.ipOrHost, current.port == host.port,
                let ssh = current.ssh, ssh.monitoringEnabled != false
            else { return }
            monitoring.ensureMonitoring(current, allowTrustRetry: true)
        }
    }

    /// 打开监控面板或终端认证完成时调用；不在视图求值时建立连接，也不自动弹出密码框。
    func ensureHostMonitoring(_ host: Host) {
        guard let current = self.host(host.id) else { return }
        monitoring.ensureMonitoring(current)
    }

    func refreshHostMonitoring(_ host: Host) {
        monitoring.refresh(host, hasOpenWorkspace: tabs.contains { $0.hostId == host.id })
    }

    /// 同步完成密钥与主机配置的应用后，恢复已经打开的主机。
    func refreshOpenHostMonitoring() {
        hosts.forEach { refreshHostMonitoring($0) }
    }

    func stopMonitorIfUnused(_ hostId: String) {
        monitoring.releaseIfUnused(hostID: hostId, hasOpenWorkspace: tabs.contains { $0.hostId == hostId })
    }

}
