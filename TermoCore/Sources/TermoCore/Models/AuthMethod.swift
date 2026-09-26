import Foundation

public enum AuthMethod: String, CaseIterable, Hashable, Codable, Sendable {
    case password = "密码"
    case key = "密钥"
    case ask = "每次询问"           // 每次连接时弹窗输入本次密码，不保存任何凭证

    // rawValue 已持久化进主机，不能改；显示用本地化 label。
    public var label: String {
        switch self {
        case .password: return String(localized: "密码")
        case .key: return String(localized: "密钥")
        case .ask: return String(localized: "每次询问")
        }
    }
}
