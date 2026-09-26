import SwiftUI
import TermoCore
import TermoEngine

/// OpenSSH 算法与编码选项。空字符串表示「默认（自动协商）」。
enum SSHOptions {
    static var encodings: [(value: String, label: String)] { [
        ("", String(localized: "默认（UTF-8）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("UTF-8", "UTF-8"), ("GBK", "GBK"), ("GB2312", "GB2312"), ("GB18030", "GB18030"),
        ("Big5", String(localized: "Big5 (繁体)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), ("Shift_JIS", String(localized: "Shift_JIS (日文)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), ("EUC-JP", String(localized: "EUC-JP (日文)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("EUC-KR", String(localized: "EUC-KR (韩文)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), ("KOI8-R", String(localized: "KOI8-R (俄文)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("ISO-8859-1", String(localized: "ISO-8859-1 (西欧)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), ("ISO-8859-15", "ISO-8859-15"),
        ("Windows-1251", String(localized: "Windows-1251 (西里尔)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), ("Windows-1252", "Windows-1252"),
        ("ASCII", "US-ASCII"),
    ] }

    static var hostKeyAlgos: [(value: String, label: String)] { [
        ("", String(localized: "默认（自动协商）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("ssh-ed25519", "ssh-ed25519"),
        ("rsa-sha2-512", "rsa-sha2-512"),
        ("rsa-sha2-256", "rsa-sha2-256"),
        ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256"),
        ("ecdsa-sha2-nistp384", "ecdsa-sha2-nistp384"),
        ("ecdsa-sha2-nistp521", "ecdsa-sha2-nistp521"),
        ("ssh-rsa", String(localized: "ssh-rsa (旧)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
    ] }

    static var ciphers: [(value: String, label: String)] { [
        ("", String(localized: "默认（自动协商）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("chacha20-poly1305@openssh.com", "chacha20-poly1305"),
        ("aes256-gcm@openssh.com", "aes256-gcm"),
        ("aes128-gcm@openssh.com", "aes128-gcm"),
        ("aes256-ctr", "aes256-ctr"),
        ("aes192-ctr", "aes192-ctr"),
        ("aes128-ctr", "aes128-ctr"),
        ("aes256-cbc", String(localized: "aes256-cbc (旧)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("aes128-cbc", String(localized: "aes128-cbc (旧)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
    ] }

    static var kexAlgos: [(value: String, label: String)] { [
        ("", String(localized: "默认（自动协商）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
        ("mlkem768x25519-sha256", "mlkem768x25519-sha256"),
        ("curve25519-sha256", "curve25519-sha256"),
        ("curve25519-sha256@libssh.org", "curve25519-sha256@libssh.org"),
        ("ecdh-sha2-nistp256", "ecdh-sha2-nistp256"),
        ("ecdh-sha2-nistp384", "ecdh-sha2-nistp384"),
        ("ecdh-sha2-nistp521", "ecdh-sha2-nistp521"),
        ("diffie-hellman-group-exchange-sha256", "dh-group-exchange-sha256"),
        ("diffie-hellman-group16-sha512", "dh-group16-sha512"),
        ("diffie-hellman-group14-sha256", "dh-group14-sha256"),
        ("diffie-hellman-group14-sha1", String(localized: "dh-group14-sha1 (旧)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
    ] }
}

// AuthMethod 已随 SSHConnection 下沉至 TermoCore（rawValue 持久化契约不变）。
extension AuthMethod {
    /// macOS UI label that follows Termo's in-app language instead of the system locale.
    var appLocalizedLabel: String {
        switch self {
        case .password: return String(localized: "密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .key: return String(localized: "密钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .ask: return String(localized: "每次询问", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

enum HostFormSection: String, CaseIterable, Hashable {
    case basic = "基本信息"
    case connection = "连接设置"
    case initial = "终端设置"
    case proxy = "代理设置"
    case advanced = "高级设置"

    var label: String {
        switch self {
        case .basic: return String(localized: "基本信息", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .connection: return String(localized: "连接设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .initial: return String(localized: "终端设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .proxy: return String(localized: "代理设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .advanced: return String(localized: "高级设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    var summary: String {
        switch self {
        case .basic: return String(localized: "地址与登录凭据", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .initial: return String(localized: "监控、目录与启动命令", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .connection: return String(localized: "超时与心跳", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .proxy: return String(localized: "连接代理", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .advanced: return String(localized: "编码与加密算法", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    var icon: String {
        switch self {
        case .basic: return "server.rack"
        case .connection: return "network"
        case .initial: return "terminal"
        case .proxy: return "arrow.triangle.swap"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// 新增/编辑主机的表单数据。
@MainActor
final class HostDraft: ObservableObject {
    // 基本信息
    @Published var group = ""
    @Published var name = ""
    @Published var address = ""
    @Published var authMethod: AuthMethod = .password {
        didSet { if authMethod != oldValue { password = "" } }
    }
    @Published var user = "root"
    @Published var password = "" { didSet { passwordWasEdited = true } }
    private(set) var passwordWasEdited = false
    @Published var keyPath = ""        // 私钥文件路径（认证方式为「密钥」时使用）
    @Published var keyId = ""          // 关联密钥库的密钥 id（非空则用库密钥，优先于 keyPath）
    @Published var notes = ""

    // 连接设置
    @Published var timeout = "10000"
    @Published var heartbeat = "5000"

    // 终端设置
    @Published var monitoringEnabled = true
    @Published var defaultPath = "~"
    @Published var initialCommand = ""

    // 代理设置
    @Published var proxyEnabled = false
    @Published var proxyURL = ""

    // 高级设置
    @Published var encoding = ""
    @Published var hostKeyAlgos = ""
    @Published var ciphers = ""
    @Published var kexAlgos = ""

    // 端口
    @Published var port = "22"

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "填写主机名称，便于在工作区中识别。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        return connectionValidationMessage
    }

    var connectionValidationMessage: String? {
        if resolvedAddress.isEmpty { return String(localized: "填写服务器的 IP 地址或域名。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        if resolvedAddress.contains(where: { $0.isWhitespace }) || resolvedAddress.contains("/")
            || resolvedAddress.contains("@") || resolvedAddress.contains("[") || resolvedAddress.contains("]") {
            return String(localized: "地址仅填写 IP 或域名；登录用户和端口请分别填写。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        // A single colon usually means host:port; an IPv6 literal has multiple colons.
        if resolvedAddress.filter({ $0 == ":" }).count == 1 {
            return String(localized: "请将端口填入独立的端口字段。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(portNumber) else {
            return String(localized: "端口需为 1–65535 之间的整数。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        guard let timeoutNumber = Int(timeout.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1_000...300_000).contains(timeoutNumber) else {
            return String(localized: "连接超时需为 1000–300000 毫秒。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        guard let heartbeatNumber = Int(heartbeat.trimmingCharacters(in: .whitespacesAndNewlines)),
              heartbeatNumber == 0 || (1_000...3_600_000).contains(heartbeatNumber) else {
            return String(localized: "心跳间隔需为 0（关闭）或 1000–3600000 毫秒。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if proxyEnabled {
            do {
                _ = try SSHProxyConfiguration(url: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return error.localizedDescription
            }
        }
        if authMethod == .key, keyId.isEmpty,
           keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "选择密钥库中的密钥，或指定私钥文件。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        return nil
    }

    var canSave: Bool { validationMessage == nil }

    var testUnavailableReason: String? {
        if let connectionValidationMessage { return connectionValidationMessage }
        if authMethod == .ask || (authMethod == .password && password.isEmpty) {
            return String(localized: "测试需要登录凭证；可填写密码后测试，或先保存，再连接时输入。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        return nil
    }

    var resolvedAddress: String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["), value.hasSuffix("]"), value.contains(":") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    var targetLabel: String {
        let login = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = resolvedAddress.contains(":") ? "[\(resolvedAddress)]" : resolvedAddress
        return "\(login.isEmpty ? "root" : login)@\(host):\(port.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var resolvedGroup: String {
        // “未分组”是界面占位文案，不应写入主机资料。否则切换语言后，
        // 旧语言的占位文案会被当成用户创建的真实分组继续显示。
        group.trimmingCharacters(in: .whitespaces)
    }

    /// 从已有主机回填表单（编辑模式）。
    func load(from host: Host, passwordIsTemporary: Bool = false) {
        name = host.name
        group = host.group
        notes = host.notes
        guard let s = host.ssh else { return }
        user = s.user
        address = s.host
        port = String(s.port)
        authMethod = s.authMethod
        password = passwordIsTemporary ? "" : s.password
        keyPath = s.keyPath
        keyId = s.keyId
        encoding = s.encoding
        hostKeyAlgos = s.hostKeyAlgos
        ciphers = s.ciphers
        kexAlgos = s.kexAlgos
        proxyURL = s.proxyURL
        proxyEnabled = !s.disableProxy && !s.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        timeout = String(s.timeoutMs)
        heartbeat = String(s.heartbeatMs)
        monitoringEnabled = s.monitoringEnabled ?? true
        initialCommand = s.initialCommand
        defaultPath = s.defaultPath
        passwordWasEdited = false
    }

    func buildConnection() -> SSHConnection {
        SSHConnection(
            user: user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "root" : user.trimmingCharacters(in: .whitespacesAndNewlines),
            host: resolvedAddress,
            port: Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22,
            authMethod: authMethod,
            password: authMethod == .ask ? "" : password,
            keyPath: keyPath.trimmingCharacters(in: .whitespaces),
            keyId: keyId,
            encoding: encoding,
            hostKeyAlgos: hostKeyAlgos,
            ciphers: ciphers,
            kexAlgos: kexAlgos,
            proxyURL: proxyURL.trimmingCharacters(in: .whitespaces),
            disableProxy: !proxyEnabled,
            timeoutMs: Int(timeout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10000,
            heartbeatMs: Int(heartbeat.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5000,
            initialCommand: initialCommand,
            defaultPath: defaultPath,
            monitoringEnabled: monitoringEnabled ? nil : false
        )
    }
}
