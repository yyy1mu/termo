import SwiftUI

struct IOSSettingsView: View {
    var body: some View {
        Form {
            Section("开发状态") {
                Label("主机资料保存在本机", systemImage: "iphone")
                Label("主机名称通过配对同步到 Apple Watch", systemImage: "applewatch")
            }
            Section {
                Text("SSH 连接、凭证管理和 WebDAV 同步尚未接入 iOS。当前资料不会自动与 macOS 合并。")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}
