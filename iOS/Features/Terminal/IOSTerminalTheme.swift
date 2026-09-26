import SwiftTerm
import UIKit

/// iOS 终端深色配色：与 macOS 的 dark 色板一致（Theme.swift / TerminalPalette）。
enum IOSTerminalTheme {
    static let background = UIColor(hex: 0x151F25)
    static let foreground = UIColor(hex: 0xD5DFE2)
    static let caret = UIColor(hex: 0x79D8C3)
    static let selection = UIColor(hex: 0x2B5F55)

    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// 16 色 ANSI 调色板（与 macOS TerminalPalette.dark 相同）。
    static var ansiColors: [SwiftTerm.Color] {
        [
            color(0x00, 0x00, 0x00), color(0xcd, 0x31, 0x31), color(0x0d, 0xbc, 0x79), color(0xe5, 0xe5, 0x10),
            color(0x24, 0x72, 0xc8), color(0xbc, 0x3f, 0xbc), color(0x11, 0xa8, 0xcd), color(0xe5, 0xe5, 0xe5),
            color(0x66, 0x66, 0x66), color(0xf1, 0x4c, 0x4c), color(0x23, 0xd1, 0x8b), color(0xf5, 0xf5, 0x43),
            color(0x3b, 0x8e, 0xea), color(0xd6, 0x70, 0xd6), color(0x29, 0xb8, 0xdb), color(0xe5, 0xe5, 0xe5),
        ]
    }

    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    static func apply(to tv: TerminalView) {
        tv.installColors(ansiColors)
        tv.nativeBackgroundColor = background
        tv.nativeForegroundColor = foreground
        tv.caretColor = caret
        tv.caretTextColor = background
        tv.selectedTextBackgroundColor = selection
        tv.keyboardAppearance = .dark
    }
}
