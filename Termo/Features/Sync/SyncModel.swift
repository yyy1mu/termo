import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum SyncUIError: LocalizedError {
    case weakMaster
    case badPayload
    case masterUnavailable
    case credentialUnavailable(String)
    case unresolvedConflicts(Int)
    case remoteUpdatedLocalFailed(Error)

    var errorDescription: String? {
        switch self {
        case .weakMaster: return String(localized: "主密码至少 8 位（用于加密备份）")
        case .badPayload: return String(localized: "备份内容无法解析")
        case .masterUnavailable: return String(localized: "请先验证主密码，再进行同步或备份")
        case .credentialUnavailable(let detail): return detail
        case .unresolvedConflicts(let count):
            return String(localized: "还有 \(count) 项冲突未选择保留版本。")
        case .remoteUpdatedLocalFailed(let error):
            return String(localized: "远端备份已更新，本机应用未完成。\(error.localizedDescription)")
        }
    }
}

/// 同步面板的状态与操作编排：WebDAV 配置持久化（密码入 Keychain），主密码只留本次运行内存。
@MainActor
final class SyncModel: ObservableObject {
    static let shared = SyncModel()

    /// 等待用户裁决的合并结果；uploadAfter=true 表示裁决后还要把合并结果传回 WebDAV。
    struct PendingMerge {
        let result: SyncMergeResult
        let uploadAfter: Bool
    }

    @Published var baseURL: String
    @Published var username: String
    @Published var password: String = "" {
        didSet {
            guard password != oldValue else { return }
            passwordWasEdited = true
            credentialReadError = nil
        }
    }
    @Published private(set) var credentialReadError: String?
    private var passwordWasEdited = false
    private var credentialLoadAttempted = false
    private var persistedPassword: String?
    @Published var remotePath: String
    private var masterPassword: String { AppLockManager.shared.masterPassword ?? "" }
    @Published var busy = false
    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var pendingMerge: PendingMerge? = nil
    @Published var lastSyncAt: Date? = SyncConfigStore.lastSyncAt

    private var lockSubscription: AnyCancellable?
    private var operationGeneration: Int?

    private init() {
        baseURL = SyncConfigStore.baseURL
        username = SyncConfigStore.username
        remotePath = SyncConfigStore.remotePath
        lockSubscription = AppLockManager.shared.$isLocked.sink { [weak self] locked in
            guard locked else { return }
            self?.pendingPreview = nil
            self?.pendingMerge = nil
        }
    }

    var config: WebDAVConfig {
        WebDAVConfig(baseURL: baseURL, username: username, password: password, remotePath: remotePath)
    }

    /// 仅在打开同步页时读取；锁屏为了查询 busy 创建模型，不应因此触发 WebDAV 钥匙串授权。
    func loadCredentialIfNeeded() {
        guard !credentialLoadAttempted, !passwordWasEdited else { return }
        credentialLoadAttempted = true
        do {
            password = try SyncKeychain.loadPassword()
            passwordWasEdited = false
            persistedPassword = password
            credentialReadError = nil
        } catch {
            credentialReadError = error.localizedDescription
        }
    }

    func retryCredentialRead() {
        guard !passwordWasEdited else { return }
        credentialLoadAttempted = false
        loadCredentialIfNeeded()
    }

    /// 密码先写入 Keychain；写入失败不得把普通连接配置标为已保存。
    func saveConfig() throws {
        loadCredentialIfNeeded()
        if let credentialReadError, !passwordWasEdited {
            throw SyncUIError.credentialUnavailable(credentialReadError)
        }
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if persistedPassword != password {
            try SyncKeychain.savePassword(password)
            persistedPassword = password
        }
        SyncConfigStore.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConfigStore.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        SyncConfigStore.remotePath = path.isEmpty ? SyncConfigStore.defaultRemotePath : path
        remotePath = SyncConfigStore.remotePath
        passwordWasEdited = false
        credentialReadError = nil
    }

    // MARK: - 操作

    func testConnection() async {
        guard validateConfig() else { return }
        await perform {
            let exists = try await WebDAVClient.test(self.config)
            try self.saveConfig()
            return exists
                ? String(localized: "连接成功")
                : String(localized: "连接成功；远端目录尚不存在，首次同步会尝试创建（Seafile 需先在网页端新建资料库）")
        }
    }

