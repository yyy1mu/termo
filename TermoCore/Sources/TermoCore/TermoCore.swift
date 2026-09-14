//  TermoCore：三端共享框架（结构占位，尚未迁入实现）。
//
//  规划迁入的模块（依赖关系自下而上）：
//  1. Rust 引擎桥接（termo_russh_* FFI 封装：会话/exec/shell/转发/SFTP/密钥）
//  2. Core/Models（Host/SSHConnection/ForwardRule/Snippet 等 Codable 模型）
//  3. Core/Persistence（HostStore/KeyStore/SnippetStore/Keychain 封装）
//  4. Features/Sync（WebDAV 同步：SyncCrypto/SyncEngine/SyncStore，纯 Foundation）
//  5. 自绘 UI 组件（Pal/ThemeManager/PrimaryButton/ThemedTextField 等无 AppKit 依赖部分）
//
//  留在各平台壳内：AppKit/UIKit 特化（托盘/窗口/文档面板）、SwiftTerm 终端视图、
//  本地终端（macOS only）、系统通知、Apple Watch 的 WatchConnectivity 桥接。

/// 框架占位信息（三端 target 用它验证包已正确链接）。
public enum TermoCoreInfo {
    public static let name = "TermoCore"
    public static let stage = "skeleton"
}
