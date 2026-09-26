import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system = "跟随系统"
    case dark = "深色"
    case light = "浅色"

    var label: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

struct ThemeColors {
    let crust: Color
    let mantle: Color
    let base: Color
    let surface0: Color
    /// 卡片底色：比所在表面亮半档（深色）/纯白（浅色），承载信息卡片。
    let card: Color
    let text: Color
    let textBright: Color
    let subtext: Color
    let overlay: Color
    let mauve: Color
    let green: Color
    let yellow: Color
    let red: Color

    // 终端颜色
    let termBg: UInt32
    let termFg: UInt32
    let termCaret: UInt32
    let termSelection: UInt32

    // 工作区底色的 hex（= base），供以 NSColor 给窗口设底、消除冷启动白闪。
    let baseHex: UInt32
}

extension ThemeColors {
    // 深色工作台：青蓝石墨底、薄荷强调色。色相统一在 H≈200 蓝灰家族（与浅色主题同族），
    // 表面层级等距提亮（L: 8.5 → 11.5 → 15 → 20 → 25），强调色与语义色同族协调。
    static let dark = ThemeColors(
        crust: Color(hex: 0x0F171D),
        mantle: Color(hex: 0x1D2830),
        base: Color(hex: 0x151F25),
        surface0: Color(hex: 0x33434C),
        card: Color(hex: 0x27363F),
        text: Color(hex: 0xD5DFE2),
        textBright: Color(hex: 0xF4F8F8),
        subtext: Color(hex: 0x9FB1B7),
        overlay: Color(hex: 0x7C9098),
        mauve: Color(hex: 0x20B69D),     // 品牌青：比旧色亮半档，小图标/文字在深底上更清晰
        green: Color(hex: 0x6CD0A1),
        yellow: Color(hex: 0xE2B66F),
        red: Color(hex: 0xEA7F7B),
        termBg: 0x151F25, termFg: 0xD5DFE2,
        termCaret: 0x79D8C3, termSelection: 0x2B5F55,
        baseHex: 0x151F25
    )

    // 浅色工作台：冷灰蓝白（与深色主题同 H≈200 色族；旧版偏绿灰，两主题身份不一致）。
    // base 略沉至 L=97，让纯白卡片自然浮起；文字/语义色加深提对比。
    static let light = ThemeColors(
        crust: Color(hex: 0xDDE5E9),
        mantle: Color(hex: 0xE8EDF0),
        base: Color(hex: 0xF6F8F9),
        surface0: Color(hex: 0xD3DBDF),
        card: Color(hex: 0xFFFFFF),
        text: Color(hex: 0x28373E),
        textBright: Color(hex: 0x141F24),
        subtext: Color(hex: 0x50646D),
        overlay: Color(hex: 0x6B7E85),
        mauve: Color(hex: 0x0E7C6D),
        green: Color(hex: 0x178255),
        yellow: Color(hex: 0x9E691A),
        red: Color(hex: 0xC13833),
        termBg: 0xF6F8F9, termFg: 0x28373E,
        termCaret: 0x0E7C6D, termSelection: 0xC4E9E1,
        baseHex: 0xF6F8F9
    )
}

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
            update()
        }
    }

    @Published private(set) var colors: ThemeColors = .dark
    @Published private(set) var isDark: Bool = true

    /// 当前主题的窗口底色（NSColor），用于给 NSWindow 设 backgroundColor，使首帧即品牌深/浅底，消除冷启动白闪。
    var windowBackground: NSColor { NSColor(hex: colors.baseHex) }

    private var systemObserver: NSObjectProtocol?

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appearanceMode") ?? "跟随系统"
        self.mode = AppearanceMode(rawValue: saved) ?? .system
        update()

        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            if self?.mode == .system { self?.update() }
        }
    }

    private func update() {
        switch mode {
        case .dark:
            isDark = true
            NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light:
            isDark = false
            NSApp?.appearance = NSAppearance(named: .aqua)
        case .system:
            // 关键：先清除强制外观，否则 effectiveAppearance 被上一次强制值钉死，
            // 从深/浅切回「跟随系统」时读到的仍是旧值，导致无变化。清空后按系统全局设置判定。
            NSApp?.appearance = nil
            isDark = Self.systemIsDark
        }
        // 同步 AppKit 外观：让系统默认窗口底色与各类系统控件首帧即正确明暗，配合 NSWindow.backgroundColor
        // 消除冷启动白闪；同时避免强制深色时标题栏/菜单等仍为浅色造成的明暗错配。
        colors = isDark ? .dark : .light
    }

    /// 读系统全局外观（不受 App 自身 NSApp.appearance 覆盖影响）。
    private static var systemIsDark: Bool {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        return style?.lowercased().contains("dark") ?? false
    }
}