    /// 双向合并同步：下载 → 解密 → 合并 → 加密上传 → 应用。上传失败时不改动本机。
    /// 合并预检：双边数据规模，给用户确认后再真正应用（不改任何数据）。
    struct SyncPreview: Identifiable {
        let id = UUID()
        let result: SyncMergeResult
        let uploadAfter: Bool  // true=合并同步（回传云端）；false=仅下载导入
        let localHosts, localPasswords, localKeys, localSnippets: Int
        let remoteHosts, remotePasswords, remoteKeys, remoteSnippets: Int
        let mergedHosts, mergedKeys, mergedSnippets: Int
        var conflicts: Int { result.conflicts.count }
    }
    @Published var pendingPreview: SyncPreview?

    /// 点「合并同步/下载合并」：下载解密并合并出预览弹确认——此步不改任何数据。
    /// 远端无备份时：合并同步直接以本机创建；仅导入则提示无备份。
    func requestMerge(model: AppModel, uploadAfter: Bool) async {
        guard validateConfig(), validateMaster() else { return }
        do { try saveConfig() } catch {
            statusText = error.localizedDescription
            statusIsError = true
            return
        }
        await perform {
            let local = try SyncEngine.makePayload(model: model)
            var remoteData: Data?
            do { remoteData = try await WebDAVClient.download(self.config) } catch WebDAVError.notFound {
                remoteData = nil
            }
            guard let remoteData else {
                if uploadAfter {
                    guard self.masterPassword.count >= 8 else { throw SyncUIError.weakMaster }
                    try await self.upload(local)
                    self.recordSuccessfulSync()
                    return String(localized: "远端无备份，已用本机数据创建")
                }
                return String(localized: "远端没有可下载的备份")
            }
            let remote = try await self.decode(remoteData)
            let result = SyncEngine.merge(local: local, remote: remote)
            self.pendingPreview = SyncPreview(
                result: result, uploadAfter: uploadAfter,
                localHosts: local.hosts.count, localPasswords: local.hostPasswords.count,
                localKeys: local.keys.count, localSnippets: local.snippets.count,
                remoteHosts: remote.hosts.count, remotePasswords: remote.hostPasswords.count,
                remoteKeys: remote.keys.count, remoteSnippets: remote.snippets.count,
                mergedHosts: result.merged.hosts.count, mergedKeys: result.merged.keys.count,
                mergedSnippets: result.merged.snippets.count
            )
            return nil
        }
    }

    /// 确认预览：无冲突直接应用（按需回传云端）；有冲突进入冲突选择器（沿用原有流程）。
    func confirmPreview(model: AppModel) async {
        guard !busy, validateMaster(), let p = pendingPreview else { return }
        pendingPreview = nil
        await perform {
            guard p.result.conflicts.isEmpty else {
                self.pendingMerge = PendingMerge(result: p.result, uploadAfter: p.uploadAfter)
                return String(localized: "发现 \(p.result.conflicts.count) 处冲突，请选择保留哪边")
            }
            try await self.applyMergedPayload(p.result.merged, to: model, uploadFirst: p.uploadAfter)
            return self.summary(p.result)
        }
    }

    func cancelPreview() { pendingPreview = nil }

    /// 以本机数据覆盖远端备份（单向上传，不做合并）。
    func uploadLocal(model: AppModel) async {
        guard validateConfig(), validateMaster() else { return }
        guard masterPassword.count >= 8 else {
            statusText = SyncUIError.weakMaster.errorDescription ?? ""
            statusIsError = true
            return
        }
        do { try saveConfig() } catch {
            statusText = error.localizedDescription
            statusIsError = true
            return
        }
        await perform {
            let payload = try SyncEngine.makePayload(model: model)
            try await self.upload(payload)
            self.recordSuccessfulSync()
            return String(localized: "已上传本机数据覆盖远端备份")
        }
    }

