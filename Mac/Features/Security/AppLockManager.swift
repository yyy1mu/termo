import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// 新主密码用现有 PBKDF2 + AES-GCM 校验记录；保留旧版 salted SHA-256 锁定码验证。
/// 记录仅验证输入，不保存或恢复明文主密码。
enum AppPasswordRecord {
    private static let marker = Data("termo-master-password-v1".utf8)

    static func isLegacy(_ record: String) -> Bool { !record.hasPrefix("master-v1:") }

    static func make(_ password: String) throws -> String {
        guard password.count >= 8, !password.contains("\0"), !password.contains(where: \.isNewline) else {
            throw AppPasswordError.invalidPassword
        }
        return "master-v1:" + (try SyncCrypto.encrypt(marker, password: password)).base64EncodedString()
    }

    static func verify(_ password: String, record: String) -> Bool {
        guard !password.contains("\0") else { return false }
        if !isLegacy(record) {
            guard let data = Data(base64Encoded: String(record.dropFirst("master-v1:".count))),
                let plain = try? SyncCrypto.decrypt(data, password: password)
            else { return false }
            return plain == marker
        }
        let parts = record.split(separator: ":")
        guard parts.count == 2 else { return false }
        let hash = SHA256.hash(data: Data((String(parts[0]) + password).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return hash == parts[1]
    }
}

enum AppPasswordError: LocalizedError {
    case invalidPassword, wrongCurrentPassword, sessionChanged, keychain(OSStatus), readKeychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalidPassword: return String(localized: "主密码至少 8 个字符，可包含文字、数字和符号", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .wrongCurrentPassword: return String(localized: "当前密码不正确", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .sessionChanged: return String(localized: "应用已锁定，请解锁后重试", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .keychain(let status): return String(localized: "无法保存主密码，原密码未更改（\(status)）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .readKeychain(let status): return String(localized: "无法读取主密码校验记录，请允许 Termo 访问系统钥匙串后重试（\(status)）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

/// 应用锁与同步共用主密码。明文只在解锁会话内保存，锁定即清除；Touch ID 不恢复主密码。
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()
    @Published private(set) var isLocked = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var masterPassword: String?
    @Published private(set) var credentialError: String?

    struct CredentialStore {
        var read: () throws -> String?
        var write: (String) throws -> Void

        static let keychain = CredentialStore(
            read: {
                var query = keychainQuery
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecItemNotFound { return nil }
                guard status == errSecSuccess else { throw AppPasswordError.readKeychain(status) }
                guard let data = item as? Data, let record = String(data: data, encoding: .utf8) else {
                    throw AppPasswordError.readKeychain(errSecDecode)
                }
                return record
            },
            write: { record in
                let data = Data(record.utf8)
                var status = SecItemUpdate(
                    keychainQuery as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    var query = keychainQuery
                    query[kSecValueData as String] = data
                    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    status = SecItemAdd(query as CFDictionary, nil)
                }
                guard status == errSecSuccess else { throw AppPasswordError.keychain(status) }
            })

        // 沿用旧 service/account；写入失败时保留原记录。
        private static var keychainQuery: [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.termo.appLock", kSecAttrAccount as String: "pin",
            ]
        }
    }

    private let d: UserDefaults
    private let credentials: CredentialStore
    // 仅缓存密码校验记录；界面、空闲计时和 hasPin 不再触发系统授权。
    private var cachedRecord: String?
    private var recordReadFailed = false
    private(set) var sessionGeneration = 0

    init(defaults: UserDefaults = .standard, credentials: CredentialStore = .keychain) {
        d = defaults
        self.credentials = credentials
        isEnabled = defaults.bool(forKey: "applock.enabled")
        do { cachedRecord = try credentials.read() }
        catch {
            recordReadFailed = true
            credentialError = Self.userFacingCredentialError(error)
        }
        // 钥匙串读取被拒绝时保持锁定，不能把失败当作未设置密码。
        isLocked = isEnabled && (cachedRecord != nil || recordReadFailed)
    }

    var hasPin: Bool { cachedRecord != nil || recordReadFailed }
    var usesLegacyPin: Bool { cachedRecord.map(AppPasswordRecord.isLegacy) ?? false }
    var hasMasterPassword: Bool { hasPin && !usesLegacyPin }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        d.set(on, forKey: "applock.enabled")
        if !on { isLocked = false }
    }

    @MainActor
    func setMasterPassword(_ password: String, currentPassword: String) async throws {
        let generation = sessionGeneration
        guard !isLocked else { throw AppPasswordError.sessionChanged }
        if let record = try authenticationRecord() {
            let valid = await Task.detached { AppPasswordRecord.verify(currentPassword, record: record) }
                .value
            guard valid else { throw AppPasswordError.wrongCurrentPassword }
        }
        let record = try await Task.detached { try AppPasswordRecord.make(password) }.value
        guard generation == sessionGeneration, !isLocked else { throw AppPasswordError.sessionChanged }
        try credentials.write(record)
        cachedRecord = record
        recordReadFailed = false
        credentialError = nil
        sessionGeneration += 1
        masterPassword = password
    }

    /// 密码解锁与同步授权走同一校验；旧锁定码只解锁，不用作新的备份密钥。
    @MainActor
    func verifyPassword(_ password: String) async -> Bool {
        let generation = sessionGeneration
        let record: String
        credentialError = nil
        do {
            guard let stored = try authenticationRecord() else { return false }
            record = stored
        } catch {
            credentialError = Self.userFacingCredentialError(error)
            return false
        }
        let valid = await Task.detached { AppPasswordRecord.verify(password, record: record) }.value
        guard generation == sessionGeneration else { return false }
        if valid && !AppPasswordRecord.isLegacy(record) { masterPassword = password }
        return valid
    }

    /// 锁屏只显示可操作的产品提示，不把 Keychain / LocalAuthentication 的内部错误原样暴露给用户。
    static func userFacingCredentialError(_ error: Error) -> String {
        if let error = error as? AppPasswordError {
            return error.localizedDescription
        }
        return String(localized: "无法访问主密码，请检查系统钥匙串后重试", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
    }

    /// 解锁（锁定屏/触摸成功后调用）。
    func unlock() {
        isLocked = false
        lastActivity = Date()  // 解锁后重新计空闲
    }

    // MARK: - 立即锁定 / 空闲自动锁

    /// 空闲自动锁定时长（分钟），默认 5。设置 → 安全 可调。
    var idleMinutes: Int {
        get { d.object(forKey: "applock.idleMinutes") as? Int ?? 5 }
        set { d.set(newValue, forKey: "applock.idleMinutes") }
    }

    private var activityMonitor: Any?
    private var idleTimer: Timer?
    /// 最近一次本 App 内的键鼠活动时间（本地事件监听，只算用户真正在用 Termo）。
    private var lastActivity = Date()

    /// 启动活动监听（AppDelegate 启动时调一次）：键鼠活动刷新时间戳 + 周期检查空闲超时。
    func startIdleWatching() {
        guard activityMonitor == nil else { return }
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] ev in
            self?.lastActivity = Date()
            return ev
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkIdleLock()
        }
    }

    private func checkIdleLock() {
        guard isEnabled, hasPin, !isLocked, idleMinutes > 0 else { return }  // 0 = 从不自动锁定
        if Date().timeIntervalSince(lastActivity) >= TimeInterval(idleMinutes * 60) {
            lock()
        }
    }

    /// 立即锁定（⌘L 菜单与空闲超时共用）。
    /// 未启用启动锁/未设锁定码时无操作——避免把没设码的用户锁死在锁定屏。
    func lock() {
        guard isEnabled, hasPin, !isLocked else { return }
        lastActivity = Date()
        sessionGeneration += 1
        masterPassword = nil
        isLocked = true
    }

    /// Touch ID 解锁：仅生物识别策略——系统密码策略会绕过我们的锁定码，故不用 .deviceOwnerAuthentication。
    @MainActor
    func unlockWithBiometrics() async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return false
        }
        do {
            return try await ctx.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: String(localized: "解锁", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) + " Termo"
            )
        } catch {
            return false  // 用户取消/失败 → 走锁定码输入
        }
    }

    /// 本机是否可用生物识别（有 Touch ID 且已录指纹）。
    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// 初次读取失败后仅在用户明确验证/改密时重试，不在 UI 刷新和定时器里重试。
    private func authenticationRecord() throws -> String? {
        if recordReadFailed {
            cachedRecord = try credentials.read()
            recordReadFailed = false
            credentialError = nil
        }
        return cachedRecord
    }
}
