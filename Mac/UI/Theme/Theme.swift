import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case system = "跟随系统"
    case dark = "深色"
    case light = "浅色"

    var label: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .dark: return String(localized: "深色")
        case .light: return String(localized: "浅色")
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
    // 深色工作台：石墨蓝底、柔和薄荷强调色，压低大面积背景亮度。
    static let dark = ThemeColors(
        // 层级微调：crust 最暗、逐档提亮；base 与 mantle 拉开半档，层级更清晰
        crust: Color(hex: 0x0F161D),
        mantle: Color(hex: 0x1A2530),
        base: Color(hex: 0x141D24),
        surface0: Color(hex: 0x2E3E4A),
        card: Color(hex: 0x22323C),
        text: Color(hex: 0xD5E0E3),
        textBright: Color(hex: 0xF4F8F7),
        subtext: Color(hex: 0xA2B6BA),
        overlay: Color(hex: 0x7E949B),   // 提亮：原 0x72868D 过暗难读
        mauve: Color(hex: 0x1BA894),     // 提亮强调色：深色底上原色偏沉
        green: Color(hex: 0x68D3A1),
        yellow: Color(hex: 0xE7BD77),
        red: Color(hex: 0xF08080),
        termBg: 0x141D24, termFg: 0xD5E0E3,
        termCaret: 0x79D6C2, termSelection: 0x28584F,
        baseHex: 0x141D24
    )

    // 浅色工作台：暖白工作面、灰绿导航与深青色强调。
    static let light = ThemeColors(
        // 层级微调：crust/mantle 再沉半档，与近白 base 拉开；次级文字加深提高可读性
        crust: Color(hex: 0xE3ECE9),
        mantle: Color(hex: 0xECF2EF),
        base: Color(hex: 0xFAFCFA),
        surface0: Color(hex: 0xD5E2DD),
        card: Color(hex: 0xFFFFFF),
        text: Color(hex: 0x2D4242),
        textBright: Color(hex: 0x162C2C),
        subtext: Color(hex: 0x55706F),
        overlay: Color(hex: 0x6E8884),   // 加深：原 0x809693 在白底上发灰看不清
        mauve: Color(hex: 0x087E72),
        green: Color(hex: 0x168B62),
        yellow: Color(hex: 0xAB741D),
        red: Color(hex: 0xBD4B4B),
        termBg: 0xFAFCFA, termFg: 0x2D4242,
        termCaret: 0x087E72, termSelection: 0xBFE8DC,
        baseHex: 0xFAFCFA
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
        case .unknown: return String(localized: "未探测")
        case .good:    return String(localized: "流畅")
        case .warning: return String(localized: "延迟较高")
        case .poor:    return String(localized: "延迟很高")
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
