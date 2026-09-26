import SwiftUI
import TermoCore

/// 主机编辑器：完整 SSH 连接资料。密码/私钥由钥匙串管理；「每次询问」不保存任何凭证。
struct IOSHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hostname: String
    @State private var username: String
    @State private var port: String
    @State private var authMethod: AuthMethod
    @State private var password: String
    @State private var keyId: String
    @Binding var errorMessage: String?

    let host: IOSHost?
    let keyStore: IOSKeyStore
    let onSave: (IOSHost) -> Bool

    init(host: IOSHost?, keyStore: IOSKeyStore,
         errorMessage: Binding<String?>, onSave: @escaping (IOSHost) -> Bool) {
        self.host = host
        self.keyStore = keyStore
        self.onSave = onSave
        _errorMessage = errorMessage
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.ssh.host ?? "")
        _username = State(initialValue: host?.ssh.user ?? "root")
        _port = State(initialValue: String(host?.ssh.port ?? 22))
        _authMethod = State(initialValue: host?.ssh.authMethod ?? .password)
        _password = State(initialValue: host?.ssh.password ?? "")
        _keyId = State(initialValue: host?.ssh.keyId ?? "")
    }

    private var validPort: Int? {
        guard let number = Int(port), (1...65535).contains(number) else { return nil }
        return number
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validPort != nil else { return false }
        // 密钥认证必须已选密钥
        if authMethod == .key, keyId.isEmpty { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "连接资料")) {
                    TextField(String(localized: "名称"), text: $name)
                        .accessibilityIdentifier("hostEditor.name")
                    TextField(String(localized: "主机地址"), text: $hostname)
                        .accessibilityIdentifier("hostEditor.hostname")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField(String(localized: "用户名"), text: $username)
                        .accessibilityIdentifier("hostEditor.username")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(String(localized: "端口"), text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("hostEditor.port")
                }
                Section(String(localized: "认证")) {
                    Picker(String(localized: "认证方式"), selection: $authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    .accessibilityIdentifier("hostEditor.authMethod")
                    switch authMethod {
                    case .password:
                        SecureField(String(localized: "密码"), text: $password)
                            .accessibilityIdentifier("hostEditor.password")
                    case .key:
                        if keyStore.keys.isEmpty {
                            Text(String(localized: "还没有密钥。请先在「设置 → 密钥」中生成或导入。"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker(String(localized: "密钥"), selection: $keyId) {
                                Text(String(localized: "请选择")).tag("")
                                ForEach(keyStore.keys) { key in
                                    Text(key.name).tag(key.id)
                                }
                            }
                            .accessibilityIdentifier("hostEditor.key")
                        }
                        SecureField(String(localized: "私钥口令（如设置）"), text: $password)
                    case .ask:
                        Text(String(localized: "每次连接时输入密码，不保存任何凭证。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(host == nil
                ? String(localized: "添加主机")
                : String(localized: "编辑主机"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) {
                        var ssh = host?.ssh ?? SSHConnection()
                        ssh.user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        ssh.host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
                        ssh.port = validPort ?? 22
                        ssh.authMethod = authMethod
                        ssh.password = authMethod == .ask ? "" : password
                        ssh.keyId = authMethod == .key ? keyId : ""
                        let saved = onSave(IOSHost(
                            id: host?.id ?? UUID().uuidString,
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            ssh: ssh))
                        if saved { dismiss() }
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("hostEditor.save")
                }
            }
            .alert(
                String(localized: "无法保存主机"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(String(localized: "好"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
