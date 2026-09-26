import SwiftUI
import TermoCore

/// 主机页：iPhone（compact）用 NavigationStack 栈式导航；iPad（regular）用 NavigationSplitView
/// 左列表右详情。折叠态 SplitView 的 selection 导航在 iOS 27 模拟器上不触发 push（实测），
/// 故按 size class 分流而不是依赖折叠行为。
struct IOSHostsView: View {
    @ObservedObject var repository: IOSHostRepository
    @ObservedObject var keyStore: IOSKeyStore
    @StateObject private var latencyStore = IOSLatencyStore()
    @State private var selectedID: String?
    @State private var adding = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                NavigationStack { sidebar(stackMode: true) }
            } else {
                NavigationSplitView {
                    sidebar(stackMode: false)
                } detail: {
                    if let host = repository.hosts.first(where: { $0.id == selectedID }) {
                        IOSHostDetailView(host: host, repository: repository, keyStore: keyStore)
                            .id(host.id)   // 切换主机时重建详情，监控换绑到新主机
                    } else {
                        Text(String(localized: "选择主机查看详情"))
                            .foregroundStyle(IOSTheme.subtext)
                    }
                }
            }
        }
        .sheet(isPresented: $adding) {
            IOSHostEditor(host: nil, keyStore: keyStore,
                          errorMessage: $repository.errorMessage, onSave: repository.save)
        }
        .alert(
            String(localized: "无法保存主机"),
            isPresented: Binding(
                get: { !adding && repository.errorMessage != nil },
                set: { if !$0 { repository.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) { repository.errorMessage = nil }
        } message: {
            Text(repository.errorMessage ?? "")
        }
        // 订阅即回调一次，覆盖 onAppear；之后随主机增删改刷新延迟。
        .onReceive(repository.$hosts) { latencyStore.probe($0) }
    }

    @ViewBuilder
    private func sidebar(stackMode: Bool) -> some View {
        if repository.hosts.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.tint)
                Text(String(localized: "还没有主机")).font(.headline)
                Text(String(localized: "添加主机后即可连接 SSH 终端。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "添加主机")) { adding = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("addHostButton")
            }
            .padding(28)
            .navigationTitle(String(localized: "主机"))
        } else if stackMode {
            // iPhone：栈式，NavigationLink push 详情
            List {
                ForEach(repository.hosts) { host in
                    NavigationLink(value: host.id) { row(host) }
                }
                .onDelete(perform: repository.remove)
            }
            .navigationTitle(String(localized: "主机"))
            .navigationDestination(for: String.self) { id in
                if let host = repository.hosts.first(where: { $0.id == id }) {
                    IOSHostDetailView(host: host, repository: repository, keyStore: keyStore)
                }
            }
            .toolbar { addButton }
        } else {
            // iPad：分栏，selection 驱动 detail 列
            List(selection: $selectedID) {
                ForEach(repository.hosts) { host in
                    row(host).tag(host.id)
                }
                .onDelete(perform: repository.remove)
            }
            .navigationTitle(String(localized: "主机"))
            .toolbar { addButton }
        }
    }

    private var addButton: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                adding = true
            } label: {
                Label(String(localized: "添加主机"), systemImage: "plus")
            }
            .accessibilityIdentifier("addHostButton")
        }
    }

    /// 主机行：名称 + 地址 + 延迟右对齐（参照 macOS 侧栏主机行；延迟分档着色阈值 80/500ms）。
    /// 地址用 verbatim：Text 插值 Int 会按 locale 加千分位（"2,222"），端口必须原样显示。
    private func row(_ host: IOSHost) -> some View {
        let address = "\(host.ssh.user)@\(host.ssh.host):\(host.ssh.port)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.name).foregroundStyle(IOSTheme.text)
                Spacer(minLength: 0)
                if let probed = latencyStore.latency[host.id], let ms = probed {
                    Text("\(ms) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(IOSTheme.latencyColor(ms: ms))
                        .fixedSize()
                }
            }
            Text(verbatim: address)
                .font(.caption).foregroundStyle(IOSTheme.subtext)
        }
        .accessibilityIdentifier("hostRow.\(host.id)")
    }
}

#Preview {
    IOSHostsView(
        repository: IOSHostRepository(inMemory: true),
        keyStore: IOSKeyStore(inMemory: true))
}
