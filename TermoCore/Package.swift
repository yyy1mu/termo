// swift-tools-version: 5.9
// 三端共享的纯 Foundation 模型。平台存储、认证、连接和界面留在各自 target。
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
        .testTarget(name: "TermoCoreTests", dependencies: ["TermoCore"]),
    ]
)
