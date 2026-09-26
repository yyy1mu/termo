import Foundation
import TermoEngine

/// iOS 平台装配：known_hosts 双文件路径（IOSKnownHosts）与密钥落盘（IOSKeyMaterializer）
/// 注入引擎；语义与 Mac 侧 SSHEngineEnvironment.swift 一致。
extension SSHConnectionEnvironment {
    static let ios = SSHConnectionEnvironment(
        realKnownHosts: IOSKnownHosts.real,
        sessionKnownHosts: IOSKnownHosts.session,
        materializeKey: { IOSKeyMaterializer.path(forKeyId: $0) })
}

extension SSHSessionPool {
    static let shared = SSHSessionPool(makeHub: { SSHConnectionHub(environment: .ios) })
}
