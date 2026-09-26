import CTermoSSH
import CryptoKit
import Foundation
import TermoCore

public struct SSHProxyConfiguration: Equatable {
    public enum Kind: Int32 { case socks5 = 1, httpConnect = 2 }

    public let kind: Kind
    public let host: String
    public let port: Int32

    public init(url value: String) throws {
        guard let components = URLComponents(string: value) else {
            throw SSHSession.SSHError(message: String(localized: "代理地址格式无效。"))
        }
        guard components.user == nil, components.password == nil else {
            throw SSHSession.SSHError(message: String(localized: "代理地址不能包含用户名或密码。"))
        }
        guard let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty,
            let port = components.port, (1...65535).contains(port),
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/"
        else {
            throw SSHSession.SSHError(message: String(localized: "代理地址无效，请填写包含端口的 socks5:// 或 http:// 地址。"))
        }
        switch scheme {
        case "socks5": kind = .socks5
        case "http": kind = .httpConnect
        default:
            throw SSHSession.SSHError(message: String(localized: "当前仅支持 SOCKS5 和 HTTP CONNECT 代理。"))
        }
        self.host = host
        self.port = Int32(port)
    }
}

/// Validated settings used by every network entry point for a host.
public struct SSHTransportOptions: Equatable {
    public let timeoutMs: Int32
    public let heartbeatMs: Int32
    public let proxy: SSHProxyConfiguration?
    public let hostKeyAlgorithms: String
    public let ciphers: String
    public let keyExchangeAlgorithms: String

    public init(_ connection: SSHConnection) throws {
        guard (1_000...300_000).contains(connection.timeoutMs) else {
            throw SSHSession.SSHError(message: String(localized: "连接超时需为 1000–300000 毫秒。"))
        }
        guard connection.heartbeatMs == 0 || (1_000...3_600_000).contains(connection.heartbeatMs) else {
            throw SSHSession.SSHError(message: String(localized: "心跳间隔需为 0（关闭）或 1000–3600000 毫秒。"))
        }
        timeoutMs = Int32(connection.timeoutMs)
        heartbeatMs = Int32(connection.heartbeatMs)
        let proxyURL = connection.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        proxy = connection.disableProxy || proxyURL.isEmpty ? nil : try SSHProxyConfiguration(url: proxyURL)
        hostKeyAlgorithms = connection.hostKeyAlgos
        ciphers = connection.ciphers
        keyExchangeAlgorithms = connection.kexAlgos
    }

    public func withRawOptions<Result>(
        _ body: (UnsafePointer<TermoConnectionOptions>) throws -> Result
    ) rethrows -> Result {
        let proxyHost = proxy?.host ?? ""
        return try proxyHost.withCString { proxyHostPointer in
            try hostKeyAlgorithms.withCString { hostKeyPointer in
                try ciphers.withCString { cipherPointer in
                    try keyExchangeAlgorithms.withCString { keyExchangePointer in
                        var raw = TermoConnectionOptions(
                            timeout_ms: timeoutMs,
                            heartbeat_ms: heartbeatMs,
                            proxy_kind: proxy?.kind.rawValue ?? 0,
                            proxy_port: proxy?.port ?? 0,
                            proxy_host: proxyHostPointer,
                            host_key_algos: hostKeyPointer,
                            ciphers: cipherPointer,
                            kex_algos: keyExchangePointer
                        )
                        return try withUnsafePointer(to: &raw, body)
                    }
                }
            }
        }
    }
}

/// 平台连接环境：known_hosts 双文件路径与密钥落盘属平台职责（macOS 由 HostKeyVerifier/KeyMaterializer 提供），
/// 由 App 侧装配注入；引擎自身不引用任何平台单例或全局状态。
public struct SSHConnectionEnvironment: Sendable {
    public let realKnownHosts: String
    public let sessionKnownHosts: String
    public let materializeKey: @Sendable (String) -> String?

    public init(realKnownHosts: String, sessionKnownHosts: String,
                materializeKey: @escaping @Sendable (String) -> String?) {
        self.realKnownHosts = realKnownHosts
        self.sessionKnownHosts = sessionKnownHosts
        self.materializeKey = materializeKey
    }
}

/// Resolved credentials for one connection attempt. Password and key authentication cannot be mixed.
public enum SSHAuthentication: Equatable {
    case password(String?)
    case privateKey(path: String, passphrase: String?)

    public init(
        _ connection: SSHConnection,
        materializeKey: (String) -> String?
    ) throws {
        let secret = connection.password.isEmpty ? nil : connection.password
        guard connection.authMethod == .key else {
            self = .password(secret)
            return
        }
        let path =
            connection.keyId.isEmpty
            ? connection.keyPath : (materializeKey(connection.keyId) ?? connection.keyPath)
        guard !path.isEmpty else {
            throw SSHSession.SSHError(message: String(localized: "私钥文件不可用"))
        }
        self = .privateKey(path: path, passphrase: secret)
    }
}

extension SSHSession {
    public static func connect(_ connection: SSHConnection,
                               environment: SSHConnectionEnvironment) throws -> SSHSession {
        let options = try SSHTransportOptions(connection)
        switch try SSHAuthentication(connection, materializeKey: environment.materializeKey) {
        case .password(let password):
            return try connect(
                host: connection.host, port: connection.port, user: connection.user,
                password: password, keyPath: nil, keyPassphrase: nil, options: options,
                realKnownHosts: environment.realKnownHosts,
                sessionKnownHosts: environment.sessionKnownHosts)
        case .privateKey(let path, let passphrase):
            return try connect(
                host: connection.host, port: connection.port, user: connection.user,
                password: nil, keyPath: path, keyPassphrase: passphrase, options: options,
                realKnownHosts: environment.realKnownHosts,
                sessionKnownHosts: environment.sessionKnownHosts)
        }
    }
}

/// 连接身份必须包含认证信息，防止相同地址下不同密码/密钥串用旧连接。
/// 只保留认证摘要，不在缓存键中长期保留密码明文。
public struct SSHConnectionReuseKey: Hashable {
    let host: String
    let port: Int
    let user: String
    private let auth: Data

    public init(_ connection: SSHConnection) {
        host = connection.host; port = connection.port; user = connection.user
        let fields: [String] = [
            connection.authMethod == .key ? "key" : "password",
            connection.keyId, connection.keyPath, connection.password,
            connection.proxyURL, connection.disableProxy.description,
            String(connection.timeoutMs), String(connection.heartbeatMs),
            connection.hostKeyAlgos, connection.ciphers, connection.kexAlgos,
        ]
        auth = Data(SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)))
    }
}
