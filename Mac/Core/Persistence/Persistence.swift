import Foundation
import Security

/// 主机密码的 Keychain 存取——密码只进系统钥匙串，绝不写入磁盘 JSON。
/// 所有主机密码合并为「单条」钥匙串条目（combined*），读取一次即拿到全部，把授权弹窗从「每主机一次」降到「一次」。
/// 旧的逐主机条目（service）仅保留用于迁移读取与删除清理。
enum HostKeychain {
    private static let service = "com.termo.hostPassword"
    private static let combinedService = "com.termo.hostPasswords"
    private static let combinedAccount = "all"

    /// 可注入的系统边界：隔离测试使用内存存储，不访问用户钥匙串。
    struct Storage {
        var read: (String, String) -> (OSStatus, Data?)
        var update: (String, String, Data) -> OSStatus
        var add: (String, String, Data) -> OSStatus
        var remove: (String, String) -> OSStatus

        static let live = Storage(
            read: { service, account in
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            update: { service, account, data in
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account]
                return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            },
            add: { service, account, data in
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
                return SecItemAdd(query as CFDictionary, nil)
            },
            remove: { service, account in
                let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service, kSecAttrAccount as String: account]
                return SecItemDelete(query as CFDictionary)
            })
    }

    struct AccessError: LocalizedError {
        enum Operation {
            case read, save, restore, readPrivateKey, savePrivateKey
        }

        let operation: Operation
        let status: OSStatus
        var errorDescription: String? {
            // Keychain status is an opaque diagnostic code, not a quantity. Interpolate its
            // textual form so locale formatting never inserts thousands separators.
            let code = String(status)
            switch operation {
            case .read:
                return String(localized: "无法读取系统钥匙串（错误 \(code)）。请确认已允许 Termo 访问钥匙串后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .save:
                return String(localized: "无法保存到系统钥匙串（错误 \(code)）。请确认已允许 Termo 访问钥匙串后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .restore:
                return String(localized: "无法恢复系统钥匙串（错误 \(code)）。请确认已允许 Termo 访问钥匙串后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .readPrivateKey:
                return String(localized: "无法从系统钥匙串读取私钥（错误 \(code)）。请确认已允许 Termo 访问钥匙串后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .savePrivateKey:
                return String(localized: "无法将私钥保存到系统钥匙串（错误 \(code)）。请确认已允许 Termo 访问钥匙串后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
        }
    }

    /// nil 表示不存在合并条目；读取失败必须抛出，不能当作空密码库。
    static func loadAll(using storage: Storage = .live) throws -> [String: String]? {
        let (status, data) = storage.read(combinedService, combinedAccount)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccessError(operation: .read, status: status) }
        guard let data else { throw AccessError(operation: .read, status: errSecDecode) }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    /// 原位写入；失败返回调用方。空字典也保留合并条目，避免清空后又恢复旧单条密码。
    static func saveAll(_ map: [String: String], using storage: Storage = .live) throws {
        let data = try JSONEncoder().encode(map)
        let status = storage.update(combinedService, combinedAccount, data)
        if status == errSecItemNotFound {
            let added = storage.add(combinedService, combinedAccount, data)
            guard added == errSecSuccess else { throw AccessError(operation: .save, status: added) }
        } else if status != errSecSuccess {
            throw AccessError(operation: .save, status: status)
        }
    }

    /// 配置文件保存失败时尽力恢复原状态；nil 与空字典不同，nil 必须恢复旧单条密码的回退路径。
    static func restoreAll(_ snapshot: [String: String]?, using storage: Storage = .live) throws {
        if let snapshot {
            try saveAll(snapshot, using: storage)
        } else {
            let status = storage.remove(combinedService, combinedAccount)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AccessError(operation: .restore, status: status)
            }
        }
    }

    static func load(_ hostId: String, using storage: Storage = .live) throws -> String {
        let (status, data) = storage.read(service, hostId)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw AccessError(operation: .read, status: status) }
        guard let data, let value = String(data: data, encoding: .utf8) else {
            throw AccessError(operation: .read, status: errSecDecode)
        }
        return value
    }

    static func delete(_ hostId: String) {
        _ = Storage.live.remove(service, hostId)
    }
}

/// 主机列表与会话历史的 JSON 持久化（~/Library/Application Support/termo/）。
enum HostStore {
    struct SaveRecoveryError: LocalizedError {
        let saveError: Error
        let recoveryError: Error
        var errorDescription: String? {
            String(localized: "主机资料保存失败，原密码也未能恢复。保存错误：\(saveError.localizedDescription)；恢复错误：\(recoveryError.localizedDescription)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static var hostsURL: URL { dir.appendingPathComponent("hosts.json") }
    private static var sessionsURL: URL { dir.appendingPathComponent("sessions.json") }
    private static var forwardsURL: URL { dir.appendingPathComponent("forwards.json") }

    /// 仅返回已选择保存的口令；临时密码从不成为同步或持久化的数据源。
    static func savedPasswords(for hosts: [Host], credentials: HostKeychain.Storage = .live) throws -> [String: String] {
        let combined = try HostKeychain.loadAll(using: credentials)
        return try savedPasswords(for: hosts, combined: combined, credentials: credentials)
    }

    private static func savedPasswords(for hosts: [Host], combined: [String: String]?,
                                       credentials: HostKeychain.Storage) throws -> [String: String] {
        let eligible = hosts.filter { $0.ssh != nil && $0.ssh?.authMethod != .ask }
        var result: [String: String] = [:]
        for host in eligible {
            let value: String
            if let combined { value = combined[host.id] ?? "" }
            else { value = try HostKeychain.load(host.id, using: credentials) }
            if !value.isEmpty { result[host.id] = value }
        }
        return result
    }

    static func loadHosts(at url: URL? = nil, credentials: HostKeychain.Storage = .live) -> [Host] {
        guard let data = try? Data(contentsOf: url ?? hostsURL),
              var hosts = try? JSONDecoder().decode([Host].self, from: data) else { return [] }
        // 旧版本曾把本地化后的“未分组”占位文案写入 hosts.json。
        // 读取时恢复为空值，让当前语言决定显示文案，并防止语言切换后残留中文。
        for i in hosts.indices where hosts[i].group == "未分组" || hosts[i].group == "Ungrouped" {
            hosts[i].group = ""
        }
        // 配置仍可打开；凭证读取失败时不伪造密码，也不会在下一次保存时覆盖原钥匙串。
        if let saved = try? savedPasswords(for: hosts, credentials: credentials) {
            for i in hosts.indices {
                let id = hosts[i].id
                hosts[i].ssh?.password = saved[id] ?? ""
            }
        }
        return hosts
    }

    @discardableResult
    static func saveHosts(
        _ hosts: [Host], clearingPasswordsFor cleared: Set<String> = [],
        ignoringPasswordValuesFor temporary: Set<String> = [],
        at url: URL? = nil, credentials: HostKeychain.Storage = .live
    ) -> Result<Void, Error> {
        do {
            let data = try JSONEncoder().encode(hosts) // CodingKeys 排除明文口令
            // 必须保留完整快照；新列表可能删除主机或改为每次询问，不能用筛选后的口令集合恢复。
            let passwordSnapshot = try HostKeychain.loadAll(using: credentials)
            let saved = try savedPasswords(for: hosts, combined: passwordSnapshot, credentials: credentials)
            var passwords: [String: String] = [:]
            for host in hosts {
                guard let ssh = host.ssh, ssh.authMethod != .ask else { continue }
                if !temporary.contains(host.id), !ssh.password.isEmpty {
                    passwords[host.id] = ssh.password
                } else if !cleared.contains(host.id), let previous = saved[host.id] {
                    // 启动读取未成功或仅改名称时，空内存值不能删除已保存口令。
                    passwords[host.id] = previous
                }
            }
            try HostKeychain.saveAll(passwords, using: credentials)
            do {
                try data.write(to: url ?? hostsURL, options: .atomic)
            } catch let saveError {
                do { try HostKeychain.restoreAll(passwordSnapshot, using: credentials) }
                catch let recoveryError {
                    throw SaveRecoveryError(saveError: saveError, recoveryError: recoveryError)
                }
                throw saveError
            }
            return .success(())
        } catch { return .failure(error) }
    }

    static func loadSessions() -> [SessionEvent] {
        guard let data = try? Data(contentsOf: sessionsURL),
              let s = try? JSONDecoder().decode([SessionEvent].self, from: data) else { return [] }
        return s
    }

    static func saveSessions(_ sessions: [SessionEvent]) {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    static func loadForwards() -> [ForwardRule] {
        guard let data = try? Data(contentsOf: forwardsURL),
              let f = try? JSONDecoder().decode([ForwardRule].self, from: data) else { return [] }
        return f
    }

    static func saveForwards(_ forwards: [ForwardRule]) {
        if let data = try? JSONEncoder().encode(forwards) {
            try? data.write(to: forwardsURL, options: .atomic)
        }
    }
}
