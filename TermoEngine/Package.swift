// swift-tools-version: 5.9
// SSH 引擎的 Swift/C 封装层：macOS 与 iOS 共用。Rust 静态库（russh）仍在各 App target 层链接。
import PackageDescription

let package = Package(
    name: "TermoEngine",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TermoEngine", targets: ["TermoEngine"]),
        // C 接口模块（termo_ssh_* / termo_russh_* 声明与派发层）；App 侧直接调 C 的文件也需 import。
        .library(name: "CTermoSSH", targets: ["CTermoSSH"]),
    ],
    dependencies: [
        .package(path: "../TermoCore"),
    ],
    targets: [
        .target(name: "CTermoSSH", path: "Sources/CTermoSSH"),
        .target(
            name: "TermoEngine",
            dependencies: [
                "CTermoSSH",
                .product(name: "TermoCore", package: "TermoCore"),
            ],
            path: "Sources/TermoEngine"
        ),
    ]
)
