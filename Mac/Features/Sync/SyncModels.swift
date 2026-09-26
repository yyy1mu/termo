import Foundation
import TermoCore

/// 加密备份信封：上传到 WebDAV / 导出到本地文件的最终格式。
/// 明文负载（SyncPayload）只在加密前的内存里存在，任何路径都不落盘。
struct SyncEnvelope: Codable {
    var format: String = "termo-backup"
    var version: Int = 1
    var kdf: String = "PBKDF2-HMAC-SHA256"
    var iterations: Int
    var salt: String  // base64(16 字节随机盐)
    var cipher: String = "AES-GCM"
    var data: String  // base64(AES-GCM combined：nonce + 密文 + tag)

    var isSupported: Bool { format == "termo-backup" && version == 1 && cipher == "AES-GCM" }
}

/// 备份明文负载（仅在内存中组装与解析）。
/// 密码 / 私钥从 Keychain 读入内存后放进本结构，加密后即刻释放；绝不写明文文件。
struct SyncPayload: Codable {
    var format = "termo-payload"
    var version = 1
    var exportedAt: Date
    var deviceName: String
    /// 主机配置。Host 的 Codable 已排除密码字段，密码单独放 hostPasswords。
    var hosts: [Host]
    /// hostId → 密码。
    var hostPasswords: [String: String]
    /// 密钥元数据。私钥 PEM 单独放 privateKeys。
    var keys: [SSHKey]
    /// keyId → 私钥 PEM。
    var privateKeys: [String: String]
    var snippets: [Snippet]
    var forwards: [ForwardRule]
    var settings: SyncedSettings
    /// AI 配置（含 apiKey，与 privateKeys 同属机密：只存在于加密信封内）。
    var ai: SyncedAI?
    /// App 自有的主机信任记录（~/.termo/session_known_hosts 的有效行）。
    var knownHosts: [String] = []
}

extension SyncPayload {
    /// 旧备份没有 ai / knownHosts 键：缺失时按空处理，不导致整份备份解析失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "termo-payload"
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        hosts = try c.decodeIfPresent([Host].self, forKey: .hosts) ?? []
        hostPasswords = try c.decodeIfPresent([String: String].self, forKey: .hostPasswords) ?? [:]
        keys = try c.decodeIfPresent([SSHKey].self, forKey: .keys) ?? []
        privateKeys = try c.decodeIfPresent([String: String].self, forKey: .privateKeys) ?? [:]
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        forwards = try c.decodeIfPresent([ForwardRule].self, forKey: .forwards) ?? []
        settings = try c.decodeIfPresent(SyncedSettings.self, forKey: .settings) ?? SyncedSettings()
        ai = try c.decodeIfPresent(SyncedAI.self, forKey: .ai)
        knownHosts = try c.decodeIfPresent([String].self, forKey: .knownHosts) ?? []
    }
}

/// 参与同步的 AI 配置快照（对应 LLMProfile + Keychain 中的 apiKey）。
/// 全部字段带默认值解码：远端来自旧/新版本时缺键不导致解析失败。
struct SyncedAI: Codable, Equatable {
    var baseURL: String = "https://api.deepseek.com"
    var model: String = "deepseek-chat"
    var temperature: Double = 0.3
    var contextWindow: Int = 32_000
    var systemPrompt: String = LLMProfile.defaultSystemPrompt
    var apiKey: String = ""

    init() {}

    enum CodingKeys: String, CodingKey {
        case baseURL, model, temperature, contextWindow, systemPrompt, apiKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.deepseek.com"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "deepseek-chat"
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.3
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 32_000
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? LLMProfile.defaultSystemPrompt
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }
}

