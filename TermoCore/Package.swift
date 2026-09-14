// swift-tools-version: 5.9
// Termo 共享框架（结构占位）：macOS / iOS / watchOS 三端共用代码的未来住所。
// 规划迁入：Core/Models、Core/Persistence、Features/Sync、Rust 引擎适配层，
// 以及不含 AppKit 依赖的 SwiftUI 自绘组件。当前仅占位，macOS 壳代码保持原位。
import PackageDescription

let package = Package(
    name: "TermoCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "TermoCore", targets: ["TermoCore"]),
    ],
    targets: [
        .target(name: "TermoCore", path: "Sources/TermoCore"),
    ]
)
