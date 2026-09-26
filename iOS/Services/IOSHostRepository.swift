import Foundation
import TermoCore

/// iOS 主机仓库：非机密字段 JSON 落盘（Application Support/Termo/hosts-ios.json），
/// 密码经 IOSKeychain 存设备钥匙串，绝不写入磁盘。
/// 保存顺序与 macOS 对齐：先写钥匙串再写 JSON；JSON 失败时回滚钥匙串。
@MainActor
final class IOSHostRepository: ObservableObject {
    @Published private(set) var hosts: [IOSHost] = []
    @Published var errorMessage: String?

    private let fileURL: URL?
    private let keychain: IOSKeychain.Storage

    init(inMemory: Bool = false, keychain: IOSKeychain.Storage = .live) {
        self.keychain = keychain
        if inMemory {
            fileURL = nil
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = root.appendingPathComponent("Termo/hosts-ios.json")
        }
        hosts = Self.load(from: fileURL)
        // 凭证读取失败时不伪造密码，也不会在下一次保存时覆盖原钥匙串（空内存值不覆盖）。
        if let saved = try? IOSKeychain.loadAll(service: IOSKeychain.hostPasswordsService, using: keychain) {
            for i in hosts.indices where hosts[i].ssh.authMethod != .ask {
                hosts[i].ssh.password = saved[hosts[i].id] ?? ""
            }
        }
    }

    private static func load(from fileURL: URL?) -> [IOSHost] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        if let hosts = try? JSONDecoder().decode([IOSHost].self, from: data) { return hosts }
        // 旧版格式（[HostProfile]，无凭证）一次性迁移。
        if let legacy = try? JSONDecoder().decode([HostProfile].self, from: data) {
            return legacy.map { IOSHost(legacy: $0) }
        }
        return []
    }

    /// password 为内存中的明文（编辑器填写）；按认证方式决定是否进钥匙串。
    /// 「每次询问」主机的密码永不持久化，且清除可能存在的旧记录。
    @discardableResult
    func save(_ host: IOSHost) -> Bool {
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == host.id }) {
            updated[index] = host
        } else {
            updated.append(host)
        }
        return persistWithCredentialRollback(updated)
    }

    func remove(at offsets: IndexSet) {
        var updated = hosts
        updated.remove(atOffsets: offsets)
        _ = persistWithCredentialRollback(updated)
    }

    /// 先写钥匙串再写 JSON；JSON 失败时回滚钥匙串到先前快照，两处存储不长时间分叉。
    /// iOS 无旧版单条密码条目，回滚无快照时写空映射即可（读取语义等同于不存在）。
    private func persistWithCredentialRollback(_ updated: [IOSHost]) -> Bool {
        let snapshot = try? IOSKeychain.loadAll(service: IOSKeychain.hostPasswordsService, using: keychain)
        do {
            try persistPasswords(updated)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if persist(updated) { return true }
        try? IOSKeychain.saveAll(snapshot ?? [:], service: IOSKeychain.hostPasswordsService, using: keychain)
        return false
    }

    /// 重建密码钥匙串映射：只保留非「每次询问」且非空的密码。
    private func persistPasswords(_ updated: [IOSHost]) throws {
        var passwords: [String: String] = [:]
        for host in updated where host.ssh.authMethod != .ask && !host.ssh.password.isEmpty {
            passwords[host.id] = host.ssh.password
        }
        try IOSKeychain.saveAll(passwords, service: IOSKeychain.hostPasswordsService, using: keychain)
    }

    private func persist(_ updated: [IOSHost]) -> Bool {
        do {
            if let fileURL {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            }
            hosts = updated
            errorMessage = nil
            return true
        } catch {
            // JSON 失败时内存状态不推进；调用方负责回滚钥匙串。
            errorMessage = String(localized: "主机资料保存失败：\(error.localizedDescription)")
            return false
        }
    }
}
