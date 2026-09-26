import SwiftUI

struct IOSSettingsView: View {
    @ObservedObject var keyStore: IOSKeyStore

    var body: some View {
        Form {
            Section(String(localized: "安全")) {
                NavigationLink {
                    IOSKeysView(keyStore: keyStore)
                } label: {
                    Label(String(localized: "密钥"), systemImage: "key")
                }
                Label(String(localized: "密码与私钥保存在设备钥匙串"), systemImage: "lock.shield")
            }
            Section(String(localized: "同步")) {
                Label(String(localized: "主机名称通过配对同步到 Apple Watch"), systemImage: "applewatch")
                Text(String(localized: "凭证不会离开本设备；WebDAV 同步尚未接入 iOS，当前资料不会自动与 macOS 合并。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "设置"))
    }
}
