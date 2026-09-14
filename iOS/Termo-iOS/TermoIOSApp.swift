import SwiftUI
import TermoCore

/// Termo iOS 壳（结构占位）：功能尚未实现。
/// 迁移要点备忘：远程 SSH 终端走 SwiftTerm 的 iOSTerminalView；
/// 本地终端不可迁移（iOS 无 PTY）；后台约 30s 冻结网络，需回前台重连。
@main
struct TermoIOSApp: App {
    var body: some Scene {
        WindowGroup {
            IOSPlaceholderView()
        }
    }
}

struct IOSPlaceholderView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Termo iOS")
                .font(.title2.weight(.semibold))
            Text("结构占位 · \(TermoCoreInfo.name) \(TermoCoreInfo.stage)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("共享框架已接入，功能尚未实现")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    IOSPlaceholderView()
}
