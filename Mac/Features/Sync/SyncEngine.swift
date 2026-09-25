import Foundation

/// 主机存储已完成后，后续密钥保存失败；同步应用不是跨存储事务。
struct SyncPartialApplyError: LocalizedError {
    let underlyingError: Error
    var errorDescription: String? {
        String(localized: "同步尚未全部完成：主机配置与已保存密码已更新；密钥保存未完成，代码片段、端口转发和设置尚未应用。\(underlyingError.localizedDescription)")
    }
}

/// 同步引擎：本地打包 → 双向合并 → 应用合并结果。
/// 密码 / 私钥只在 Keychain 与内存之间流转；本引擎不写任何明文文件。
@MainActor
enum SyncEngine {

    // MARK: - 打包

    /// 密码只取已成功保存的钥匙串记录；读取失败中止打包，不能把失败伪装为没有密码。
    static func makePayload(model: AppModel) throws -> SyncPayload {
        let hostPasswords = try HostStore.savedPasswords(for: model.hosts)
        return SyncPayload(
            exportedAt: Date(),
            deviceName: SyncConfigStore.deviceName,
            hosts: model.hosts,
            hostPasswords: hostPasswords,
            keys: model.sshKeys,
            privateKeys: try KeyKeychain.loadAll(),
            snippets: model.snippets,
            forwards: model.forwards,
            settings: SyncedSettings.capture())
    }

    // MARK: - 双向合并

