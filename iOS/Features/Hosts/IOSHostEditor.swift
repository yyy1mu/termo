import SwiftUI
import TermoCore

struct IOSHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hostname: String
    @State private var username: String
    @State private var port: String
    @Binding var errorMessage: String?

    let profile: HostProfile?
    let onSave: (HostProfile) -> Bool

    init(profile: HostProfile?, errorMessage: Binding<String?>, onSave: @escaping (HostProfile) -> Bool) {
        self.profile = profile
        self.onSave = onSave
        _errorMessage = errorMessage
        _name = State(initialValue: profile?.name ?? "")
        _hostname = State(initialValue: profile?.hostname ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _port = State(initialValue: String(profile?.port ?? 22))
    }

    private var validPort: Int? {
        guard let number = Int(port), (1...65535).contains(number) else { return nil }
        return number
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("连接资料") {
                    TextField("名称", text: $name)
                    TextField("主机地址", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port).keyboardType(.numberPad)
                }
                Section {
                    Text("这里不保存密码或私钥。连接功能接入后由设备钥匙串管理凭证。")
                }
            }
            .navigationTitle(profile == nil ? "添加主机" : "编辑主机")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let validPort else { return }
                        let saved = onSave(
                            HostProfile(
                                id: profile?.id ?? UUID().uuidString,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                hostname: hostname.trimmingCharacters(in: .whitespacesAndNewlines),
                                port: validPort,
                                username: username.trimmingCharacters(in: .whitespacesAndNewlines)))
                        if saved { dismiss() }
                    }
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || validPort == nil)
                }
            }
            .alert(
                "无法保存主机",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
