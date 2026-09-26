import AppKit
import SwiftUI
import TermoCore

struct AddHostView: View {
    @ObservedObject var model: AppModel
    var editing: Host? = nil
    @StateObject private var draft = HostDraft()
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var section: HostFormSection = .basic
    @State private var showTest = false
    @State private var didLoad = false
    @State private var saveError: String?

    private var isEditing: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            HStack(spacing: 0) {
                navSidebar
                Divider().overlay(Pal.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { sectionContent }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().overlay(Pal.fill(0.06))
            footer
        }
        .frame(minWidth: 680, idealWidth: 780, maxWidth: 920, minHeight: 480, idealHeight: 640, maxHeight: 800)
        .background(Pal.solidBase)
        .background(NoInitialFocus())   // 打开时不默认把光标聚焦到「名称」
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            if let editing {
                draft.load(from: editing, passwordIsTemporary: model.isHostPasswordTemporary(editing.id))
            }
        }
        .sheet(isPresented: $showTest) {
            TestConnectionView(draft: draft)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            Image(systemName: "server.rack")
                .font(.system(size: 20)).foregroundStyle(Pal.mauve)
                .frame(width: 42, height: 42)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(isEditing ? String(localized: "编辑主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "新增主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Pal.text)
                Text(draft.resolvedAddress.isEmpty ? String(localized: "填写连接信息，建立你的远程工作区", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : draft.targetLabel)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭主机表单")
            .help("关闭主机表单")
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - 左侧导航

    private var navSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    navigationGroup("主机设置", sections: [.basic, .initial])
                    navigationGroup("连接选项", sections: [.connection, .proxy, .advanced])
                }
                .padding(.horizontal, 10).padding(.vertical, 18)
            }
            Text("仅应用于这台主机，保存后生效。")
                .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
        }
        .frame(width: 184)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    private func navigationGroup(_ title: LocalizedStringKey, sections: [HostFormSection]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                .padding(.horizontal, 10).padding(.bottom, 3)
            ForEach(sections, id: \.self) { item in
                let selected = section == item
                Button { section = item } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13)).frame(width: 18).padding(.top, 2)
                            .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label).font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected ? Pal.textBright : Pal.text)
                            Text(item.summary).font(.system(size: 10)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(10)
                    .background(selected ? Pal.mauve.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = saveError ?? draft.validationMessage {
                ScrollView {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: saveError == nil ? "info.circle" : "exclamationmark.circle")
                        Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11)).foregroundStyle(saveError == nil ? Pal.subtext : Pal.red)
                }
                .frame(height: saveError == nil ? 30 : 52)
            }
            HStack(spacing: 10) {
                Button {
                    guard draft.testUnavailableReason == nil else { return }
                    showTest = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: 13))
                        Text("测试连接").font(.system(size: 13))
                    }
                    .foregroundStyle(Pal.mauve)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.mauve.opacity(0.25), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor(draft.testUnavailableReason == nil)
                .disabled(draft.testUnavailableReason != nil)
                .opacity(draft.testUnavailableReason == nil ? 1 : 0.5)
                .help(draft.testUnavailableReason ?? String(localized: "测试当前填写的连接，不保存主机资料", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))

                Spacer()
                SecondaryButton(title: "取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: isEditing ? "保存主机" : "添加主机", enabled: draft.canSave) { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() {
        guard draft.canSave else { saveError = draft.validationMessage; return }
        let saved: Bool
        if let editing {
            saved = model.updateHost(id: editing.id, from: draft)
        } else {
            saved = model.addHost(from: draft)
        }
        if saved { dismiss() } else { saveError = model.hostSaveError ?? String(localized: "保存失败，请重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = AppEnv.isMAS
        panel.showsHiddenFiles = true   // ~/.ssh 为隐藏目录，需显示隐藏文件才能选到密钥
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = AppEnv.isMAS
            ? String(localized: "选择私钥；加密私钥可按住 ⌘ 同时选择同名 .pub 公钥", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            : String(localized: "选择一份私钥文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        panel.prompt = String(localized: "选择", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        if panel.runModal() == .OK {
            let files: (privateKey: URL, publicKey: URL?)
            do { files = try KeyTools.selectedImportFiles(panel.urls) }
            catch { saveError = error.localizedDescription; return }
            if AppEnv.isMAS {
                // 沙盒下不能长期持有容器外路径 → 选中即导入密钥库，改用 keyId。
                if let key = model.importKey(from: files.privateKey, publicKeyURL: files.publicKey) {
                    draft.keyId = key.id
                    draft.keyPath = ""
                }
                else { saveError = model.keyOpError ?? String(localized: "无法导入私钥，请检查文件内容。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            } else {
                draft.keyPath = files.privateKey.path
            }
        }
    }

    /// 「密钥来源」下拉选项：手动文件 + 密钥库中的每把密钥。
    private var keySourceOptions: [(value: String, label: String)] {
        [(value: "", label: String(localized: "手动指定文件…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))]
            + model.sshKeys.map { (value: $0.id, label: "\($0.name)（\($0.type.label)）") }
    }

    // MARK: - 各分区内容

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .basic: basicSection
        case .connection: connectionSection
        case .initial: initialSection
        case .proxy: proxySection
        case .advanced: advancedSection
        }
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "基本信息", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            Text("名称用于识别主机；地址、端口和登录用户决定连接目标。")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            field(String(localized: "名称 · 必填", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "我的服务器", text: $draft.name)
            HStack(spacing: 12) {
                field(String(localized: "地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "192.168.1.1 或 example.com", text: $draft.address)
                field(String(localized: "端口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "22", text: $draft.port).frame(width: 90)
            }
            field(String(localized: "登录用户", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "root", text: $draft.user)
            Divider().overlay(Pal.border).padding(.vertical, 2)
            labeled(String(localized: "登录方式", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedDropdown(
                    options: AuthMethod.allCases.map { (value: $0, verbatim: $0.appLocalizedLabel) },
                    selection: $draft.authMethod
                )
                .frame(width: 200)
            }
            if draft.authMethod == .key {
                labeled(String(localized: "密钥来源", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                    ThemedDropdown(options: keySourceOptions.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.keyId)
                }
                if draft.keyId.isEmpty {
                    labeled(String(localized: "私钥文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                        if AppEnv.isMAS {
                            // 沙盒下不接受手填路径（容器外读不到）：选文件即导入密钥库。
                            SecondaryButton(title: "选择文件并导入密钥库…") { chooseKeyFile() }
                        } else {
                            HStack(spacing: 8) {
                                ThemedTextField(placeholder: "~/.ssh/id_ed25519", text: $draft.keyPath)
                                SecondaryButton(title: "选择…") { chooseKeyFile() }
                            }
                        }
                    }
                }
                labeled(String(localized: "私钥密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), optional: true) {
                    ThemedSecureField(placeholder: "（私钥有 passphrase 时填写）", text: $draft.password)
                }
            } else if draft.authMethod == .password {
                labeled(String(localized: "登录密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), optional: true) {
                    ThemedSecureField(placeholder: "留空则连接时询问", text: $draft.password)
                    Text("填写后保存到系统钥匙串，并随加密备份同步。")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    if isEditing, !draft.password.isEmpty, !draft.passwordWasEdited {
                        Label("已保存登录密码", systemImage: "checkmark.shield")
                            .font(.system(size: 11)).foregroundStyle(Pal.green)
                    }
                }
            } else {
                // 每次询问：不保存任何凭证，连接时弹窗输入本次密码。
                Text("仅在当前会话中使用输入的密码，不保存、不纳入同步；连接时可以选择保存。")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Pal.border).padding(.vertical, 2)
            groupSelector
            labeled(String(localized: "主机备注", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), optional: true) {
                ThemedTextEditor(placeholder: "备注信息…", text: $draft.notes)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "连接设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            Text("连接超时覆盖 DNS、代理、TCP、握手和认证；心跳为 0 时关闭。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            field(String(localized: "连接超时 (ms)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "10000", text: $draft.timeout)
            field(String(localized: "心跳间隔 (ms)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "5000", text: $draft.heartbeat)
        }
    }

    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "终端设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            toggleRow(String(localized: "启用主机监控", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), isOn: $draft.monitoringEnabled)
            Text("仅控制这台主机。默认开启；关闭后停止采集，不影响终端、文件和转发。此选项随主机配置同步。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            field(String(localized: "默认路径", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), placeholder: "~", text: $draft.defaultPath)
            labeled(String(localized: "初始执行", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedTextEditor(placeholder: "#!/bin/bash", text: $draft.initialCommand)
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "代理设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            toggleRow(String(localized: "使用代理", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), isOn: $draft.proxyEnabled)
            labeled(String(localized: "代理设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedTextField(placeholder: "socks5://127.0.0.1:10808", text: $draft.proxyURL)
            }
            .disabled(!draft.proxyEnabled)
            .opacity(draft.proxyEnabled ? 1 : 0.55)
            Text("支持 SOCKS5（代理端解析域名）和 HTTP CONNECT。当前不在主机配置中保存代理密码。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "高级设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            Text("留空时按安全默认顺序自动协商；指定算法后，仅允许该算法。编码只影响交互终端。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            labeled(String(localized: "终端显示编码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedDropdown(options: SSHOptions.encodings.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.encoding)
                    .frame(maxWidth: .infinity)
            }
            labeled(String(localized: "主机密钥算法", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedDropdown(options: SSHOptions.hostKeyAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.hostKeyAlgos)
                    .frame(maxWidth: .infinity)
            }
            labeled(String(localized: "Cipher 算法", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedDropdown(options: SSHOptions.ciphers.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.ciphers)
                    .frame(maxWidth: .infinity)
            }
            labeled(String(localized: "密钥交换算法", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                ThemedDropdown(options: SSHOptions.kexAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.kexAlgos)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 组件

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Pal.text)
            .padding(.bottom, 2)
    }

    private func field(_ label: String, placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        labeled(label) { ThemedTextField(placeholder: placeholder, text: text).accessibilityLabel(label) }
    }

    private func labeled<C: View>(_ label: String, optional: Bool = false, hint: String? = nil, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                if optional {
                    Text("可选").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
            }
            control()
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            ThemedToggle(isOn: isOn)
        }
    }

    private var groupSelector: some View {
        labeled(String(localized: "服务器分组", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
            SearchableSelect(options: model.groupNames, text: $draft.group, placeholder: String(localized: "搜索或新建分组…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
    }
}
