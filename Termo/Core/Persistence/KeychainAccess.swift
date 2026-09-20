import Foundation
import Security

/// Keychain 访问控制（用户可选）：开启后本 App 存的机密条目（主机密码 / SSH 私钥 / LLM Key）
/// 的读取提示变为「Touch ID 或设备密码」；关闭则回退默认行为（配合签名构建通常免提示）。
///
/// 首次启动由引导弹窗让用户选择（见 TermoApp 的 isChosen 分支），设置 → 通用 可随时切换。
/// 每次状态切换都会把已有条目按新模式重写（见各 store 的 syncAccessControl，重写后验证读回）。
enum KeychainAccess {
    private static let prefKey = "keychain.biometric.enabled"

    /// 是否已开启指纹/设备密码验证（未选择时视为关）。
    static var enabled: Bool { UserDefaults.standard.bool(forKey: prefKey) }
    /// 用户是否已做过选择（首次启动引导弹窗只在未选择时显示一次）。
    static var isChosen: Bool { UserDefaults.standard.object(forKey: prefKey) != nil }

    /// 选择/切换入口：写偏好并同步重写全部机密条目。
    static func setEnabled(_ v: Bool) {
        UserDefaults.standard.set(v, forKey: prefKey)
        syncAllIfNeeded()
    }

    /// 启动时同步入口：三个 store 各自查状态戳，模式没变就零开销跳过。
    static func syncAllIfNeeded() {
        HostKeychain.syncAccessControl()
        KeyKeychain.syncAccessControl()
        LLMSettingsStore.syncAccessControl()
    }

    /// 生成访问控制对象；关闭时返回 nil（条目按默认模式写入）。
    static func control() -> SecAccessControl? {
        guard enabled else { return nil }
        return SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlock,
            .userPresence,   // = Touch ID 或设备密码（macOS 上兼容性最好的组合）
            nil
        )
    }

    /// 在 SecItemAdd 的查询里注入访问控制（若可用/已开启）。
    static func attach(_ query: inout [String: Any]) {
        if let c = control() {
            query[kSecAttrAccessControl as String] = c
        }
    }
}
