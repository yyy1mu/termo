import Foundation
import LocalAuthentication
import CryptoKit
import Security

/// 启动锁：启用后 App 启动时显示锁定屏，需 **Touch ID 或 6 位锁定码** 解锁进入。
/// 锁定码加盐 SHA-256 存 Keychain（service=com.termo.appLock），不设明文恢复——忘记只能删偏好重置。
/// 与钥匙串 ACL 无关（那套机制已移除）；签名构建读 Keychain 本就免提示。
final class AppLockManager: ObservableObject {
    static let shared = AppLockManager()

    /// 当前是否处于锁定态（TermoApp 据此盖锁定屏）。
    @Published private(set) var isLocked = false
    /// 启动锁开关（设置 → 安全）。
    @Published private(set) var isEnabled: Bool

    private let d = UserDefaults.standard
    private let service = "com.termo.appLock"
    private let account = "pin"

    private init() {
        isEnabled = d.bool(forKey: "applock.enabled")
        // 启动即锁：开关开着且锁定码存在才锁（二者缺一都不具备锁定意义）
        if isEnabled, pinRecord() != nil { isLocked = true }
    }

    /// 是否已设置锁定码（未设码时开关不可用，先引导设码）。
    var hasPin: Bool { pinRecord() != nil }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        d.set(on, forKey: "applock.enabled")
        if !on { isLocked = false }
    }

    /// 设置/覆盖锁定码（6 位数字；调用方负责校验两次输入一致）。
    func setPin(_ pin: String) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = saltBytes.map { String(format: "%02x", $0) }.joined()
        let rec = salt + ":" + sha(salt + pin)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = rec.data(using: .utf8) as Any
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    func verifyPin(_ pin: String) -> Bool {
        guard let rec = pinRecord() else { return false }
        let parts = rec.split(separator: ":")
        guard parts.count == 2 else { return false }
        return sha(String(parts[0]) + pin) == parts[1]
    }

    /// 解锁（锁定屏/触摸成功后调用）。
    func unlock() { isLocked = false }

    /// Touch ID 解锁：仅生物识别策略——系统密码策略会绕过我们的锁定码，故不用 .deviceOwnerAuthentication。
    @MainActor
    func unlockWithBiometrics() async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        do {
            return try await ctx.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁 Termo"
            )
        } catch {
            return false   // 用户取消/失败 → 走锁定码输入
        }
    }

    /// 本机是否可用生物识别（有 Touch ID 且已录指纹）。
    var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func pinRecord() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