/// 参与同步的应用设置白名单。
/// 全部字段带默认值解码：远端来自旧/新版本时缺键不导致整份备份解析失败。
struct SyncedSettings: Codable, Equatable {
    var appearanceMode: String = "跟随系统"
    var appLanguage: String = AppLanguage.system.rawValue
    var startupBehavior: String = "welcome"
    var defaultShell: String = "auto"
    var closeConfirm: Bool = true
    var confirmHostDelete: Bool = true
    var termFont: String = ""
    var termFontSize: Int = 13
    var termCursorStyle: String = "bar"
    var termCursorBlink: Bool = true
    var termScrollback: Int = 1000
    var resourceAlerts: Bool = true
    var snippetAction: String = "ask"
    var closeToTray: Bool = false
    var monitorNoticeHidden: Bool = false
    var downloadDir: String = ""
    var downloadAskEachTime: Bool = false
    var maxConcurrentTransfers: Int = 2
    var pausedReleasesSlot: Bool = true
    var showDownloadDialog: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case appearanceMode, appLanguage, startupBehavior, defaultShell, closeConfirm, confirmHostDelete
        case termFont, termFontSize, termCursorStyle, termCursorBlink, termScrollback
        case resourceAlerts, snippetAction
        case closeToTray, monitorNoticeHidden, downloadDir, downloadAskEachTime
        case maxConcurrentTransfers, pausedReleasesSlot, showDownloadDialog
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearanceMode = try c.decodeIfPresent(String.self, forKey: .appearanceMode) ?? "跟随系统"
        appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage) ?? AppLanguage.system.rawValue
        startupBehavior = try c.decodeIfPresent(String.self, forKey: .startupBehavior) ?? "welcome"
        defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell) ?? "auto"
        closeConfirm = try c.decodeIfPresent(Bool.self, forKey: .closeConfirm) ?? true
        confirmHostDelete = try c.decodeIfPresent(Bool.self, forKey: .confirmHostDelete) ?? true
        termFont = try c.decodeIfPresent(String.self, forKey: .termFont) ?? ""
        termFontSize = try c.decodeIfPresent(Int.self, forKey: .termFontSize) ?? 13
        termCursorStyle = try c.decodeIfPresent(String.self, forKey: .termCursorStyle) ?? "bar"
        termCursorBlink = try c.decodeIfPresent(Bool.self, forKey: .termCursorBlink) ?? true
        termScrollback = try c.decodeIfPresent(Int.self, forKey: .termScrollback) ?? 1000
        resourceAlerts = try c.decodeIfPresent(Bool.self, forKey: .resourceAlerts) ?? true
        snippetAction = try c.decodeIfPresent(String.self, forKey: .snippetAction) ?? "ask"
        closeToTray = try c.decodeIfPresent(Bool.self, forKey: .closeToTray) ?? false
        monitorNoticeHidden = try c.decodeIfPresent(Bool.self, forKey: .monitorNoticeHidden) ?? false
        downloadDir = try c.decodeIfPresent(String.self, forKey: .downloadDir) ?? ""
        downloadAskEachTime = try c.decodeIfPresent(Bool.self, forKey: .downloadAskEachTime) ?? false
        maxConcurrentTransfers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers) ?? 2
        pausedReleasesSlot = try c.decodeIfPresent(Bool.self, forKey: .pausedReleasesSlot) ?? true
        showDownloadDialog = try c.decodeIfPresent(Bool.self, forKey: .showDownloadDialog) ?? true
    }
}

/// 一条双向合并冲突：同一 id 在本机与远端内容不同，由用户选择保留哪边。
struct SyncConflict: Identifiable {
    /// 一行字段对比：本机值 vs 远端值。值不同即高亮，供用户逐项核对。
    struct Field {
        let label: String
        let local: String
        let remote: String
        let isDifferent: Bool

        init(label: String, local: String, remote: String, different: Bool? = nil) {
            self.label = label
            self.local = local
            self.remote = remote
            self.isDifferent = different ?? (local != remote)
        }
    }

    enum Item {
        case host(local: Host, localPassword: String?, remote: Host, remotePassword: String?)
        case key(local: SSHKey, localPEM: String?, remote: SSHKey, remotePEM: String?)
        case snippet(local: Snippet, remote: Snippet)
        case forward(local: ForwardRule, remote: ForwardRule)
        case settings(local: SyncedSettings, remote: SyncedSettings)
        case ai(local: SyncedAI, remote: SyncedAI)
    }

    let item: Item

    var id: String {
        switch item {
        case .host(let l, _, _, _): return "host-\(l.id)"
        case .key(let l, _, _, _): return "key-\(l.id)"
        case .snippet(let l, _): return "snippet-\(l.id)"
        case .forward(let l, _): return "forward-\(l.id.uuidString)"
        case .settings: return "settings"
        case .ai: return "ai"
        }
    }

