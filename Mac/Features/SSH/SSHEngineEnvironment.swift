import Foundation
import TermoEngine

/// 平台装配：known_hosts 双文件路径（HostKeyVerifier）与密钥落盘（KeyMaterializer）属 Mac 平台职责，
/// 经 SSHConnectionEnvironment 显式注入引擎；TermoEngine 自身不含任何 Swift 全局状态，可供 iOS 复用。
extension SSHConnectionEnvironment {
    static let mac = SSHConnectionEnvironment(
        realKnownHosts: HostKeyVerifier.realKnownHosts,
        sessionKnownHosts: HostKeyVerifier.sessionKnownHosts,
        materializeKey: { KeyMaterializer.path(forKeyId: $0) })
}

extension SSHSessionPool {
    static let shared = SSHSessionPool(makeHub: { SSHConnectionHub(environment: .mac) })
}
