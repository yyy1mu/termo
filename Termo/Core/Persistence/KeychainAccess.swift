import Foundation
import Security

/// Keychain 访问控制：让本 App 存的所有机密条目的读取提示从「输入登录密码」
/// 变为「Touch ID 或设备密码」（macOS 系统级，无需自研弹窗）。
///
/// 背景：未签名/ad-hoc 构建读 Keychain 时，macOS 每次启动都要输一次登录密码，
/// 体验很差。给条目加 `SecAccessControl`（biometryCurrentSet OR devicePasscode）后，
/// 系统提示自动变为生物识别优先——有 Touch ID 的机器按一下手指，没有则输设备密码。
///
/// 注意：已存在的旧条目（无访问控制）行为不变——需要一次性迁移（读取后用新参数重写一次，
/// 迁移过程本身只需再输一次密码，此后永久走生物识别）。
enum KeychainAccess {
    /// 生成访问控制对象；macOS 12+ 支持。失败（极老系统/无生物识别）返回 nil，
    /// 调用方应跳过该属性（行为回退为默认登录密码提示，不破坏功能）。
    static func control() -> SecAccessControl? {
        SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlock,
            .userPresence,   // = Touch ID 或设备密码（macOS 上兼容性最好的组合）
            nil
        )
    }

    /// 在 SecItemAdd 的查询里注入访问控制（若可用）。
    static func attach(_ query: inout [String: Any]) {
        if let c = control() {
            query[kSecAttrAccessControl as String] = c
        }
    }
}
