import AppKit
import SwiftUI

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
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if geometry.size.width >= 640 {
                        navSidebar
                        Divider().overlay(Pal.border)
                    }
                    VStack(spacing: 0) {
                        if geometry.size.width < 640 {
                            ThemedDropdown(options: HostFormSection.allCases.map { (value: $0, verbatim: $0.label) }, selection: $section)
                                .accessibilityLabel("主机设置分区")
                                .padding(16)
                            Divider().overlay(Pal.border)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) { sectionContent }
                                .padding(22)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(section)
                    }
                }
            }
            Divider().overlay(Pal.fill(0.06))
            footer
        }
        .frame(minWidth: 420, idealWidth: 740, maxWidth: 860, minHeight: 420, idealHeight: 640, maxHeight: 760)
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
                Text(isEditing ? "编辑主机" : "新增主机")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Pal.text)
                Text(draft.resolvedAddress.isEmpty ? String(localized: "填写连接信息，建立你的远程工作区") : draft.targetLabel)
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
        VStack(spacing: 2) {
            ForEach(HostFormSection.allCases, id: \.self) { s in
                let selected = section == s
                Button {
                    section = s
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: s.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                            .frame(width: 18)
                        Text(s.label)
                            .font(.system(size: 13))
                            .foregroundStyle(selected ? Pal.text : Pal.subtext)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(
                        selected ? Pal.mauve.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
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
                .help(draft.testUnavailableReason ?? String(localized: "测试当前填写的连接，不保存主机资料"))

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
        if saved { dismiss() } else { saveError = model.hostSaveError ?? String(localized: "保存失败，请重试。") }
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = AppEnv.isMAS
        panel.showsHiddenFiles = true   // ~/.ssh 为隐藏目录，需显示隐藏文件才能选到密钥
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.message = AppEnv.isMAS
            ? String(localized: "选择私钥；加密私钥可按住 ⌘ 同时选择同名 .pub 公钥")
            : String(localized: "选择一份私钥文件")
        panel.prompt = String(localized: "选择")
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
                else { saveError = model.keyOpError ?? String(localized: "无法导入私钥，请检查文件内容。") }
            } else {
                draft.keyPath = files.privateKey.path
            }
        }
    }

    /// 「密钥来源」下拉选项：手动文件 + 密钥库中的每把密钥。
    private var keySourceOptions: [(value: String, label: String)] {
        [(value: "", label: String(localized: "手动指定文件…"))]
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
            sectionTitle(String(localized: "基本信息"))
            Text("名称用于识别主机；地址、端口和登录用户决定连接目标。")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            field(String(localized: "名称 · 必填"), placeholder: "我的服务器", text: $draft.name)
            HStack(spacing: 12) {
                field(String(localized: "地址"), placeholder: "192.168.1.1 或 example.com", text: $draft.address)
                field(String(localized: "端口"), placeholder: "22", text: $draft.port).frame(width: 90)
            }
            field(String(localized: "登录用户"), placeholder: "root", text: $draft.user)
            Divider().overlay(Pal.border).padding(.vertical, 2)
            labeled(String(localized: "登录方式")) {
                ThemedDropdown(
                    options: AuthMethod.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $draft.authMethod
                )
                .frame(width: 200)
            }
            if draft.authMethod == .key {
                labeled(String(localized: "密钥来源")) {
                    ThemedDropdown(options: keySourceOptions.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.keyId)
                }
                if draft.keyId.isEmpty {
                    labeled(String(localized: "私钥文件")) {
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
                labeled(String(localized: "私钥密码"), optional: true) {
                    ThemedSecureField(placeholder: "（私钥有 passphrase 时填写）", text: $draft.password)
                }
            } else if draft.authMethod == .password {
                labeled(String(localized: "登录密码"), optional: true) {
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
            labeled(String(localized: "主机备注"), optional: true) {
                ThemedTextEditor(placeholder: "备注信息…", text: $draft.notes)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "连接设置"))
            unavailableOptionsNote("连接超时和心跳目前由应用自动管理。以下旧配置尚未接入当前连接，暂不可修改。")
            field(String(localized: "超时时间 (ms)"), placeholder: "10000", text: $draft.timeout).disabled(true)
            field(String(localized: "心跳时间 (ms)"), placeholder: "5000", text: $draft.heartbeat).disabled(true)
        }
    }

    private var initialSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "初始选项"))
            field(String(localized: "默认路径"), placeholder: "~", text: $draft.defaultPath)
            labeled(String(localized: "初始执行")) {
                ThemedTextEditor(placeholder: "#!/bin/bash", text: $draft.initialCommand)
            }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "代理设置"))
            unavailableOptionsNote("当前连接暂不支持代理。以下旧配置仅保留展示，不会生效；连接将直接访问服务器。")
            toggleRow(String(localized: "禁用代理"), isOn: $draft.disableProxy).disabled(true)
            labeled(String(localized: "代理设置")) {
                ThemedTextField(placeholder: "socks5://127.0.0.1:10808", text: $draft.proxyURL)
            }
            .disabled(true)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle(String(localized: "高级设置"))
            unavailableOptionsNote("当前连接自动协商加密算法，终端使用 UTF-8。以下旧配置尚未接入，暂不可修改。")
            labeled(String(localized: "终端显示编码")) {
                ThemedDropdown(options: SSHOptions.encodings.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.encoding)
                    .frame(maxWidth: .infinity).disabled(true)
            }
            labeled(String(localized: "主机密钥算法")) {
                ThemedDropdown(options: SSHOptions.hostKeyAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.hostKeyAlgos)
                    .frame(maxWidth: .infinity).disabled(true)
            }
            labeled(String(localized: "Cipher 算法")) {
                ThemedDropdown(options: SSHOptions.ciphers.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.ciphers)
                    .frame(maxWidth: .infinity).disabled(true)
            }
            labeled(String(localized: "密钥交换算法")) {
                ThemedDropdown(options: SSHOptions.kexAlgos.map { (value: $0.value, verbatim: $0.label) }, selection: $draft.kexAlgos)
                    .frame(maxWidth: .infinity).disabled(true)
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

    private func unavailableOptionsNote(_ message: LocalizedStringKey) -> some View {
        Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: "info.circle")
        }
        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var groupSelector: some View {
        labeled(String(localized: "服务器分组")) {
            SearchableSelect(options: model.groupNames, text: $draft.group, placeholder: String(localized: "搜索或新建分组…"))
        }
    }
}
