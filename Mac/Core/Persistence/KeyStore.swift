import Foundation
import Security

/// 密钥元数据的 JSON 持久化。私钥仅交给系统钥匙串，不写入此文件。
enum KeyStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo/keys.json")
    }

    static func load() -> [SSHKey] {
        guard let data = try? Data(contentsOf: url),
              let keys = try? JSONDecoder().decode([SSHKey].self, from: data) else { return [] }
        return keys
    }

    static func save(_ keys: [SSHKey], at destination: URL? = nil) throws {
        let destination = destination ?? url
        let data = try JSONEncoder().encode(keys)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    /// 两处存储都成功后，调用方才发布新列表；JSON 失败时恢复先前的私钥快照。
    static func save(_ keys: [SSHKey], updatingPrivateKeys update: (inout [String: String]) -> Void,
                     at destination: URL? = nil, credentials: KeyKeychain.Storage = .live,
                     beforePrivateKeysChange: ([String]) throws -> Void = { _ in }) throws {
        let original = try KeyKeychain.loadAll(using: credentials)
        var updated = original
        update(&updated)
        let changedIDs = Set(original.keys).union(updated.keys)
            .filter { original[$0] != updated[$0] }.sorted()
        try beforePrivateKeysChange(changedIDs)
        try KeyKeychain.saveAll(updated, using: credentials)
        do {
            try save(keys, at: destination)
        } catch {
            let saveError = error
            do { try KeyKeychain.saveAll(original, using: credentials) }
            catch { throw RollbackError(saveError: saveError, rollbackError: error) }
            throw saveError
        }
    }

    private struct RollbackError: LocalizedError {
        let saveError: Error
        let rollbackError: Error
        var errorDescription: String? {
            String(localized: "密钥列表未能保存：\(saveError.localizedDescription)；恢复原私钥记录也失败：\(rollbackError.localizedDescription)。请检查存储权限后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

/// 全部私钥合并为一个条目。读取失败不能当作空库；保存失败不能先删除旧数据。
enum KeyKeychain {
    typealias Storage = HostKeychain.Storage
    private static let service = "com.termo.sshPrivateKeys"
    private static let account = "all"

    static func loadAll(using storage: Storage = .live) throws -> [String: String] {
        let (status, data) = storage.read(service, account)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess else { throw HostKeychain.AccessError(operation: .readPrivateKey, status: status) }
        guard let data, let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw HostKeychain.AccessError(operation: .readPrivateKey, status: errSecDecode)
        }
        return map
    }

    static func saveAll(_ map: [String: String], using storage: Storage = .live) throws {
        let data = try JSONEncoder().encode(map)
        let status = storage.update(service, account, data)
        if status == errSecItemNotFound {
            let added = storage.add(service, account, data)
            guard added == errSecSuccess else { throw HostKeychain.AccessError(operation: .savePrivateKey, status: added) }
        } else if status != errSecSuccess {
            throw HostKeychain.AccessError(operation: .savePrivateKey, status: status)
        }
    }

    /// 连接入口仍以 nil 表示私钥不可用，写入和同步入口使用 throwing API。
    static func privateKey(_ id: String) -> String? { try? loadAll()[id] }

    static func set(_ id: String, _ pem: String, using storage: Storage = .live) throws {
        var map = try loadAll(using: storage)
        map[id] = pem
        try saveAll(map, using: storage)
    }

    static func remove(_ id: String, using storage: Storage = .live) throws {
        var map = try loadAll(using: storage)
        map.removeValue(forKey: id)
        try saveAll(map, using: storage)
    }
}