    var title: String {
        switch item {
        case .host(let l, _, _, _): return String(localized: "主机「\(l.name)」", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .key(let l, _, _, _): return String(localized: "密钥「\(l.name)」", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .snippet(let l, _): return String(localized: "片段「\(l.name)」", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .forward(let l, _): return String(localized: "转发规则「\(l.name.isEmpty ? l.summary : l.name)」", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .settings: return String(localized: "应用设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .ai: return String(localized: "AI 配置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    /// 字段级对比。主机按协议 / IP / 端口 / 名称匹配后，这里逐项列出差异供用户裁决。
    var fields: [Field] {
        switch item {
        case .host(let l, let lp, let r, let rp):
            let pwDiff = secretDifferent(lp, rp)
            let pwInconsistent = pwDiff && lp?.isEmpty == false && rp?.isEmpty == false
            return [
                Field(label: String(localized: "名称", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.name, remote: r.name),
                Field(
                    label: String(localized: "协议", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: "SSH", remote: "SSH"),
                Field(label: String(localized: "地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.ipOrHost, remote: r.ipOrHost),
                Field(label: String(localized: "端口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: "\(l.port)", remote: "\(r.port)"),
                Field(
                    label: String(localized: "用户名", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.ssh?.user ?? "", remote: r.ssh?.user ?? ""),
                Field(
                    label: String(localized: "认证方式", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.ssh?.authMethod.appLocalizedLabel ?? "", remote: r.ssh?.authMethod.appLocalizedLabel ?? ""),
                Field(
                    label: String(localized: "密钥来源", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: keySource(l.ssh), remote: keySource(r.ssh)),
                Field(
                    label: String(localized: "分组", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: groupLabel(l.group), remote: groupLabel(r.group)),
                Field(label: String(localized: "备注", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.notes, remote: r.notes),
                Field(
                    label: String(localized: "默认目录", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.ssh?.defaultPath ?? "", remote: r.ssh?.defaultPath ?? ""),
                Field(
                    label: String(localized: "连接后命令", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.ssh?.initialCommand ?? "", remote: r.ssh?.initialCommand ?? ""),
                Field(label: String(localized: "启用主机监控", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                      local: l.ssh?.monitoringEnabled == false ? String(localized: "关", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "开", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                      remote: r.ssh?.monitoringEnabled == false ? String(localized: "关", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "开", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
                Field(
                    label: String(localized: "密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: secretLabel(lp, inconsistent: pwInconsistent),
                    remote: secretLabel(rp, inconsistent: pwInconsistent),
                    different: pwDiff),
            ]
        case .key(let l, let lp, let r, let rp):
            let pemDiff = secretDifferent(lp, rp)
            let pemInconsistent = pemDiff && lp?.isEmpty == false && rp?.isEmpty == false
            return [
                Field(label: String(localized: "名称", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.name, remote: r.name),
                Field(label: String(localized: "类型", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.type.label, remote: r.type.label),
                Field(label: String(localized: "指纹", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.fingerprint, remote: r.fingerprint),
                Field(label: String(localized: "备注", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.comment, remote: r.comment),
                Field(
                    label: String(localized: "私钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: secretLabel(lp, inconsistent: pemInconsistent),
                    remote: secretLabel(rp, inconsistent: pemInconsistent),
                    different: pemDiff),
            ]
        case .snippet(let l, let r):
            return [
                Field(label: String(localized: "名称", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.name, remote: r.name),
                Field(
                    label: String(localized: "分组", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: groupLabel(l.group), remote: groupLabel(r.group)),
                Field(label: String(localized: "内容", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.content, remote: r.content),
                Field(
                    label: String(localized: "更新时间", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: Self.dateLabel(l.updatedAt), remote: Self.dateLabel(r.updatedAt)),
            ]
        case .forward(let l, let r):
            return [
                Field(
                    label: String(localized: "名称", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.name.isEmpty ? l.summary : l.name, remote: r.name.isEmpty ? r.summary : r.name),
                Field(label: String(localized: "类型", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.kind.title, remote: r.kind.title),
                Field(
                    label: String(localized: "监听", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: "\(l.bindAddress):\(l.listenPort)",
                    remote: "\(r.bindAddress):\(r.listenPort)"),
                Field(
                    label: String(localized: "目标", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: l.kind == .dynamic ? "—" : "\(l.destHost):\(l.destPort)",
                    remote: r.kind == .dynamic ? "—" : "\(r.destHost):\(r.destPort)"),
            ]
        case .settings(let l, let r):
            return settingsFields(l, r)
        case .ai(let l, let r):
            let keyDiff = secretDifferent(l.apiKey, r.apiKey)
            let keyInconsistent = keyDiff && !l.apiKey.isEmpty && !r.apiKey.isEmpty
            return [
                Field(label: String(localized: "服务地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.baseURL, remote: r.baseURL),
                Field(label: String(localized: "模型", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.model, remote: r.model),
                Field(
                    label: String(localized: "温度", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: "\(l.temperature)", remote: "\(r.temperature)"),
                Field(
                    label: String(localized: "上下文窗口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: "\(l.contextWindow)", remote: "\(r.contextWindow)"),
                Field(
                    label: String(localized: "系统提示", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: l.systemPrompt, remote: r.systemPrompt),
                Field(
                    label: String(localized: "API Key", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    local: secretLabel(l.apiKey, inconsistent: keyInconsistent),
                    remote: secretLabel(r.apiKey, inconsistent: keyInconsistent),
                    different: keyDiff),
            ]
        }
    }

    // MARK: - 对比辅助

    private static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func groupLabel(_ group: String) -> String {
        group.isEmpty ? String(localized: "未分组", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : group
    }

    private func keySource(_ connection: SSHConnection?) -> String {
        guard let connection, connection.authMethod == .key else { return "" }
        if !connection.keyId.isEmpty { return String(localized: "密钥库（\(connection.keyId)）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        return connection.keyPath
    }

    private func secretLabel(_ value: String?, inconsistent: Bool = false) -> String {
        guard value?.isEmpty == false else { return String(localized: "无", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        return inconsistent ? String(localized: "已保存（不一致）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "已保存", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
    }

    /// 只比较机密是否一致，不在界面上暴露明文。
    private func secretDifferent(_ a: String?, _ b: String?) -> Bool {
        (a ?? "") != (b ?? "")
    }

    /// 设置冲突只列出不同的项，避免整块设置刷屏。
    private func settingsFields(_ l: SyncedSettings, _ r: SyncedSettings) -> [Field] {
        func onOff(_ v: Bool) -> String { v ? String(localized: "开", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "关", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        var out: [Field] = []
        func add(_ label: String, _ lv: String, _ rv: String) {
            if lv != rv { out.append(Field(label: label, local: lv, remote: rv)) }
        }
        add(String(localized: "外观", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.appearanceMode, r.appearanceMode)
        add(String(localized: "语言", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.appLanguage, r.appLanguage)
        add(String(localized: "启动行为", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.startupBehavior, r.startupBehavior)
        add(String(localized: "默认 Shell", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.defaultShell, r.defaultShell)
        add(String(localized: "关闭确认", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.closeConfirm), onOff(r.closeConfirm))
        add(String(localized: "删除确认", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.confirmHostDelete), onOff(r.confirmHostDelete))
        add(String(localized: "终端字体", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.termFont, r.termFont)
        add(String(localized: "终端字号", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), "\(l.termFontSize)", "\(r.termFontSize)")
        add(String(localized: "光标样式", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.termCursorStyle, r.termCursorStyle)
        add(String(localized: "光标闪烁", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.termCursorBlink), onOff(r.termCursorBlink))
        add(String(localized: "滚动缓冲", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), "\(l.termScrollback)", "\(r.termScrollback)")
        add(String(localized: "资源告警", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.resourceAlerts), onOff(r.resourceAlerts))
        add(String(localized: "片段运行方式", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.snippetAction, r.snippetAction)
        add(String(localized: "关闭时隐藏到菜单栏", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.closeToTray), onOff(r.closeToTray))
        add(String(localized: "隐藏监控说明", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.monitorNoticeHidden), onOff(r.monitorNoticeHidden))
        add(String(localized: "默认下载目录", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), l.downloadDir, r.downloadDir)
        add(String(localized: "下载时询问位置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.downloadAskEachTime), onOff(r.downloadAskEachTime))
        add(String(localized: "并发传输数", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), "\(l.maxConcurrentTransfers)", "\(r.maxConcurrentTransfers)")
        add(String(localized: "暂停时让出名额", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.pausedReleasesSlot), onOff(r.pausedReleasesSlot))
        add(String(localized: "下载时显示弹窗", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), onOff(l.showDownloadDialog), onOff(r.showDownloadDialog))
        if out.isEmpty { out.append(Field(label: String(localized: "设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), local: "—", remote: "—")) }
        return out
    }
}

/// 双向合并结果：默认以本机为准的合并负载 + 待用户裁决的冲突列表。
struct SyncMergeResult {
    var merged: SyncPayload
    var conflicts: [SyncConflict]
    var localOnlyCount: Int
    var remoteOnlyCount: Int
}
