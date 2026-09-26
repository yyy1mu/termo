import SwiftUI

private func keySheetString(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
}

/// 生成新密钥；失败保留表单，成功才关闭。
struct GenerateKeyView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var type: SSHKeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var generationError: String?
    @State private var isGenerating = false
    @State private var generationTask: Task<Void, Never>?

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            KeySheetHeader(title: keySheetString("生成 SSH 密钥"), subtitle: keySheetString("创建一对用于服务器登录的公钥和私钥"), symbol: "key.fill")
            Divider().overlay(Pal.border)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        KeyFormField(title: keySheetString("密钥名称"), hint: keySheetString("必填 · 用于在 Termo 中识别这把密钥")) {
                            ThemedTextField(verbatim: keySheetString("例如：工作服务器"), text: $name, autofocus: true)
                                .accessibilityLabel(keySheetString("密钥名称，必填"))
                        }
                        KeyFormField(title: keySheetString("密钥类型"), hint: keySheetString("Ed25519 适用于多数服务器；旧服务器可选 RSA 4096。")) {
                            ThemedDropdown(options: SSHKeyType.allCases.map { (value: $0, verbatim: $0.label) }, selection: $type)
                                .accessibilityLabel(keySheetString("密钥类型"))
                        }
                        KeyFormField(title: keySheetString("公钥注释"), hint: keySheetString("可选 · 会写入公钥尾部，可填写邮箱或设备名称")) {
                            ThemedTextField(verbatim: keySheetString("例如：work@macbook"), text: $comment)
                                .accessibilityLabel(keySheetString("公钥注释，可选"))
                        }
                        KeyFormField(title: keySheetString("私钥口令"), hint: keySheetString("可选 · 用于加密这把私钥，与应用锁定密码无关。请妥善保管。")) {
                            ThemedSecureField(verbatim: keySheetString("留空则不设置口令"), text: $passphrase)
                                .accessibilityLabel(keySheetString("私钥口令，可选"))
                        }
                        KeySheetNote(symbol: "lock.shield", text: keySheetString("私钥保存在系统钥匙串中。生成后可复制公钥，或部署到服务器。"))
                        if let generationError {
                            KeySheetNotice(success: false, title: keySheetString("未能生成密钥"), detail: generationError)
                                .id("generation-error")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isGenerating)
                .onChange(of: generationError) {
                    if generationError != nil { proxy.scrollTo("generation-error", anchor: .top) }
                }
            }
            KeySheetFooter {
                if isGenerating {
                    ProgressView().controlSize(.small)
                    Text(verbatim: keySheetString("正在生成密钥…"))
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer()
                Button(keySheetString("取消")) {
                    generationTask?.cancel()
                    dismiss()
                }
                    .buttonStyle(KeySheetButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(keySheetString("生成密钥"), action: generate)
                    .buttonStyle(KeySheetButtonStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedName.isEmpty || isGenerating)
                    .help(keySheetString("生成密钥（⌘↩）"))
            }
        }
        .frame(minWidth: 340, idealWidth: 480, maxWidth: 560, minHeight: 360, idealHeight: 580, maxHeight: 680)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onDisappear { generationTask?.cancel() }
        .environment(\.locale, settings.effectiveLocale)
    }

    private func generate() {
        guard !trimmedName.isEmpty, !isGenerating else { return }
        let name = trimmedName
        let chosenType = type
        let chosenComment = comment
        let chosenPassphrase = passphrase
        generationError = nil
        isGenerating = true
        generationTask = Task {
            let saved = await model.generateKey(
                name: name, type: chosenType, comment: chosenComment, passphrase: chosenPassphrase)
            guard !Task.isCancelled else { return }
            isGenerating = false
            generationTask = nil
            if saved {
                dismiss()
            } else {
                generationError = model.keyOpError ?? String(localized: "未能保存密钥，请重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                model.keyOpError = nil
            }
        }
    }
}

