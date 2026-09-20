import SwiftUI

/// 生成新密钥弹窗。
struct GenerateKeyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: SSHKeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("生成密钥").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("名称") { ThemedTextField(placeholder: "我的密钥", text: $name) }
                    labeled(String(localized: "类型")) {
                        ThemedDropdown(options: SSHKeyType.allCases.map { (value: $0, label: $0.label) },
                                       selection: $type)
                    }
                    labeled("注释") { ThemedTextField(placeholder: "user@host（可选，写入公钥尾部）", text: $comment) }
                    labeled(String(localized: "口令")) { ThemedSecureField(placeholder: "（可选，给私钥加密）", text: $passphrase) }
                    Text("私钥安全存入系统钥匙串，绝不落盘明文；公钥可随时复制到服务器 authorized_keys。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Button {
                    model.generateKey(name: name.trimmingCharacters(in: .whitespaces),
                                      type: type, comment: comment, passphrase: passphrase)
                    dismiss()
                } label: {
                    Text("生成").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 460, height: 420)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}

/// 密钥详情弹窗：查看类型/指纹/创建时间，复制公钥，删除。
struct KeyDetailView: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showDeploy = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill").font(.system(size: 14)).foregroundStyle(Pal.mauve)
                Text(key.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text).lineLimit(1)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    info(String(localized: "类型"), key.type.label)
                    info(String(localized: "指纹"), key.fingerprint.isEmpty ? "—" : key.fingerprint)
                    info(String(localized: "口令保护"), key.hasPassphrase ? String(localized: "已加密") : String(localized: "无"))
                    info(String(localized: "创建于"), Self.dateFormatter.string(from: key.createdAt))
                    if !key.comment.isEmpty { info(String(localized: "注释"), key.comment) }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("公钥").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            Spacer()
                            Button { showDeploy = true } label: {
                                Label("部署到服务器", systemImage: "arrow.up.to.line")
                                    .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            }
                            .buttonStyle(.plain).pointerCursor()
                            Button {
                                model.copyPublicKey(key); copied = true
                            } label: {
                                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                        Text(key.publicKey)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                Button {
                    model.deleteKey(key); dismiss()
                } label: {
                    Text("删除").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.red)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer()
                Button { dismiss() } label: {
                    Text("关闭").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 480, height: 440)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $showDeploy) { KeyDeploySheet(model: model, key: key) }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}


/// 公钥部署到指定服务器：用该主机已保存的凭据连接，把公钥幂等追加到 ~/.ssh/authorized_keys
/// （grep -qxF 去重，重复部署不产生多余行）；可选同时设为该主机的登录密钥（写 ssh.keyId）。
struct KeyDeploySheet: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @State private var hostId = ""
    @State private var setAsLoginKey = true
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.to.line").font(.system(size: 13)).foregroundStyle(Pal.mauve)
                Text("部署公钥到服务器").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("公钥").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Text(key.publicKey)
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.text)
                    .lineLimit(2).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Pal.crust, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("目标主机（使用该主机已保存的凭据连接）").font(.system(size: 12)).foregroundStyle(Pal.text)
                if model.hosts.isEmpty {
                    Text("暂无主机，请先在主机列表添加").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                } else {
                    Picker("", selection: $hostId) {
                        ForEach(model.hosts) { h in
                            Text("\(h.name) · \(h.ipOrHost)").tag(h.id).font(.system(size: 12))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 260, alignment: .leading)
                }
            }

            HStack(spacing: 6) {
                ThemedToggle(isOn: $setAsLoginKey)
                Text("部署后设为该主机的登录密钥").font(.system(size: 12)).foregroundStyle(Pal.text)
            }

            if let r = result {
                Text(r.text)
                    .font(.system(size: 11)).foregroundStyle(r.ok ? Pal.green : Pal.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()

                Button(action: deploy) {
                    HStack(spacing: 5) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text(busy ? "部署中…" : "部署").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(busy || hostId.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.border, lineWidth: 1))
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear { hostId = model.hosts.first?.id ?? "" }
    }

    /// 幂等部署命令：建目录/权限 → 去重追加；公钥单引号包裹（防御性转义 '）
    private var deployCommand: String {
        let pk = key.publicKey.replacingOccurrences(of: "'", with: "'\\''")
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && " +
            "chmod 600 ~/.ssh/authorized_keys && grep -qxF '\(pk)' ~/.ssh/authorized_keys 2>/dev/null " +
            "|| printf '%s\\n' '\(pk)' >> ~/.ssh/authorized_keys"
    }

    private func deploy() {
        guard let host = model.hosts.first(where: { $0.id == hostId }) else { return }
        busy = true
        result = nil
        let ssh = host.ssh ?? SSHConnection()
        let cmd = deployCommand
        let setKey = setAsLoginKey
        Task {
            let r = await RemoteFS(ssh).run(cmd, timeout: 30)
            await MainActor.run {
                busy = false
                if r.code == 0 {
                    if setKey { model.associateKey(key.id, hostId: host.id) }
                    result = (true, String(localized: "已部署到 \(host.name)，该主机现可用此密钥登录"))
                } else {
                    let err = String(decoding: r.stderr, as: UTF8.self)
                    let out = String(decoding: r.data, as: UTF8.self)
                    result = (false, "失败（exit \(r.code)）：\(err.isEmpty ? out : err)")
                }
            }
        }
    }
}
