import SwiftUI
import TermoCore

/// 主机详情：连接资料摘要 + 实时监控（页面可见期间运行）+ 「连接终端」入口。
/// 列表选择变化时由 `.id(host.id)` 整体重建，监控随之换绑。
struct IOSHostDetailView: View {
    let host: IOSHost
    @ObservedObject var repository: IOSHostRepository
    @ObservedObject var keyStore: IOSKeyStore
    @StateObject private var monitor: IOSHostMonitor
    @State private var editing = false

    init(host: IOSHost, repository: IOSHostRepository, keyStore: IOSKeyStore) {
        self.host = host
        self.repository = repository
        self.keyStore = keyStore
        _monitor = StateObject(wrappedValue: IOSHostMonitor(connection: host.ssh))
    }

    var body: some View {
        Form {
            Section(String(localized: "连接资料")) {
                LabeledContent(String(localized: "地址"), value: "\(host.ssh.host):\(host.ssh.port)")
                LabeledContent(String(localized: "用户名"), value: host.ssh.user)
                LabeledContent(String(localized: "认证方式"), value: host.ssh.authMethod.label)
                if host.ssh.authMethod == .key, let key = keyStore.keys.first(where: { $0.id == host.ssh.keyId }) {
                    LabeledContent(String(localized: "密钥"), value: key.name)
                }
            }
            IOSHostMonitorSection(monitor: monitor, host: host)
            Section {
                NavigationLink {
                    IOSTerminalPage(host: host)
                } label: {
                    Label(String(localized: "连接终端"), systemImage: "terminal")
                }
                .accessibilityIdentifier("connectTerminalButton")
            }
        }
        .navigationTitle(host.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "编辑")) { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            IOSHostEditor(
                host: host, keyStore: keyStore,
                errorMessage: $repository.errorMessage, onSave: repository.save)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