/// 仅展示密钥元数据与公钥，私钥内容不进入详情界面。
struct KeyDetailView: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showDeploy = false
    @State private var confirmDelete = false
    @State private var deletionError: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            KeySheetHeader(title: keySheetString("密钥详情"), subtitle: keySheetString("核对身份信息，复制或部署公钥"), symbol: "key.fill")
            Divider().overlay(Pal.border)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(key.name)
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.textBright)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 14) {
                            info(keySheetString("密钥类型"), key.type.label)
                            info(keySheetString("私钥口令"), key.hasPassphrase ? String(localized: "已设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "未设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                            info(
                                keySheetString("创建时间"),
                                key.createdAt.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .shortened)
                                        .locale(settings.effectiveLocale)))
                            if !key.comment.isEmpty { info(keySheetString("公钥注释"), key.comment) }
                        }
                        KeyFormField(title: keySheetString("指纹"), hint: keySheetString("用于核对密钥身份")) {
                            Text(key.fingerprint.isEmpty ? String(localized: "暂无指纹", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : key.fingerprint)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(verbatim: keySheetString("公钥")).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
                                Spacer()
                                Button(action: copyPublicKey) {
                                    Label(copied ? String(localized: "已复制", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "复制公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                                          systemImage: copied ? "checkmark" : "doc.on.doc")
                                }
                                .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Pal.mauve)
                                .pointerCursor().disabled(key.publicKey.isEmpty)
                                .accessibilityLabel(copied ? String(localized: "公钥已复制", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "复制完整公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                            }
                            Text(key.publicKey.isEmpty ? String(localized: "暂无可用公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : key.publicKey)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                            Text(verbatim: keySheetString("将完整公钥添加到服务器的 ~/.ssh/authorized_keys，即可授权对应私钥登录。"))
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let deletionError {
                            KeySheetNotice(success: false, title: keySheetString("未能删除密钥"), detail: deletionError)
                                .id("deletion-error")
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: deletionError) {
                    if deletionError != nil { proxy.scrollTo("deletion-error", anchor: .top) }
                }
            }
            KeySheetFooter {
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash").frame(width: 20)
                }
                .buttonStyle(KeySheetButtonStyle(destructive: true))
                .help(keySheetString("删除密钥…")).accessibilityLabel(keySheetString("删除密钥，需要确认"))
                Spacer(minLength: 4)
                Button(keySheetString("关闭")) { dismiss() }
                    .buttonStyle(KeySheetButtonStyle()).keyboardShortcut(.cancelAction)
                Button(keySheetString("部署公钥…")) { showDeploy = true }
                    .buttonStyle(KeySheetButtonStyle(primary: true))
                    .disabled(key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(minWidth: 340, idealWidth: 500, maxWidth: 620, minHeight: 360, idealHeight: 580, maxHeight: 700)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .sheet(isPresented: $showDeploy) { KeyDeploySheet(model: model, key: key) }
        .alert(keySheetString("删除这把密钥？"), isPresented: $confirmDelete) {
            Button(keySheetString("取消"), role: .cancel) { }
            Button(keySheetString("删除密钥"), role: .destructive) {
                if model.deleteKey(key) { dismiss() }
                else {
                    deletionError = model.keyOpError ?? String(localized: "密钥未能删除，请重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    model.keyOpError = nil
                }
            }
        } message: {
            Text(verbatim: String(localized: "将从此设备的密钥库删除“\(key.name)”及其私钥。使用它的主机需要重新选择登录凭据，服务器上的公钥不会被移除。此操作无法撤销。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        .onDisappear { copyResetTask?.cancel() }
        .environment(\.locale, settings.effectiveLocale)
    }

    private func copyPublicKey() {
        model.copyPublicKey(key)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(Pal.subtext).frame(width: 64, alignment: .leading)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 使用目标主机已保存的凭据部署公钥；执行期间固定目标与选项。
struct KeyDeploySheet: View {
    @ObservedObject var model: AppModel
    let key: SSHKey
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var hostId = ""
    @State private var setAsLoginKey = true
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?

    private var eligibleHosts: [Host] { model.hosts.filter { $0.ssh != nil } }
    private var selectedHost: Host? { eligibleHosts.first { $0.id == hostId } }
    private var canDeploy: Bool {
        !busy && selectedHost != nil && !key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result?.ok != true
    }

    var body: some View {
        VStack(spacing: 0) {
            KeySheetHeader(title: keySheetString("部署公钥"), subtitle: keySheetString("将公钥添加到所选主机，授权密钥登录"), symbol: "arrow.up.to.line")
            Divider().overlay(Pal.border)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(key.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                            Text(key.type.label).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            Text(key.fingerprint.isEmpty ? String(localized: "暂无指纹", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : key.fingerprint)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                                .textSelection(.enabled)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))

                        KeyFormField(title: keySheetString("目标主机"), hint: keySheetString("必选 · 使用该主机已保存的 SSH 登录凭据连接")) {
                            if eligibleHosts.isEmpty {
                                KeySheetNote(symbol: "server.rack", text: keySheetString("暂无可用的 SSH 主机，请先添加并配置主机连接。"))
                            } else {
                                ThemedDropdown(options: [(value: "", verbatim: String(localized: "选择目标主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))] + eligibleHosts.map {
                                    (value: $0.id, verbatim: "\($0.name) · \($0.ipOrHost)")
                                }, selection: $hostId)
                                .disabled(busy).accessibilityLabel(keySheetString("部署目标主机"))
                                if let host = selectedHost, let ssh = host.ssh {
                                    Text("\(host.name)\n\(ssh.user)@\(host.ipOrHost):\(ssh.port)")
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }

                        Toggle(isOn: $setAsLoginKey) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: keySheetString("设为该主机的登录密钥")).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                                Text(verbatim: keySheetString("仅在部署成功后更新主机配置，下一次连接生效。"))
                                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox).tint(Pal.mauve).disabled(busy || eligibleHosts.isEmpty)
                        if setAsLoginKey && key.hasPassphrase {
                            KeySheetNote(symbol: "lock", text: keySheetString("这把私钥设有口令。部署后请在主机的连接设置中填写私钥口令，再连接验证。"))
                        }
                        KeySheetNote(symbol: "info.circle", text: keySheetString("仅添加公钥，不上传私钥。服务器现有的授权公钥会保留；部署后仍需实际连接验证登录。"))
                        if let result {
                            KeySheetNotice(success: result.ok, title: result.ok ? keySheetString("公钥已部署") : keySheetString("部署未完成"), detail: result.text)
                                .id("deploy-result")
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: result?.text) {
                    if result != nil { proxy.scrollTo("deploy-result", anchor: .top) }
                }
            }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: keySheetString("正在连接并部署，请等待结果…")).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
            KeySheetFooter {
                Spacer()
                Button(result?.ok == true ? String(localized: "完成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "关闭", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { dismiss() }
                    .buttonStyle(KeySheetButtonStyle())
                    .keyboardShortcut(.cancelAction).disabled(busy)
                    .help(busy ? String(localized: "部署完成后可关闭", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "关闭部署窗口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                Button(result?.ok == true ? String(localized: "已部署", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                       : result == nil ? String(localized: "部署公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "重试部署", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: deploy)
                    .buttonStyle(KeySheetButtonStyle(primary: true)).disabled(!canDeploy)
            }
        }
        .frame(minWidth: 340, idealWidth: 480, maxWidth: 600, minHeight: 360, idealHeight: 570, maxHeight: 700)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .interactiveDismissDisabled(busy)
        .onAppear {
            if let currentHostId = model.workspaceContext.hostId, eligibleHosts.contains(where: { $0.id == currentHostId }) {
                hostId = currentHostId
            }
        }
        .onChange(of: hostId) { if !busy { result = nil } }
        .onChange(of: setAsLoginKey) { if !busy { result = nil } }
        .environment(\.locale, settings.effectiveLocale)
    }

    /// 建目录与权限成功后才执行去重追加；公钥内容作为单引号参数。
    private var deployCommand: String {
        let pk = key.publicKey.replacingOccurrences(of: "'", with: "'\\''")
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && " +
            "chmod 600 ~/.ssh/authorized_keys && (grep -qxF '\(pk)' ~/.ssh/authorized_keys 2>/dev/null " +
            "|| printf '%s\\n' '\(pk)' >> ~/.ssh/authorized_keys)"
    }

    private func deploy() {
        guard canDeploy, let host = selectedHost, let ssh = host.ssh else { return }
        busy = true
        result = nil
        let cmd = deployCommand
        let setKey = setAsLoginKey
        Task {
            let response = await RemoteFS(ssh).run(cmd, timeout: 30)
            await MainActor.run {
                busy = false
                if response.code == 0 {
                    if setKey && !model.associateKey(key.id, hostId: host.id) {
                        let error = model.keyOpError ?? String(localized: "登录密钥配置未能保存。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        model.keyOpError = nil
                        result = (false, String(localized: "公钥已添加到 \(host.name)，但本机登录配置未保存：\(error)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        return
                    }
                    let detail = setKey
                        ? String(localized: "已添加到 \(host.name) 的 authorized_keys，并设为该主机的登录密钥。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        : String(localized: "已添加到 \(host.name) 的 authorized_keys，登录配置未更改。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    result = (true, detail + (setKey && key.hasPassphrase ? String(localized: "\n请在该主机的连接设置中填写私钥口令后再连接。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : ""))
                } else {
                    let err = String(decoding: response.stderr, as: UTF8.self)
                    let out = String(decoding: response.data, as: UTF8.self)
                    let detail = (err.isEmpty ? out : err).trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(
                        localized: "服务器未返回错误说明，请检查连接凭据和远端权限。",
                        bundle: AppSettings.localizationBundle,
                        locale: AppSettings.activeLocale
                    )
                    result = (false, String(
                        localized: "目标：\(host.name)\n退出状态：\(response.code)\n\(detail.isEmpty ? fallback : detail)",
                        bundle: AppSettings.localizationBundle,
                        locale: AppSettings.activeLocale
                    ))
                }
            }
        }
    }
}

private struct KeySheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Pal.mauve)
                .frame(width: 38, height: 38)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text(verbatim: subtitle).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }
}

private struct KeyFormField<Content: View>: View {
    let title: String
    let hint: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            content
            Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeySheetNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Text(verbatim: text).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeySheetNotice: View {
    let success: Bool
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle")
            }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(success ? Pal.green : Pal.red)
            Text(detail).font(.system(size: 11)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((success ? Pal.green : Pal.red).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct KeySheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Pal.border)
            HStack(spacing: 8) { content }.padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
}

private struct KeySheetButtonStyle: ButtonStyle {
    var primary = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.white : destructive ? Pal.red : Pal.text)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(primary ? Pal.mauve : destructive ? Pal.red.opacity(0.08) : Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle()).pointerCursor(isEnabled)
    }
}
