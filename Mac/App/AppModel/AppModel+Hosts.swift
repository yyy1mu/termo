import AppKit
import SwiftUI

extension AppModel {
    /// 现有分组（保持出现顺序，去重）
    var groupNames: [String] {
        var seen: [String] = []
        for h in hosts where !seen.contains(h.group) { seen.append(h.group) }
        return seen
    }

    @discardableResult
    func addHost(from draft: HostDraft) -> Bool {
        guard draft.canSave else { hostSaveError = draft.validationMessage; return false }
        let conn = draft.buildConnection()
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let addr = "\(conn.user)@\(conn.host)"
        let id = "host-\(UUID().uuidString)"
        let newHost = Host(
            id: id,
            name: name,
            addr: addr,
            group: draft.resolvedGroup,
            status: .unknown,
            os: String(localized: "未知", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        let saved = hosts + [newHost]
        guard persistHosts(saved) else { return false }
        hosts = saved
        if !conn.password.isEmpty { hostCredentialNotice = String(localized: "主机和密码已保存，密码会随加密备份同步。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        checkReachability(newHost)
        return true
    }

    func beginEditHost(_ host: Host) {
        editingHost = host
    }

    /// 用编辑后的表单覆盖已有主机（保持 id / 状态 / 系统不变）。
    @discardableResult
    func updateHost(id: String, from draft: HostDraft) -> Bool {
        guard draft.canSave else { hostSaveError = draft.validationMessage; return false }
        guard let idx = hosts.firstIndex(where: { $0.id == id }) else { return false }
        var conn = draft.buildConnection()
        let old = hosts[idx]
        if sessionOnlyHostPasswords.contains(id), !draft.passwordWasEdited,
            conn.authMethod == old.ssh?.authMethod
        {
            conn.password = old.ssh?.password ?? ""
        }
        // 连接相关配置（ssh：ip/端口/用户/密码/认证方式/密钥/编码/算法/代理/超时等）是否变化。
        // 只改名称/备注/分组时为 false → 不重探可达性、不刷新监控连接，避免无谓的状态闪烁与重连。
        var previousConnection = old.ssh
        previousConnection?.monitoringEnabled = conn.monitoringEnabled
        let connectionChanged = previousConnection != conn
        var saved = hosts
        saved[idx] = Host(
            id: id,
            name: draft.name.trimmingCharacters(in: .whitespaces),
            addr: "\(conn.user)@\(conn.host)",
            group: draft.resolvedGroup,
            status: old.status,
            os: old.os,
            port: conn.port,
            ssh: conn,
            notes: draft.notes.trimmingCharacters(in: .whitespaces)
        )
        // 保留运行时探测结果：延迟徽标沿用旧值；系统信息缓存仅在连接变化时作废（迫使概览重探），
        // 只改名称/备注/分组时原样保留 → 概览不再触发 SSH 重新探测，主机图标不闪「探测中」。
        saved[idx].latencyMs = old.latencyMs
        saved[idx].specs = connectionChanged ? nil : old.specs
        let changedPassword = draft.passwordWasEdited || conn.authMethod != old.ssh?.authMethod
        let temporary =
            changedPassword ? sessionOnlyHostPasswords.subtracting([id]) : sessionOnlyHostPasswords
        guard persistHosts(saved, clearingPasswordsFor: changedPassword ? [id] : [], temporary: temporary)
        else { return false }
        hosts = saved
        reconcileConnectionRequests()
        sessionOnlyHostPasswords = temporary
        if changedPassword {
            hostCredentialNotice =
                conn.authMethod == .ask || conn.password.isEmpty
                ? String(localized: "主机已保存，不保留登录密码。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                : String(localized: "主机和密码已保存，密码会随加密备份同步。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if connectionChanged {
            checkReachability(hosts[idx])
        }
        refreshHostMonitoring(hosts[idx])
        return true
    }

    func isHostPasswordTemporary(_ id: String) -> Bool { sessionOnlyHostPasswords.contains(id) }

    /// 同步已先完成持久化，回填时清除旧会话的临时口令标记。
    func applyPersistedHosts(_ values: [Host]) {
        hosts = values
        reconcileConnectionRequests()
        monitoring.applyPersistedHosts(values)
        sessionOnlyHostPasswords.removeAll()
        hostSaveError = nil
    }

    /// 所有主机保存入口统一处理错误；只用于当前会话的口令不参与落盘。
    @discardableResult
    func persistHosts(
        _ values: [Host], clearingPasswordsFor cleared: Set<String> = [],
        temporary: Set<String>? = nil
    ) -> Bool {
        switch HostStore.saveHosts(
            values, clearingPasswordsFor: cleared,
            ignoringPasswordValuesFor: temporary ?? sessionOnlyHostPasswords)
        {
        case .success:
            hostSaveError = nil
            return true
        case .failure(let error):
            hostSaveError = String(localized: "主机未能完整保存：\(error.localizedDescription)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            return false
        }
    }

    /// 请求删除主机：按设置决定是否先弹确认弹窗（避免误删），否则直接删除。
    func requestDeleteHost(_ host: Host) {
        if AppSettings.shared.confirmHostDelete {
            pendingHostDelete = host
        } else {
            deleteHost(host.id)
        }
    }
    func confirmHostDelete() {
        if let h = pendingHostDelete { deleteHost(h.id) }
        pendingHostDelete = nil
    }
    func cancelHostDelete() { pendingHostDelete = nil }

    func deleteHost(_ id: String) {
        sessionOnlyHostPasswords.remove(id)
        monitoring.remove(hostID: id)
        fileWorkspace.removeHost(id)
        AIChatStore.shared.discard(scope: .host(id))
        // 删除主机前停止其转发隧道，并清除关联规则。
        forwardManagers[id]?.stopAll()
        forwardManagers.removeValue(forKey: id)
        forwardCancellables.removeValue(forKey: id)
        if forwards.contains(where: { $0.hostId == id }) {
            forwards.removeAll { $0.hostId == id }
            HostStore.saveForwards(forwards)
        }
        hosts.removeAll { $0.id == id }
        reconcileConnectionRequests()
        sessions.removeAll { $0.hostId == id }
        HostKeychain.delete(id)
        persistHosts(hosts)
        HostStore.saveSessions(sessions)
    }

}
