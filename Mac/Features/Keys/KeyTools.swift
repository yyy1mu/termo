import Foundation
import CTermoSSH

/// 把密钥库（钥匙串）里的私钥落成 ssh 可用的工作文件（0600，等同 ~/.ssh/id_* 的安全姿态）。
/// 幂等：文件已存在则直接复用，避免每次连接重写。删除密钥时清理对应文件。
enum KeyMaterializer {
    enum CacheError: LocalizedError {
        case invalidKeyID
        case cleanup(String)

        var errorDescription: String? {
            switch self {
            case .invalidKeyID:
                return String(localized: "密钥工作文件名称无效，无法安全清理旧私钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            case .cleanup(let detail):
                return String(localized: "旧私钥工作文件未能清理，新私钥尚未保存：\(detail)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
        }
    }

    private static func validKeyID(_ id: String) -> Bool {
        id != "." && id != ".." && id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }

    private static var dir: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("termo/keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return base
    }

    /// 返回该密钥 id 的工作私钥文件路径；钥匙串无此私钥则返回 nil。
    static func path(forKeyId id: String) -> String? {
        guard validKeyID(id) else { return nil }
        let url = dir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let pem = KeyKeychain.privateKey(id) else { return nil }
            do {
                try pem.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { return nil }
        }
        return url.path
    }

    /// 私钥变更前失效旧工作文件；失败时阻止新私钥入库，避免下一次连接继续使用旧文件。
    static func invalidate(_ id: String) throws {
        guard validKeyID(id) else { throw CacheError.invalidKeyID }
        let url = dir.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw CacheError.cleanup(error.localizedDescription) }
        }
    }
}

enum KeyError: LocalizedError {
    case generate(String)
    case importFail(String)

