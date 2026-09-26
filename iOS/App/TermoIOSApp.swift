import SwiftUI

@main
struct TermoIOSApp: App {
    @StateObject private var hosts = IOSHostRepository()
    @StateObject private var keyStore = IOSKeyStore()
    @StateObject private var watchBridge = IOSWatchBridge()

    init() {
        IOSSSHSelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                IOSHostsView(repository: hosts, keyStore: keyStore)
                    .tabItem { Label("主机", systemImage: "server.rack") }

                NavigationStack {
                    IOSSettingsView(keyStore: keyStore)
                }
                .tabItem { Label("设置", systemImage: "gearshape") }
            }
            // 贴 macOS 的深色设计语言：终端色板源自同一套 dark 主题。
            .tint(IOSTheme.accent)
            .preferredColorScheme(.dark)
            .onAppear { keyStore.importTestKeyIfRequested() }
            .onReceive(hosts.$hosts) { updated in
                // Watch 只收无凭证的名称快照。
                if hosts.errorMessage == nil { watchBridge.publish(hosts: updated.map(\.profile)) }
            }
        }
    }
}
