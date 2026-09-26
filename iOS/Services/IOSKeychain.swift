import Foundation
import Security

/// iOS 凭证的 Keychain 存取——密码与私钥只进系统钥匙串，绝不写入磁盘 JSON。
/// 同一 service 下所有条目合并为「单条」钥匙串项（account="all"，JSON 字典），
/// 读取一次即拿到全部，与 macOS 的 HostKeychain/KeyKeychain 策略一致。
enum IOSKeychain {
    /// service 命名空间（任务约定）：主机密码与 SSH 私钥各占一条。
    static let hostPasswordsService = "com.cloudza.termo.ios.hostPasswords"
    static let privateKeysService = "com.cloudza.termo.ios.privateKeys"
    private static let account = "all"

    /// 可注入的系统边界：隔离测试使用内存存储，不访问设备钥匙串。
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
        let operation: String
        let status: OSStatus
        var errorDescription: String? {
            String(localized: "无法\(operation)设备钥匙串（错误 \(status)）。请重试。")
        }
    }

    /// nil 表示条目不存在；读取失败必须抛出，不能当作空库。
    static func loadAll(service: String, using storage: Storage = .live) throws -> [String: String]? {
        let (status, data) = storage.read(service, account)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw AccessError(operation: "读取", status: status) }
        guard let data else { throw AccessError(operation: "读取", status: errSecDecode) }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    static func saveAll(_ map: [String: String], service: String, using storage: Storage = .live) throws {
        let data = try JSONEncoder().encode(map)
        let status = storage.update(service, account, data)
        if status == errSecItemNotFound {
            let added = storage.add(service, account, data)
            guard added == errSecSuccess else { throw AccessError(operation: "保存到", status: added) }
        } else if status != errSecSuccess {
            throw AccessError(operation: "保存到", status: status)
        }
    }

    static func value(_ id: String, service: String, using storage: Storage = .live) -> String? {
        try? loadAll(service: service, using: storage)?[id]
    }

    static func set(_ id: String, _ value: String, service: String, using storage: Storage = .live) throws {
        var map = try loadAll(service: service, using: storage) ?? [:]
        map[id] = value
        try saveAll(map, service: service, using: storage)
    }

    static func remove(_ id: String, service: String, using storage: Storage = .live) throws {
        var map = try loadAll(service: service, using: storage) ?? [:]
        map.removeValue(forKey: id)
        try saveAll(map, service: service, using: storage)
    }
}