    var errorDescription: String? {
        switch self {
        case .generate(let m): return String(localized: "生成密钥失败：\(m)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .importFail(let m): return String(localized: "导入密钥失败：\(m)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

/// 进程内密钥生成 / 导入（OpenSSL EVP + 手写 OpenSSH 私钥格式，替代 spawn ssh-keygen）。
/// 产物为标准格式：ed25519 私钥 = OpenSSH 格式（加密走 bcrypt）；RSA 私钥 = OpenSSL PKCS#8 PEM；
/// 公钥为标准 `ssh-ed25519/ssh-rsa AAAA... comment` 行。已用系统 ssh-keygen 作 oracle 验证一致。
enum KeyTools {
    struct Generated { let publicKey: String; let privateKey: String; let fingerprint: String }
    struct Imported { let publicKey: String; let fingerprint: String; let type: SSHKeyType; let comment: String; let hasPassphrase: Bool }

    /// 文件选择可同时带同名 .pub；沙盒只保证用户明确选中的文件可读。
    static func selectedImportFiles(_ urls: [URL]) throws -> (privateKey: URL, publicKey: URL?) {
        let privateKeys = urls.filter { !$0.lastPathComponent.hasSuffix(".pub") }
        let publicKeys = urls.filter { $0.lastPathComponent.hasSuffix(".pub") }
        guard privateKeys.count == 1, publicKeys.count <= 1,
              urls.count == privateKeys.count + publicKeys.count else {
            throw KeyError.importFail(String(localized: "请选择一份私钥；加密私钥可再选同名 .pub 公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        let key = privateKeys[0]
        if let publicKey = publicKeys.first,
           (publicKey.lastPathComponent != key.lastPathComponent + ".pub"
                || publicKey.deletingLastPathComponent() != key.deletingLastPathComponent()) {
            throw KeyError.importFail(String(localized: "公钥文件需与私钥同名，并以 .pub 结尾", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        return (key, publicKeys.first)
    }

    /// 生成密钥对（进程内）。passphrase 为空串即无口令。
    static func generate(type: SSHKeyType, comment: String, passphrase: String) throws -> Generated {
        var priv = [CChar](repeating: 0, count: 1 << 15)
        var pub = [CChar](repeating: 0, count: 4096)
        var fp = [CChar](repeating: 0, count: 256)
        var err = [CChar](repeating: 0, count: 256)
        let t: Int32 = type == .ed25519 ? 0 : 1
        let rc = termo_key_generate(t, comment, passphrase, &priv, Int32(priv.count),
                                    &pub, Int32(pub.count), &fp, 256, &err, 256)
        guard rc == 0 else { throw KeyError.generate(localizedGenerationFailure(String(cString: err))) }
        return Generated(publicKey: String(cString: pub),
                         privateKey: String(cString: priv),
                         fingerprint: String(cString: fp))
    }

    /// The Rust FFI currently returns human-readable Chinese diagnostics. Keep that engine
    /// detail out of the English key workflow until the transport adopts stable error codes.
    private static func localizedGenerationFailure(_ raw: String) -> String {
        func detail(after prefix: String) -> String? {
            guard raw.hasPrefix(prefix) else { return nil }
            return String(raw.dropFirst(prefix.count))
        }
        if let value = detail(after: "公钥编码失败: ") {
            return String(localized: "公钥编码失败：\(value)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if let value = detail(after: "生成失败: ") {
            return String(localized: "密钥生成引擎失败：\(value)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if let value = detail(after: "私钥加密失败: ") {
            return String(localized: "私钥加密失败：\(value)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if let value = detail(after: "私钥编码失败: ") {
            return String(localized: "私钥编码失败：\(value)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if let value = detail(after: "类型须为 0/1，收到 ") {
            return String(localized: "不支持的密钥类型：\(value)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        if raw == "内部 panic（已被 FFI 边界拦截）" {
            return String(localized: "密钥生成引擎发生内部错误。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
        return raw
    }

    /// 从私钥文件导入：派生公钥、指纹、类型、是否加密。
    /// 公钥来源优先级：同名 .pub（含注释，即便私钥加密也可读）→ 从私钥派生（OpenSSH 公钥明文 / PEM 未加密）。
    static func importInfo(privatePath: String, publicKeyURL: URL? = nil) throws -> Imported {
        var pubLine = ""
        let siblingPub = privatePath + ".pub"
        if let publicKeyURL {
            pubLine = try String(contentsOf: publicKeyURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pubLine.isEmpty else {
                throw KeyError.importFail(String(localized: "所选 .pub 公钥文件为空", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            }
        } else if let s = try? String(contentsOfFile: siblingPub, encoding: .utf8) {
            pubLine = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var outPub = [CChar](repeating: 0, count: 4096)
        var cType: Int32 = 0
        var cEnc: Int32 = 0
        let rc = termo_key_pubkey_from_private(privatePath, "", &outPub, Int32(outPub.count), &cType, &cEnc)
        let encrypted = rc == 1 || cEnc != 0    // rc=1：PEM 加密无法派生；cEnc：OpenSSH 加密（公钥仍可派生）

        if rc == 0, !pubLine.isEmpty {
            let supplied = pubLine.split(separator: " ").prefix(2)
            let derived = String(cString: outPub).split(separator: " ").prefix(2)
            guard supplied.count == 2, supplied.elementsEqual(derived) else {
                throw KeyError.importFail(String(localized: "所选 .pub 公钥与私钥不匹配", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            }
        }

        if pubLine.isEmpty {
            guard rc == 0 else {
                throw KeyError.importFail(rc == 1
                    ? String(localized: "私钥已加密且无同名 .pub 文件，无法派生公钥；请连同 .pub 一起导入", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    : String(localized: "无法读取私钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            }
            pubLine = String(cString: outPub)
        }
        guard !pubLine.isEmpty else { throw KeyError.importFail(String(localized: "无法读取公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) }

        var fp = [CChar](repeating: 0, count: 256)
        guard termo_key_fingerprint(pubLine, &fp, 256) == 0 else {
            throw KeyError.importFail(String(localized: "所选 .pub 公钥格式无效", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        let fingerprint = String(cString: fp)

        let type: SSHKeyType = pubLine.hasPrefix("ssh-rsa") ? .rsa
            : (pubLine.hasPrefix("ssh-ed25519") ? .ed25519 : (cType == 1 ? .rsa : .ed25519))
        let comment = pubLine.split(separator: " ").dropFirst(2).joined(separator: " ")
        return Imported(publicKey: pubLine, fingerprint: fingerprint, type: type,
                        comment: comment, hasPassphrase: encrypted)
    }
}