    /// 导出加密备份到本地文件（文件内容为密文，明文不落盘）。
    func exportToFile(model: AppModel) {
        guard validateMaster() else { return }
        guard masterPassword.count >= 8 else {
            statusText = SyncUIError.weakMaster.errorDescription ?? ""
            statusIsError = true
            return
        }
        let panel = NSSavePanel()
        panel.title = String(localized: "导出加密备份")
        panel.nameFieldStringValue = "termo-backup-\(Self.dateStamp()).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await perform {
                let payload = try SyncEngine.makePayload(model: model)
                let plain = try JSONEncoder().encode(payload)
                let password = try self.requireMasterPassword()
                let encrypted = try await Task.detached(priority: .userInitiated) {
                    try SyncCrypto.encrypt(plain, password: password)
                }.value
                try encrypted.write(to: url, options: .atomic)
                return String(localized: "已导出加密备份：\(url.lastPathComponent)")
            }
        }
    }

    /// 从本地加密备份文件导入并合并。
    func importFromFile(model: AppModel) {
        guard validateMaster() else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择 Termo 备份文件")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await perform {
                let data = try Data(contentsOf: url)
                let remote = try await self.decode(data)
                let local = try SyncEngine.makePayload(model: model)
                let result = SyncEngine.merge(local: local, remote: remote)
                guard result.conflicts.isEmpty else {
                    self.pendingMerge = PendingMerge(result: result, uploadAfter: false)
                    return String(localized: "发现 \(result.conflicts.count) 处冲突，请选择保留哪边")
                }
                try await self.applyMergedPayload(result.merged, to: model, uploadFirst: false)
                return self.summary(result)
            }
        }
    }

    /// 冲突裁决完成：WebDAV 合并先上传成功，再应用到本机。
    func resolvePending(choices: [String: Bool], model: AppModel) async {
        guard !busy, validateMaster(), let pending = pendingMerge else { return }
        let unresolved = pending.result.conflicts.filter { choices[$0.id] == nil }.count
        guard unresolved == 0 else {
            statusText = SyncUIError.unresolvedConflicts(unresolved).localizedDescription
            statusIsError = true
            return
        }
        pendingMerge = nil
        let payload = SyncEngine.resolve(result: pending.result, choices: choices)
        await perform {
            try await self.applyMergedPayload(payload, to: model, uploadFirst: pending.uploadAfter)
            return pending.uploadAfter ? String(localized: "同步完成") : String(localized: "已从备份合并导入")
        }
    }

    func cancelPending() {
        pendingMerge = nil
        statusIsError = false
        statusText = String(localized: "已取消本次合并")
    }

    // MARK: - 内部

    private func perform(_ action: @escaping () async throws -> String?) async {
        guard !busy else { return }
        busy = true
        operationGeneration = AppLockManager.shared.sessionGeneration
        defer { busy = false; operationGeneration = nil }
        statusIsError = false
        statusText = ""
        do {
            if let message = try await action() { statusText = message }
        } catch {
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusIsError = true
        }
    }

    private func upload(_ payload: SyncPayload) async throws {
        let plain = try JSONEncoder().encode(payload)
        let password = try requireMasterPassword()
        let encrypted = try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.encrypt(plain, password: password)
        }.value
        _ = try requireMasterPassword()
        try await WebDAVClient.upload(config, data: encrypted)
    }

    /// 只有整个操作成功才更新时间；远端已写入后，本机失败必须明确报告已完成的部分。
    private func applyMergedPayload(_ payload: SyncPayload, to model: AppModel, uploadFirst: Bool) async throws {
        if uploadFirst { try await upload(payload) }
        do {
            _ = try requireMasterPassword()
            try SyncEngine.apply(payload, to: model)
        } catch {
            if uploadFirst { throw SyncUIError.remoteUpdatedLocalFailed(error) }
            throw error
        }
        recordSuccessfulSync()
    }

    private func recordSuccessfulSync() {
        SyncConfigStore.lastSyncAt = Date()
        lastSyncAt = SyncConfigStore.lastSyncAt
    }

    private func decode(_ data: Data) async throws -> SyncPayload {
        let password = try requireMasterPassword()
        let plain = try await Task.detached(priority: .userInitiated) {
            try SyncCrypto.decrypt(data, password: password)
        }.value
        _ = try requireMasterPassword()
        do {
            let payload = try JSONDecoder().decode(SyncPayload.self, from: plain)
            guard payload.format == "termo-payload", payload.version <= 1 else {
                throw SyncUIError.badPayload
            }
            return payload
        } catch {
            throw SyncUIError.badPayload
        }
    }

    private func summary(_ result: SyncMergeResult) -> String {
        guard result.localOnlyCount > 0 || result.remoteOnlyCount > 0 else {
            return String(localized: "同步完成，无变更")
        }
        return String(localized: "同步完成（仅本机 \(result.localOnlyCount) 项，仅远端 \(result.remoteOnlyCount) 项）")
    }

    private func validateConfig() -> Bool {
        loadCredentialIfNeeded()
        if let credentialReadError, !passwordWasEdited {
            statusText = credentialReadError
            statusIsError = true
            return false
        }
        guard config.isComplete else {
            statusText = String(localized: "请先填写 WebDAV 服务器地址与远程路径")
            statusIsError = true
            return false
        }
        return true
    }

    private func requireMasterPassword() throws -> String {
        guard !AppLockManager.shared.isLocked, !masterPassword.isEmpty,
            operationGeneration == nil || operationGeneration == AppLockManager.shared.sessionGeneration
        else {
            throw SyncUIError.masterUnavailable
        }
        return masterPassword
    }

    private func validateMaster() -> Bool {
        do { _ = try requireMasterPassword(); return true } catch {
            statusText = error.localizedDescription
            statusIsError = true
            return false
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }
}