    /// 按 id 合并本机与远端：只在一侧存在的条目直接并入；同 id 内容不同则记为冲突（默认保留本机）。
    /// 注意：不做删除同步——删除只影响本机，另一端下次合并会把条目带回来。
    static func merge(local: SyncPayload, remote: SyncPayload) -> SyncMergeResult {
        var merged = local
        merged.exportedAt = Date()
        var conflicts: [SyncConflict] = []
        var localOnly = 0
        var remoteOnly = 0

        // 主机（含密码）：优先用稳定 id 匹配同一条记录，允许修改地址/端口/名称。
        // 跨设备 id 不同时再按「地址|端口|用户名|名称」匹配；名称不同时回退到
        // 「地址|端口|用户名」。用户名必须参与身份，否则同一服务器的不同账号会互相覆盖。
        // 匹配成功的主机沿用本机 id：端口转发等对 hostId 的引用不会失效。
        var mergedHosts: [Host] = []
        var mergedHostPasswords = local.hostPasswords
        var matchedRemoteIDs = Set<String>()
        var remoteIDToMergedID: [String: String] = [:]  // 远端主机 id → 合并后（本机）id
        for lh in local.hosts {
            let remoteHost =
                remote.hosts.first {
                    !matchedRemoteIDs.contains($0.id) && $0.id == lh.id
                }
                ??
                remote.hosts.first {
                    !matchedRemoteIDs.contains($0.id) && hostNaturalKey($0) == hostNaturalKey(lh)
                }
                ?? remote.hosts.first {
                    !matchedRemoteIDs.contains($0.id) && hostFallbackKey($0) == hostFallbackKey(lh)
                }
            guard let rh = remoteHost else { mergedHosts.append(lh); localOnly += 1; continue }
            matchedRemoteIDs.insert(rh.id)
            remoteIDToMergedID[rh.id] = lh.id
            let lp = local.hostPasswords[lh.id]
            let rp = remote.hostPasswords[rh.id]
            if hostEquivalent(lh, password: lp, rh, password: rp) {
                mergedHosts.append(lh)
            } else {
                conflicts.append(
                    SyncConflict(item: .host(local: lh, localPassword: lp, remote: rh, remotePassword: rp)))
                mergedHosts.append(lh)  // 默认保留本机；选远端时 resolve 换成远端内容但沿用本机 id
            }
        }
        for rh in remote.hosts where !matchedRemoteIDs.contains(rh.id) {
            mergedHosts.append(rh)
            if let pw = remote.hostPasswords[rh.id], !pw.isEmpty { mergedHostPasswords[rh.id] = pw }
            remoteOnly += 1
        }
        merged.hosts = mergedHosts
        merged.hostPasswords = mergedHostPasswords

        // 密钥（含私钥 PEM）
        let remoteKeys = Dictionary(remote.keys.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localKeyIDs = Set(local.keys.map(\.id))
        var mergedKeys: [SSHKey] = []
        var mergedPrivateKeys = local.privateKeys
        for lk in local.keys {
            guard let rk = remoteKeys[lk.id] else { mergedKeys.append(lk); localOnly += 1; continue }
            let lp = local.privateKeys[lk.id]
            let rp = remote.privateKeys[rk.id]
            if lk == rk, lp == rp {
                mergedKeys.append(lk)
            } else {
                conflicts.append(SyncConflict(item: .key(local: lk, localPEM: lp, remote: rk, remotePEM: rp)))
                mergedKeys.append(lk)
            }
        }
        for rk in remote.keys where !localKeyIDs.contains(rk.id) {
            mergedKeys.append(rk)
            if let pem = remote.privateKeys[rk.id] { mergedPrivateKeys[rk.id] = pem }
            remoteOnly += 1
        }
        merged.keys = mergedKeys
        merged.privateKeys = mergedPrivateKeys

        // 代码片段
        let remoteSnippets = Dictionary(remote.snippets.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localSnippetIDs = Set(local.snippets.map(\.id))
        var mergedSnippets: [Snippet] = []
        for ls in local.snippets {
            guard let rs = remoteSnippets[ls.id] else { mergedSnippets.append(ls); localOnly += 1; continue }
            if snippetEquivalent(ls, rs) {
                mergedSnippets.append(ls)
            } else {
                conflicts.append(SyncConflict(item: .snippet(local: ls, remote: rs)))
                mergedSnippets.append(ls)
            }
        }
        for rs in remote.snippets where !localSnippetIDs.contains(rs.id) {
            mergedSnippets.append(rs)
            remoteOnly += 1
        }
        merged.snippets = mergedSnippets

        // 端口转发规则；远端规则的 hostId 先经主机映射表归一（自然键匹配到的主机改用本机 id）
        let mappedRemoteForwards = remote.forwards.map { rf -> ForwardRule in
            guard let mapped = remoteIDToMergedID[rf.hostId] else { return rf }
            var copy = rf
            copy.hostId = mapped
            return copy
        }
        let remoteForwards = Dictionary(
            mappedRemoteForwards.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        let localForwardIDs = Set(local.forwards.map(\.id))
        var mergedForwards: [ForwardRule] = []
        for lf in local.forwards {
            guard let rf = remoteForwards[lf.id] else { mergedForwards.append(lf); localOnly += 1; continue }
            if lf == rf {
                mergedForwards.append(lf)
            } else {
                conflicts.append(SyncConflict(item: .forward(local: lf, remote: rf)))
                mergedForwards.append(lf)
            }
        }
        for rf in mappedRemoteForwards where !localForwardIDs.contains(rf.id) {
            mergedForwards.append(rf)
            remoteOnly += 1
        }
        merged.forwards = mergedForwards

        // 应用设置（整体一致即可，不做逐项合并）
        if local.settings != remote.settings {
            conflicts.append(SyncConflict(item: .settings(local: local.settings, remote: remote.settings)))
        }

        return SyncMergeResult(
            merged: merged, conflicts: conflicts,
            localOnlyCount: localOnly, remoteOnlyCount: remoteOnly)
    }

    /// 按用户裁决生成最终负载：choices[id] == true 保留本机，false 使用远端；缺省保留本机。
    static func resolve(result: SyncMergeResult, choices: [String: Bool]) -> SyncPayload {
        var payload = result.merged
        for conflict in result.conflicts where choices[conflict.id] == false {
            switch conflict.item {
            case .host(let lh, _, let rh, let rp):
                if let i = payload.hosts.firstIndex(where: { $0.id == lh.id }) {
                    payload.hosts[i] = hostAdopting(rh, id: lh.id)  // 用远端内容，但沿用本机 id
                }
                if let rp, !rp.isEmpty {
                    payload.hostPasswords[lh.id] = rp
                } else {
                    payload.hostPasswords.removeValue(forKey: lh.id)
                }
            case .key(_, _, let rk, let rp):
                if let i = payload.keys.firstIndex(where: { $0.id == rk.id }) { payload.keys[i] = rk }
                if let rp, !rp.isEmpty {
                    payload.privateKeys[rk.id] = rp
                } else {
                    payload.privateKeys.removeValue(forKey: rk.id)
                }
            case .snippet(_, let rs):
                if let i = payload.snippets.firstIndex(where: { $0.id == rs.id }) { payload.snippets[i] = rs }
            case .forward(_, let rf):
                if let i = payload.forwards.firstIndex(where: { $0.id == rf.id }) { payload.forwards[i] = rf }
            case .settings(_, let rs):
                payload.settings = rs
            }
        }
        return payload
    }

    // MARK: - 应用到本机

    /// 把合并后的负载写回本机各存储：密码回填内存后统一经 HostStore 落 Keychain，JSON 永不含密码。
    static func apply(_ payload: SyncPayload, to model: AppModel) throws {
        var hosts = payload.hosts
        for i in hosts.indices {
            let password = hosts[i].ssh?.authMethod == .ask ? "" : (payload.hostPasswords[hosts[i].id] ?? "")
            hosts[i].ssh?.password = password
        }
        try HostStore.saveHosts(hosts, clearingPasswordsFor: Set(hosts.map(\.id))).get()
        model.applyPersistedHosts(hosts)

        do {
            try KeyStore.save(payload.keys, updatingPrivateKeys: { $0 = payload.privateKeys },
                beforePrivateKeysChange: { ids in
                    for id in ids { try KeyMaterializer.invalidate(id) }
                })
        } catch {
            throw SyncPartialApplyError(underlyingError: error)
        }
        model.sshKeys = payload.keys

        model.snippets = payload.snippets
        SnippetStore.save(payload.snippets)

        model.forwards = payload.forwards
        HostStore.saveForwards(payload.forwards)

        payload.settings.apply()
        model.refreshOpenHostMonitoring()

        for host in hosts { model.checkReachability(host) }
    }

    // MARK: - 主机身份与比较

    /// 主机自然键：地址 | 端口 | 用户名 | 名称。供跨设备、不同 id 的主机匹配。
    private static func hostNaturalKey(_ host: Host) -> String {
        "ssh|\(host.ipOrHost)|\(host.port)|\(host.ssh?.user ?? "")|\(host.name)"
    }

    /// 回退键不含名称，名称变化仍可匹配；不同登录账号不能合并。
    private static func hostFallbackKey(_ host: Host) -> String {
        "ssh|\(host.ipOrHost)|\(host.port)|\(host.ssh?.user ?? "")"
    }

    /// 采用远端内容但沿用本机 id：本机转发规则等对 hostId 的引用保持有效。
    private static func hostAdopting(_ remote: Host, id: String) -> Host {
        Host(
            id: id, name: remote.name, addr: remote.addr, group: remote.group, status: remote.status,
            os: remote.os, port: remote.port, ssh: remote.ssh, notes: remote.notes,
            specs: remote.specs, latencyMs: remote.latencyMs)
    }

    /// 主机配置的归一化编码：排除 id（跨设备不同）与探测结果（specs/latency），
    /// 密码由 ssh 的 CodingKeys 排除、单独比较。
    private struct HostComparable: Encodable {
        let name: String
        let addr: String
        let group: String
        let os: String
        let port: Int
        let notes: String
        let ssh: SSHConnection?
    }

    private static func hostEquivalent(
        _ a: Host, password pa: String?, _ b: Host, password pb: String?
    ) -> Bool {
        hostJSON(a) == hostJSON(b) && (pa ?? "") == (pb ?? "")
    }

    private static func hostJSON(_ host: Host) -> Data {
        var ssh = host.ssh
        // 未配置与显式开启语义相同，避免旧备份产生无意义的冲突。
        if ssh?.monitoringEnabled == true { ssh?.monitoringEnabled = nil }
        let comparable = HostComparable(
            name: host.name, addr: host.addr, group: host.group, os: host.os,
            port: host.port, notes: host.notes, ssh: ssh)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(comparable)) ?? Data()
    }

    /// 片段比较忽略 updatedAt：内容相同就不算冲突（保留本机时间戳）。
    private static func snippetEquivalent(_ a: Snippet, _ b: Snippet) -> Bool {
        a.name == b.name && a.content == b.content && a.group == b.group
    }

}

// MARK: - 应用设置快照

extension SyncedSettings {
    /// 从当前设置捕获白名单快照。
    @MainActor static func capture() -> SyncedSettings {
        let s = AppSettings.shared
        var out = SyncedSettings()
        out.appearanceMode = ThemeManager.shared.mode.rawValue
        out.appLanguage = s.appLanguage.rawValue
        out.startupBehavior = s.startupBehavior.rawValue
        out.defaultShell = s.defaultShell.rawValue
        out.closeConfirm = s.closeConfirm
        out.confirmHostDelete = s.confirmHostDelete
        out.termFont = s.termFont
        out.termFontSize = s.termFontSize
        out.termCursorStyle = s.termCursorStyle
        out.termCursorBlink = s.termCursorBlink
        out.termScrollback = s.termScrollback
        out.resourceAlerts = s.resourceAlerts
        out.snippetAction = s.snippetAction.rawValue
        return out
    }

    /// 应用到本机设置（非法枚举值回退默认，避免远端脏数据）。
    @MainActor func apply() {
        let s = AppSettings.shared
        ThemeManager.shared.mode = AppearanceMode(rawValue: appearanceMode) ?? .system
        s.appLanguage = AppLanguage(rawValue: appLanguage) ?? .zh
        s.startupBehavior = StartupBehavior(rawValue: startupBehavior) ?? .welcome
        s.defaultShell = DefaultShell(rawValue: defaultShell) ?? .auto
        s.closeConfirm = closeConfirm
        s.confirmHostDelete = confirmHostDelete
        s.termFont = termFont
        s.termFontSize = termFontSize
        s.termCursorStyle = termCursorStyle
        s.termCursorBlink = termCursorBlink
        s.termScrollback = termScrollback
        s.resourceAlerts = resourceAlerts
        s.snippetAction = SnippetAction(rawValue: snippetAction) ?? .ask
    }
}
