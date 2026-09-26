import CTermoSSH
import Foundation

/// iOS 密钥库条目：元数据 JSON 落盘，私钥只进设备钥匙串（IOSKeychain.privateKeysService）。
struct IOSKey: Codable, Identifiable, Equatable, Sendable {
    enum KeyType: String, Codable, Sendable {
        case ed25519, rsa
        var label: String { self == .ed25519 ? "ed25519" : "RSA 4096" }
    }

    var id: String
    var name: String
    var type: KeyType
    var publicKey: String      // 标准 `ssh-ed25519 AAAA... comment` 公钥行
    var fingerprint: String    // "SHA256:…"
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, type: KeyType,
         publicKey: String, fingerprint: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.type = type
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.createdAt = createdAt
    }
}

/// 进程内密钥生成 / 导入（引擎 C API，与 macOS KeyTools 同一 russh 后端；替代 ssh-keygen 子进程）。
enum IOSKeyTools {
    struct Generated { let publicKey: String; let privateKey: String; let fingerprint: String }

    struct KeyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 生成密钥对（进程内）。passphrase 为空串即无口令；私钥文本由调用方写入钥匙串。
    static func generate(type: IOSKey.KeyType, comment: String, passphrase: String) throws -> Generated {
        var priv = [CChar](repeating: 0, count: 1 << 15)
        var pub = [CChar](repeating: 0, count: 4096)
        var fp = [CChar](repeating: 0, count: 256)
        var err = [CChar](repeating: 0, count: 256)
        let t: Int32 = type == .ed25519 ? 0 : 1
        let rc = termo_key_generate(t, comment, passphrase, &priv, Int32(priv.count),
                                    &pub, Int32(pub.count), &fp, 256, &err, 256)
        guard rc == 0 else {
            throw KeyError(message: String(localized: "生成密钥失败：\(String(cString: err))"))
        }
        return Generated(publicKey: String(cString: pub),
                         privateKey: String(cString: priv),
                         fingerprint: String(cString: fp))
    }