// 兼容层：Pal 读取当前主题
enum Pal {
    private static var c: ThemeColors { ThemeManager.shared.colors }

    // 窗口表面色（始终不透明）
    static var crust: Color { c.crust }
    static var mantle: Color { c.mantle }
    static var base: Color { c.base }
    // solid* 别名，保留供调用点兼容
    static var solidCrust: Color { c.crust }
    static var solidMantle: Color { c.mantle }
    static var solidBase: Color { c.base }
    static var surface0: Color { c.surface0 }
    static var card: Color { c.card }
    /// 统一分割线/卡片描边：随明暗主题自适应的淡色线。
    static var border: Color { fill(0.07) }
    static var text: Color { c.text }
    static var textBright: Color { c.textBright }
    static var subtext: Color { c.subtext }
    static var overlay: Color { c.overlay }
    static var mauve: Color { c.mauve }
    static var green: Color { c.green }
    static var yellow: Color { c.yellow }
    static var red: Color { c.red }

    /// 自适应叠加色：深色主题用白色叠加，浅色主题用黑色叠加。
    /// 用于 hover / 选中 / 卡片 / 边框等半透明层，保证两种主题下都可见。
    static func fill(_ opacity: Double) -> Color {
        ThemeManager.shared.isDark
            ? Color.white.opacity(opacity)
            : Color.black.opacity(opacity * 1.4)
    }
}

/// 延迟等级：按往返毫秒映射到语义档位，颜色与文字标签共置，主机概览与主机列表共用。
enum LatencyLevel {
    case unknown   // 未探测、失败或超时
    case good      // < 80ms，交互流畅
    case warning   // 80–499ms，可用但有延迟感
    case poor      // ≥ 500ms，明显影响交互

    /// 由单次延迟值判定等级；nil 或负值视为未探测。
    init(ms: Int?) {
        guard let ms, ms >= 0 else { self = .unknown; return }
        switch ms {
        case ..<80:  self = .good
        case ..<500: self = .warning
        default:     self = .poor
        }
    }

    var color: Color {
        switch self {
        case .unknown: return Pal.overlay
        case .good:    return Pal.green
        case .warning: return Pal.yellow
        case .poor:    return Pal.red
        }
    }

    var title: String {
        switch self {
        case .unknown: return String(localized: "未探测", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .good:    return String(localized: "流畅", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .warning: return String(localized: "延迟较高", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .poor:    return String(localized: "延迟很高", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

extension View {
    /// 脱敏:开启时用高斯模糊遮住敏感内容,而非替换文字,视觉更自然。
    /// 用于截图/共享屏幕时隐藏列表/概览里的 IP、主机名。
    @ViewBuilder
    func privacyBlur(_ on: Bool, radius: CGFloat = 3.5) -> some View {
        if on { blur(radius: radius) } else { self }
    }

    /// 悬停显示手型光标，用于按钮、可点击行等交互控件。`active=false`（如禁用态按钮）则不改光标。
    /// 镜像 SidebarDivider 已验证可靠的做法：用 onContinuousHover 逐帧 `set`，压住 AppKit
    /// 的 tracking area 在鼠标移动时把光标重置回箭头——只用 onHover+push/pop 会被重置或失衡卡住。
    @ViewBuilder
    func pointerCursor(_ active: Bool = true) -> some View {
        if active {
            onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.pointingHand.set()
                case .ended:  NSCursor.arrow.set()
                }
            }
        } else {
            self
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
