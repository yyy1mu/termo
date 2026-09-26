import SwiftUI
import UIKit

/// iOS 全局色板：与 macOS 的 dark 主题（Mac/UI/Theme/Theme.swift）同值，集中定义避免零散色值。
enum IOSTheme {
    static let base = Color(hex: 0x151F25)      // 页面背景
    static let mantle = Color(hex: 0x1D2830)    // 分组/次级背景
    static let card = Color(hex: 0x27363F)      // 卡片
    static let text = Color(hex: 0xD5DFE2)      // 主文字
    static let subtext = Color(hex: 0x9FB1B7)   // 次级文字
    static let accent = Color(hex: 0x20B69D)    // 强调青

    /// 延迟/状态分档色（与 macOS Pal 同义）：流畅绿、较高黄、很高红。
    static let good = Color(hex: 0x23D18B)
    static let warning = Color(hex: 0xF5F543)
    static let poor = Color(hex: 0xF14C4C)

    /// 延迟等级：阈值与 macOS LatencyLevel 一致（<80ms 流畅，80–499 较高，≥500 很高；nil 未探测）。
    static func latencyColor(ms: Int?) -> Color {
        guard let ms, ms >= 0 else { return subtext }
        switch ms {
        case ..<80:  return good
        case ..<500: return warning
        default:     return poor
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}
