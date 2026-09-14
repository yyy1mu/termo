import SwiftUI
import TermoCore

/// Termo Watch 壳（结构占位）：功能尚未实现。
/// 定位备忘：不内嵌 SSH 引擎（体积/耗电/内存限制），
/// 经 WatchConnectivity 与 iPhone 壳桥接，做状态查看与预置快捷命令。
@main
struct TermoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchPlaceholderView()
        }
    }
}

struct WatchPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("Termo Watch")
                .font(.headline)
            Text("结构占位 · \(TermoCoreInfo.stage)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WatchPlaceholderView()
}
