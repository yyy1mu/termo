import SwiftUI

@main
struct TermoWatchApp: App {
    @StateObject private var inbox = WatchHostInbox()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchHostsView(inbox: inbox)
            }
        }
    }
}
