import SwiftUI

/// 密钥库：生成 ed25519/RSA、查看公钥/指纹、粘贴导入 PEM；私钥只存设备钥匙串。
struct IOSKeysView: View {
    @ObservedObject var keyStore: IOSKeyStore
    @State private var generating = false
    @State private var importing = false

    var body: some View {
        Form {
            if keyStore.keys.isEmpty {
                Section {
                    Text(String(localized: "还没有密钥。生成新密钥，或粘贴已有私钥导入。"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(keyStore.keys) { key in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(key.name)
                                Spacer()
                                Text(key.type.label)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(key.fingerprint)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Button(String(localized: "复制公钥")) {
                                    UIPasteboard.general.string = key.publicKey
                                }
                                .font(.caption)
                                Button(String(localized: "删除"), role: .destructive) {
                                    keyStore.remove(key)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "密钥"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(String(localized: "生成 ed25519 密钥")) { generating = true }
                    Button(String(localized: "粘贴私钥导入")) { importing = true }
                } label: {
                    Label(String(localized: "添加密钥"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $generating) {
            IOSKeyGenerateSheet(keyStore: keyStore)
        }
        .sheet(isPresented: $importing) {
            IOSKeyImportSheet(keyStore: keyStore)
        }
        .alert(
            String(localized: "密钥操作失败"),
            isPresented: Binding(
                get: { keyStore.errorMessage != nil },
                set: { if !$0 { keyStore.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好"), role: .cancel) { keyStore.errorMessage = nil }
        } message: {
            Text(keyStore.errorMessage ?? "")
        }
    }
}

/// 生成密钥：名称 + 类型 + 可选口令；私钥不进任何界面与磁盘。
private struct IOSKeyGenerateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var keyStore: IOSKeyStore
    @State private var name = ""
    @State private var type = IOSKey.KeyType.ed25519
    @State private var passphrase = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名称"), text: $name)
                    Picker(String(localized: "类型"), selection: $type) {
                        Text("ed25519").tag(IOSKey.KeyType.ed25519)
                        Text("RSA 4096").tag(IOSKey.KeyType.rsa)
                    }
                    SecureField(String(localized: "私钥口令（可选）"), text: $passphrase)
                }
            }
            .navigationTitle(String(localized: "生成密钥"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "生成")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if keyStore.generate(name: trimmed, type: type, passphrase: passphrase) != nil {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 粘贴导入：支持未加密的 PEM / OpenSSH 私钥文本。
private struct IOSKeyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var keyStore: IOSKeyStore
    @State private var name = ""
    @State private var pem = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "名称"), text: $name)
                }
                Section(String(localized: "私钥内容")) {
                    TextEditor(text: $pem)
                        .font(.caption.monospaced())
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(String(localized: "导入密钥"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "导入")) {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if keyStore.importKey(name: trimmed, pem: pem) != nil {
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || pem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