    /// 从粘贴的私钥文本派生公钥与指纹（引擎只接受文件路径，经临时文件中转，用完即删）。
    static func importInfo(privateKeyPEM: String) throws -> (publicKey: String, fingerprint: String, type: IOSKey.KeyType) {
        let trimmed = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw KeyError(message: String(localized: "私钥内容为空"))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("termo-ios-import-\(UUID().uuidString)")
        do {
            try trimmed.write(to: temp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        } catch {
            throw KeyError(message: String(localized: "无法读取私钥"))
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        var outPub = [CChar](repeating: 0, count: 4096)
        var cType: Int32 = 0
        var cEnc: Int32 = 0
        let rc = termo_key_pubkey_from_private(temp.path, "", &outPub, Int32(outPub.count), &cType, &cEnc)
        // rc=1：PEM 加密无法派生公钥；OpenSSH 加密仍可派生（rc=0 且 cEnc=1）。
        guard rc == 0 else {
            throw KeyError(message: String(localized:
                rc == 1 ? "私钥已加密（PEM），暂不支持导入；请生成新密钥或导入未加密/OpenSSH 格式私钥" : "无法读取私钥"))
        }
        let pubLine = String(cString: outPub)
        guard !pubLine.isEmpty else { throw KeyError(message: String(localized: "无法读取公钥")) }

        var fp = [CChar](repeating: 0, count: 256)
        guard termo_key_fingerprint(pubLine, &fp, 256) == 0 else {
            throw KeyError(message: String(localized: "私钥格式无效"))
        }
        let type: IOSKey.KeyType = pubLine.hasPrefix("ssh-rsa") ? .rsa : .ed25519
        return (pubLine, String(cString: fp), type)
    }
}

/// 密钥元数据的 JSON 持久化（Application Support/Termo/keys-ios.json）。
/// 私钥变更顺序：先失效旧工作文件 → 写钥匙串 → 写元数据；删除同理反向，避免遗留可用私钥。
@MainActor
final class IOSKeyStore: ObservableObject {
    @Published private(set) var keys: [IOSKey] = []
    @Published var errorMessage: String?

    private let fileURL: URL?
    private let keychain: IOSKeychain.Storage

    init(inMemory: Bool = false, keychain: IOSKeychain.Storage = .live) {
        self.keychain = keychain
        if inMemory {
            fileURL = nil
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = root.appendingPathComponent("Termo/keys-ios.json")
        }
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([IOSKey].self, from: data) {
            keys = decoded
        }
    }

    /// 生成 ed25519/RSA 密钥并入库（私钥进钥匙串）。
    @discardableResult
    func generate(name: String, type: IOSKey.KeyType, passphrase: String) -> IOSKey? {
        do {
            let comment = "termo-ios \(name)"
            let g = try IOSKeyTools.generate(type: type, comment: comment, passphrase: passphrase)
            let key = IOSKey(name: name, type: type, publicKey: g.publicKey, fingerprint: g.fingerprint)
            try IOSKeychain.set(key.id, g.privateKey, service: IOSKeychain.privateKeysService, using: keychain)
            return persist(keys + [key]) ? key : nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 导入粘贴的私钥文本（PEM/OpenSSH 格式）。
    @discardableResult
    func importKey(name: String, pem: String) -> IOSKey? {
        do {
            let info = try IOSKeyTools.importInfo(privateKeyPEM: pem)
            let key = IOSKey(name: name, type: info.type, publicKey: info.publicKey, fingerprint: info.fingerprint)
            try IOSKeychain.set(key.id, pem, service: IOSKeychain.privateKeysService, using: keychain)
            return persist(keys + [key]) ? key : nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func remove(_ key: IOSKey) {
        // 先失效工作文件再删钥匙串，保证任何时刻都不会出现「元数据没了但私钥仍可用」。
        try? IOSKeyMaterializer.invalidate(key.id)
        try? IOSKeychain.remove(key.id, service: IOSKeychain.privateKeysService, using: keychain)
        _ = persist(keys.filter { $0.id != key.id })
    }

    /// 隐藏自测通道：`-importTestKey <名称> <私钥文件路径>` 启动参数，启动后导入该私钥。
    /// 供 UI 测试注入密钥（正常启动无此参数，空操作）；同指纹密钥已存在则跳过，重复启动不重复入库。
    @discardableResult
    func importTestKeyIfRequested() -> IOSKey? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-importTestKey"), args.count > i + 2,
              let pem = try? String(contentsOfFile: args[i + 2], encoding: .utf8),
              let info = try? IOSKeyTools.importInfo(privateKeyPEM: pem)
        else { return nil }
        if let existing = keys.first(where: { $0.fingerprint == info.fingerprint }) { return existing }
        return importKey(name: args[i + 1], pem: pem)
    }

    private func persist(_ updated: [IOSKey]) -> Bool {
        do {
            if let fileURL {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            }
            keys = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "密钥资料保存失败：\(error.localizedDescription)")
            return false
        }
    }
}

/// 把钥匙串里的私钥落成引擎可用的 0600 工作文件（等同 macOS KeyMaterializer 的安全姿态）。
/// 幂等：文件已存在则直接复用，避免每次连接重写。
enum IOSKeyMaterializer {
    private static func validKeyID(_ id: String) -> Bool {
        id != "." && id != ".." && id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }

    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termo/keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    /// 返回该密钥 id 的工作私钥文件路径；钥匙串无此私钥则返回 nil。
    static func path(forKeyId id: String) -> String? {
        guard validKeyID(id) else { return nil }
        let url = dir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let pem = IOSKeychain.value(id, service: IOSKeychain.privateKeysService) else { return nil }
            do {
                try pem.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { return nil }
        }
        return url.path
    }

    /// 私钥变更/删除前失效旧工作文件。
    static func invalidate(_ id: String) throws {
        guard validKeyID(id) else { return }
        let url = dir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
