import SwiftUI

struct WatchHostsView: View {
    @ObservedObject var inbox: WatchHostInbox

    var body: some View {
        Group {
            if let snapshot = inbox.snapshot {
                if snapshot.hosts.isEmpty {
                    emptyState("iPhone 上还没有主机", symbol: "server.rack")
                } else {
                    List(snapshot.hosts) { host in
                        Label(host.name, systemImage: "server.rack")
                            .accessibilityLabel(host.name)
                    }
                    .safeAreaInset(edge: .bottom) {
                        Text(
                            "来自 iPhone · \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
            } else {
                emptyState("打开 iPhone 上的 Termo 后，主机名称会显示在这里。", symbol: "iphone")
            }
        }
        .navigationTitle("Termo")
    }

    private func emptyState(_ message: LocalizedStringKey, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
            Text(message).font(.footnote).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }
}
