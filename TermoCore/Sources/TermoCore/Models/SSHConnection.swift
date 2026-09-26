import Foundation

/// 主机的 SSH 连接配置；认证由进程内引擎消费，密码独立存于 Keychain。
public struct SSHConnection: Codable, Equatable, Sendable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, keyId, encoding, hostKeyAlgos, ciphers, kexAlgos
        case proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath, monitoringEnabled
    }

    public var user: String = "root"
    public var host: String = ""
    public var port: Int = 22
    public var authMethod: AuthMethod = .password
    public var password: String = ""
    public var keyPath: String = ""
    public var keyId: String = ""   // 关联密钥库的密钥 id；非空则用库密钥（连接时落 0600 工作文件），优先于 keyPath
    public var encoding: String = ""
    public var hostKeyAlgos: String = ""
    public var ciphers: String = ""
    public var kexAlgos: String = ""
    public var proxyURL: String = ""
    public var disableProxy: Bool = false
    public var timeoutMs: Int = 10000
    public var heartbeatMs: Int = 5000
    public var initialCommand: String = ""
    public var defaultPath: String = "~"
    /// 每台主机独立保存并同步；缺失/null 表示默认开启，仅显式 false 停止采集。
    public var monitoringEnabled: Bool? = nil

    public init(
        user: String = "root",
        host: String = "",
        port: Int = 22,
        authMethod: AuthMethod = .password,
        password: String = "",
        keyPath: String = "",
        keyId: String = "",
        encoding: String = "",
        hostKeyAlgos: String = "",
        ciphers: String = "",
        kexAlgos: String = "",
        proxyURL: String = "",
        disableProxy: Bool = false,
        timeoutMs: Int = 10000,
        heartbeatMs: Int = 5000,
        initialCommand: String = "",
        defaultPath: String = "~",
        monitoringEnabled: Bool? = nil
    ) {
        self.user = user
        self.host = host
        self.port = port
        self.authMethod = authMethod
        self.password = password
        self.keyPath = keyPath
        self.keyId = keyId
        self.encoding = encoding
        self.hostKeyAlgos = hostKeyAlgos
        self.ciphers = ciphers
        self.kexAlgos = kexAlgos
        self.proxyURL = proxyURL
        self.disableProxy = disableProxy
        self.timeoutMs = timeoutMs
        self.heartbeatMs = heartbeatMs
        self.initialCommand = initialCommand
        self.defaultPath = defaultPath
        self.monitoringEnabled = monitoringEnabled
    }

    /// 当前是否已具备自动连接所需凭证：「每次询问」需已输入本会话密码；其它方式恒为 true。
    /// 用于门控后台监控/规格探测——无凭证时跳过（UI 显示占位、不反复弹密码框），有凭证后正常采集。
    public var hasUsableCredentials: Bool {
        authMethod == .ask ? !password.isEmpty : true
    }
}
