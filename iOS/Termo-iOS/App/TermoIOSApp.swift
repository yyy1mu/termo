import SwiftUI

@main
struct TermoIOSApp: App {
    @StateObject private var hosts = IOSHostRepository()
    @StateObject private var watchBridge = IOSWatchBridge()

    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack {
                    IOSHostsView(repository: hosts)
                }
                .tabItem { Label("主机", systemImage: "server.rack") }

                NavigationStack {
                    IOSSettingsView()
                }
                .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .onReceive(hosts.$hosts) { updated in
                if hosts.errorMessage == nil { watchBridge.publish(hosts: updated) }
            }
        }
    }
}
