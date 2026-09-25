import SwiftUI
import TermoCore

struct IOSHostsView: View {
    @ObservedObject var repository: IOSHostRepository
    @State private var editor: Editor?

    private enum Editor: Identifiable {
        case add
        case edit(HostProfile)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let host): "edit-\(host.id)"
            }
        }
    }

    var body: some View {
        Group {
            if repository.hosts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.tint)
                    Text("还没有主机").font(.headline)
                    Text("先保存连接资料。SSH 终端将在 iOS 端接入后开放。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("添加主机") { editor = .add }
                        .buttonStyle(.borderedProminent)
                }
                .padding(28)
            } else {
                List {
                    ForEach(repository.hosts) { host in
                        Button {
                            editor = .edit(host)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.name).foregroundStyle(.primary)
                                Text("\(host.username)@\(host.hostname):\(host.port)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: repository.remove)
                }
            }
        }
        .navigationTitle("主机")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add
                } label: {
                    Label("添加主机", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .add:
                IOSHostEditor(profile: nil, errorMessage: $repository.errorMessage, onSave: repository.save)
            case .edit(let profile):
                IOSHostEditor(
                    profile: profile, errorMessage: $repository.errorMessage, onSave: repository.save)
            }
        }
        .alert(
            "无法保存主机",
            isPresented: Binding(
                get: { editor == nil && repository.errorMessage != nil },
                set: { if !$0 { repository.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { repository.errorMessage = nil }
        } message: {
            Text(repository.errorMessage ?? "")
        }
    }
}

#Preview {
    NavigationStack { IOSHostsView(repository: IOSHostRepository(inMemory: true)) }
}
