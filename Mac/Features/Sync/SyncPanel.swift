import SwiftUI
import TermoCore

/// 设置中的全局同步与备份页面；连接配置与单向覆盖按需展开。
struct SyncPanel: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared
    @ObservedObject private var lock = AppLockManager.shared
    @State private var enteredMaster = ""
    @State private var masterError = ""
    @State private var verifyingMaster = false
    @State private var showMasterSetup = false
    @State private var showConfiguration = false
    @State private var showAdvanced = false
    @State private var confirmOverwrite = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    scopeSection
                    disclosure(
                        title: "WebDAV 连接", symbol: "externaldrive.connected.to.line.below",
                        expanded: showConfiguration
                    ) {
                        showConfiguration.toggle()
                    }
                    if showConfiguration { webdavSection }
                    masterSection
                    HostSyncInventory(hosts: model.hosts, lastSyncAt: sync.lastSyncAt, isLocked: lock.isLocked)
                    disclosure(
                        title: "备份与高级操作", symbol: "archivebox",
                        expanded: showAdvanced
                    ) {
                        showAdvanced.toggle()
                        if !showAdvanced { confirmOverwrite = false }
                    }
                    if showAdvanced { advancedSection }
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                statusSection
                actionsSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.solidBase)
            .overlay(alignment: .top) { Divider().overlay(Pal.border) }
        }
        .sheet(isPresented: $showMasterSetup) { AppLockSetupSheet() }
        .onDisappear {
            enteredMaster = ""
        }
        .onChange(of: lock.isLocked) { _, locked in
            if locked { enteredMaster = "" }
        }
        .onAppear {
            sync.loadCredentialIfNeeded()
            if !sync.config.isComplete { showConfiguration = true }
            if sync.credentialReadError != nil { showConfiguration = true }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 36, height: 36)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("加密同步")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(sync.credentialReadError != nil ? String(localized: "WebDAV 密码不可用", bundle: AppSettings.localizationBundle, locale: locale) :
                            (sync.config.isComplete ? String(localized: "已填写 WebDAV 连接信息", bundle: AppSettings.localizationBundle, locale: locale)
                             : String(localized: "先配置 WebDAV 连接", bundle: AppSettings.localizationBundle, locale: locale)))
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(sync.config.isComplete && sync.credentialReadError == nil ? Pal.mauve : Pal.yellow)
                    .frame(width: 7, height: 7)
            }
            Text("在设备间合并主机、密钥、AI 配置、应用设置与信任记录。远端备份始终使用主密码加密。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            if let last = sync.lastSyncAt {
                Text("上次同步：\(Self.formatter.string(from: last))")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.border, lineWidth: 1))
    }

    /// 同步内容清单：静态展示参与同步的数据类别。
    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("同步内容", systemImage: "checklist")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            scopeRow("server.rack", name: "主机与密码", detail: "主机配置与已保存的 SSH 密码")
            scopeRow("key", name: "SSH 密钥（含私钥）", detail: "密钥库中的密钥与私钥")
            scopeRow("chevron.left.forwardslash.chevron.right", name: "代码片段", detail: "常用命令片段")
            scopeRow("arrow.left.arrow.right", name: "端口转发", detail: "本地、远程与动态转发规则")
            scopeRow("sparkles", name: "AI 配置（含 API Key）", detail: "模型服务配置与 API Key")
            scopeRow("gearshape", name: "应用设置", detail: "外观、终端、传输等偏好设置")
            scopeRow("checkmark.shield", name: "设备信任记录（known_hosts）", detail: "已信任的主机密钥指纹，并集合并、不删除")
            Text("以上内容全部经主密码加密后同步。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func scopeRow(_ symbol: String, name: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12)).foregroundStyle(Pal.mauve)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                Text(detail).font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("主密码", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            if !lock.hasMasterPassword {
                Text("设置主密码，用于应用解锁与备份加密。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                Button("设置主密码") { showMasterSetup = true }
                    .buttonStyle(.borderedProminent).tint(Pal.mauve)
            } else if lock.masterPassword != nil {
                Label("已验证 · 使用当前主密码加密", systemImage: "checkmark.shield")
                    .font(.system(size: 11)).foregroundStyle(Pal.green)
                Text("锁定应用或退出后清除本次密码。其他设备使用同一主密码即可同步。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            } else {
                ThemedSecureField(placeholder: "输入应用解锁使用的主密码", text: $enteredMaster)
                HStack {
                    Button("验证主密码") { verifyMaster() }
                        .buttonStyle(.borderedProminent).tint(Pal.mauve)
                        .disabled(enteredMaster.isEmpty || verifyingMaster)
                    if verifyingMaster { ProgressView().controlSize(.small) }
                }
                Text("Touch ID 只解锁应用。同步前输入主密码以加解密备份。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            }
            if !masterError.isEmpty { Text(masterError).font(.system(size: 11)).foregroundStyle(Pal.red) }

        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        .disabled(sync.busy)
    }

    private func verifyMaster() {
        guard !verifyingMaster else { return }
        verifyingMaster = true
        masterError = ""
        let candidate = enteredMaster
        Task {
            if !(await lock.verifyPassword(candidate)) {
                masterError = lock.credentialError ?? String(localized: "主密码不正确", bundle: AppSettings.localizationBundle, locale: locale)
            }
            enteredMaster = ""
            verifyingMaster = false
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                Task { await sync.requestMerge(model: model, uploadAfter: true) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("合并同步").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 11))
                }
                .font(.system(size: 12)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).pointerCursor().disabled(sync.busy)
            Text("双向合并；遇到冲突时由你逐项选择。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            actionRow(
                "下载并合并到本机", symbol: "arrow.down.to.line",
                detail: "保留本机独有项，不回传远端"
            ) {
                Task { await sync.requestMerge(model: model, uploadAfter: false) }
            }
            Text("合并不会同步删除。某项若只在另一台设备上存在，会重新带回本机。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if sync.busy || !sync.statusText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if sync.busy {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在处理…").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    }
                }
                if !sync.statusText.isEmpty {
                    Text(sync.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(sync.statusIsError ? Pal.red : Pal.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var webdavSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let error = sync.credentialReadError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("无法读取已保存的 WebDAV 密码", systemImage: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Text(error).font(.system(size: 11)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("重试读取") { sync.retryCredentialRead() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                        .disabled(sync.busy)
                }
                .foregroundStyle(Pal.red)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            }
            field("服务器地址") {
                ThemedTextField(
                    verbatim: "https://dav.example.com/remote.php/dav/files/me",
                    text: $sync.baseURL)
            }
            field("用户名") { ThemedTextField(placeholder: "用户名", text: $sync.username) }
            field("WebDAV 登录密码") { ThemedSecureField(placeholder: "服务器账户的密码或应用专用密码", text: $sync.password) }
            Text("用于登录 WebDAV 服务器，由服务商提供；备份内容由 Termo 主密码加密。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            field("远程文件路径") {
                ThemedTextField(verbatim: SyncConfigStore.defaultRemotePath, text: $sync.remotePath)
            }
            Text("建议使用 HTTPS。Seafile 请先创建资料库；密码保存到系统钥匙串。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecondaryButton(title: "测试连接") { Task { await sync.testConnection() } }
                SecondaryButton(title: "保存配置") {
                    do {
                        try sync.saveConfig()
                        sync.statusText = String(localized: "配置已保存", bundle: AppSettings.localizationBundle, locale: locale)
                        sync.statusIsError = false
                    } catch {
                        sync.statusText = error.localizedDescription
                        sync.statusIsError = true
                    }
                }
            }
            .disabled(sync.busy)
        }
        .padding(12)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 9))
        .disabled(sync.busy)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow("导出加密备份…", symbol: "square.and.arrow.up", detail: "存入本地文件") {
                sync.exportToFile(model: model)
            }
            actionRow("从文件导入…", symbol: "square.and.arrow.down", detail: "读取本地加密备份") {
                sync.importFromFile(model: model)
            }
            Rectangle().fill(Pal.border).frame(height: 1).padding(.vertical, 4)
            if confirmOverwrite {
                VStack(alignment: .leading, spacing: 9) {
                    Text("这会用本机数据替换远端备份，无法从远端恢复被替换的内容。")
                        .font(.system(size: 11)).foregroundStyle(Pal.text)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecondaryButton(title: "取消") { confirmOverwrite = false }
                        Button("确认覆盖") {
                            confirmOverwrite = false
                            Task { await sync.uploadLocal(model: model) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.red)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(Pal.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            } else {
                actionRow(
                    "用本机数据覆盖远端", symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    detail: "替换远端备份；不会合并"
                ) {
                    confirmOverwrite = true
                }
            }
            Text("语言等设置同步后需重启生效。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(sync.busy)
    }

    private func disclosure(
        title: LocalizedStringKey, symbol: String, expanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 17)
                Text(title).fontWeight(.medium)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
            }
            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(title)
            content()
        }
    }

    private func actionRow(
        _ title: LocalizedStringKey, symbol: String,
        detail: LocalizedStringKey, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13))
                    .foregroundStyle(Pal.mauve).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    Text(detail).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.border, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor().disabled(sync.busy)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// 只持有凭证是否存在；与备份负载共用读取入口，避免把内存中的临时密码计入同步。
private struct HostSyncInventory: View {
    @Environment(\.locale) private var locale
    let hosts: [Host]
    let lastSyncAt: Date?
    let isLocked: Bool
    @State private var savedHostIDs: Set<String>?
    @State private var readError: String?
    @State private var showsAllHosts = false
    @State private var refreshID = UUID()

    private struct HostRevision: Equatable {
        let id: String
        let authentication: AuthMethod
        let hasPassword: Bool
    }

    private struct InventoryRevision: Equatable {
        let hosts: [HostRevision]
        let lastSyncAt: Date?
        let isLocked: Bool
        let refreshID: UUID
    }

    private var sshHosts: [Host] { hosts.filter { $0.ssh != nil } }
    private var visibleHosts: [Host] { showsAllHosts ? sshHosts : Array(sshHosts.prefix(3)) }
    private var revision: InventoryRevision {
        InventoryRevision(
            hosts: sshHosts.compactMap {
                guard let ssh = $0.ssh else { return nil }
                return HostRevision(id: $0.id, authentication: ssh.authMethod, hasPassword: !ssh.password.isEmpty)
            },
            lastSyncAt: lastSyncAt, isLocked: isLocked, refreshID: refreshID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("本机主机与凭证", systemImage: "server.rack")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer(minLength: 0)
                Button {
                    refreshID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Pal.subtext)
                .help("重新读取已保存凭证").accessibilityLabel("重新读取已保存凭证")
                .disabled(isLocked)
            }
            HStack(spacing: 7) {
                Text("\(sshHosts.count) 台 SSH 主机").foregroundStyle(Pal.subtext)
                Text("·").foregroundStyle(Pal.overlay)
                if let savedHostIDs {
                    Text("\(savedHostIDs.count) 份已保存凭证").foregroundStyle(Pal.green)
                } else {
                    Text(isLocked ? String(localized: "解锁后查看凭证状态", bundle: AppSettings.localizationBundle, locale: locale)
                         : readError == nil ? String(localized: "读取凭证状态…", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "凭证状态不可用", bundle: AppSettings.localizationBundle, locale: locale))
                        .foregroundStyle(Pal.overlay)
                }
            }
            .font(.system(size: 11))

            if let readError {
                Text(readError).font(.system(size: 11)).foregroundStyle(Pal.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sshHosts.isEmpty {
                Text("添加 SSH 主机后，可在这里查看密码是否已保存并参与同步。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(visibleHosts) { host in
                        credentialRow(host)
                        if host.id != visibleHosts.last?.id {
                            Rectangle().fill(Pal.border).frame(height: 1)
                        }
                    }
                }
                if sshHosts.count > 3 {
                    Button {
                        showsAllHosts.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Text(showsAllHosts
                                 ? String(localized: "收起主机列表", bundle: AppSettings.localizationBundle, locale: locale)
                                 : String(localized: "查看全部 \(sshHosts.count) 台主机", bundle: AppSettings.localizationBundle, locale: locale))
                            Image(systemName: showsAllHosts ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundStyle(Pal.mauve)
                }
            }
            Text("已保存的 SSH 密码和私钥口令会随主机加密同步。「每次询问」的临时密码不参与备份。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.border, lineWidth: 1))
        .task(id: revision) { await refreshCredentials() }
    }

    private func credentialRow(_ host: Host) -> some View {
        let saved = savedHostIDs?.contains(host.id) == true
        let temporary = host.ssh?.authMethod == .ask
        let title = host.ssh?.authMethod == .key ? String(localized: "私钥口令", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "SSH 密码", bundle: AppSettings.localizationBundle, locale: locale)
        let status = temporary ? String(localized: "每次询问 · 不备份密码", bundle: AppSettings.localizationBundle, locale: locale)
            : savedHostIDs == nil ? String(localized: "保存状态待确认", bundle: AppSettings.localizationBundle, locale: locale)
            : saved ? String(localized: "已保存 · 将加密同步", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "未保存凭证", bundle: AppSettings.localizationBundle, locale: locale)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: saved ? "lock.shield.fill" : "key")
                .font(.system(size: 13)).foregroundStyle(saved ? Pal.green : Pal.overlay)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(2).textSelection(.enabled)
                Text("\(host.ssh?.user ?? "")@\(host.ipOrHost)")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .lineLimit(1).truncationMode(.middle).help(host.addr)
                Text("\(title)：\(status)")
                    .font(.system(size: 10)).foregroundStyle(saved ? Pal.green : Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func refreshCredentials() async {
        savedHostIDs = nil
        readError = nil
        guard !isLocked else { return }
        let snapshot = sshHosts
        do {
            let ids = try await Task.detached(priority: .userInitiated) {
                Set(try HostStore.savedPasswords(for: snapshot).keys)
            }.value
            guard !Task.isCancelled else { return }
            savedHostIDs = ids
        } catch {
            guard !Task.isCancelled else { return }
            readError = String(localized: "无法读取已保存凭证：\(error.localizedDescription)", bundle: AppSettings.localizationBundle, locale: locale)
        }
    }
}

/// 在整个设置窗口上显示；包含只读规模，确认前不修改业务数据。
private struct SyncPreviewDialog: View {
    @Environment(\.locale) private var locale
    let p: SyncModel.SyncPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("同步前预览", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                        Text(p.uploadAfter
                             ? String(localized: "合并后将更新本机与远端备份。", bundle: AppSettings.localizationBundle, locale: locale)
                             : String(localized: "合并后仅更新本机，不回传远端。", bundle: AppSettings.localizationBundle, locale: locale))
                            .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    Divider().overlay(Pal.border)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 5) {
                                Text("内容").frame(maxWidth: .infinity, alignment: .leading)
                                Text("本机").frame(width: 55)
                                Text("远端").frame(width: 55)
                                Text("合并后").frame(width: 55)
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                            metric("主机", local: p.localHosts, remote: p.remoteHosts, merged: p.mergedHosts)
                            metric("密钥", local: p.localKeys, remote: p.remoteKeys, merged: p.mergedKeys)
                            metric("片段", local: p.localSnippets, remote: p.remoteSnippets, merged: p.mergedSnippets)
                            metric("端口转发", local: p.localForwards, remote: p.remoteForwards, merged: p.mergedForwards)
                            metric("信任记录", local: p.localKnownHosts, remote: p.remoteKnownHosts, merged: p.mergedKnownHosts)
                            metricText("AI 配置", local: p.localAI, remote: p.remoteAI, merged: p.mergedAI)
                            Divider().overlay(Pal.border)
                            Text("已保存 SSH 密码：本机 \(p.localPasswords) 份 · 远端 \(p.remotePasswords) 份")
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            if p.conflicts > 0 {
                                Label("\(p.conflicts) 项内容不同，下一步会逐项选择保留版本。", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                    .font(.system(size: 12)).foregroundStyle(Pal.yellow)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("同步范围包括主机、已保存的密码、密钥与私钥、片段、端口转发、AI 配置、参与同步的设置和设备信任记录。合并会保留两边独有项，不会同步删除。")
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().overlay(Pal.border)
                    HStack(spacing: 10) {
                        Spacer()
                        SecondaryButton(title: "取消", action: onCancel).keyboardShortcut(.cancelAction)
                        PrimaryButton(title: p.conflicts > 0 ? "核对冲突" : "确认合并", action: onConfirm)
                    }
                    .padding(16)
                }
                .frame(width: min(520, max(280, geometry.size.width - 32)),
                       height: min(520, max(300, geometry.size.height - 32)))
                .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.border))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func metric(_ label: LocalizedStringKey, local: Int, remote: Int, merged: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(local.formatted()).frame(width: 55)
            Text(remote.formatted()).frame(width: 55)
            Text(merged.formatted()).frame(width: 55)
        }
        .font(.system(size: 12)).foregroundStyle(Pal.text)
    }

    /// AI 配置这类 0/1 语义的内容：显示「有/无」而非数量。
    private func metricText(_ label: LocalizedStringKey, local: Bool, remote: Bool, merged: Bool) -> some View {
        HStack(spacing: 5) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Text(local ? String(localized: "有", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "无", bundle: AppSettings.localizationBundle, locale: locale)).frame(width: 55)
            Text(remote ? String(localized: "有", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "无", bundle: AppSettings.localizationBundle, locale: locale)).frame(width: 55)
            Text(merged ? String(localized: "有", bundle: AppSettings.localizationBundle, locale: locale) : String(localized: "无", bundle: AppSettings.localizationBundle, locale: locale)).frame(width: 55)
        }
        .font(.system(size: 12)).foregroundStyle(Pal.text)
    }
}

/// 同步冲突裁决弹窗。覆盖整个设置窗口，避免被页面滚动区域裁切。
struct SyncDialogs: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let preview = sync.pendingPreview {
                SyncPreviewDialog(p: preview) {
                    Task { await sync.confirmPreview(model: model) }
                } onCancel: {
                    sync.cancelPreview()
                }
            } else if let pending = sync.pendingMerge {
                SyncConflictDialog(result: pending.result) { choices in
                    Task { await sync.resolvePending(choices: choices, model: model) }
                } onCancel: {
                    sync.cancelPending()
                }
            }
        }
    }
}

private struct SyncConflictDialog: View {
    let result: SyncMergeResult
    let onConfirm: ([String: Bool]) -> Void
    let onCancel: () -> Void
    @State private var choices: [String: Bool] = [:]

    private var remaining: Int { result.conflicts.filter { choices[$0.id] == nil }.count }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("解决同步冲突")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                        Text("核对字段后选择保留整条记录；未列出的配置也会随之替换。")
                            .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        Text("已选择 \(result.conflicts.count - remaining) / \(result.conflicts.count) 项")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(remaining == 0 ? Pal.green : Pal.yellow)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    Divider().overlay(Pal.border)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { bulkButtons }
                                VStack(alignment: .leading, spacing: 8) { bulkButtons }
                            }
                            ForEach(result.conflicts) { conflict in row(conflict) }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().overlay(Pal.border)
                    HStack(spacing: 10) {
                        Spacer()
                        SecondaryButton(title: "取消", action: onCancel).keyboardShortcut(.cancelAction)
                        PrimaryButton(title: remaining == 0 ? "应用选择" : "还有 \(remaining) 项未选择", enabled: remaining == 0) {
                            guard remaining == 0 else { return }
                            onConfirm(choices)
                        }
                    }
                    .padding(16)
                }
                .frame(width: min(620, max(280, geometry.size.width - 32)),
                       height: min(680, max(300, geometry.size.height - 32)))
                .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.border))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private var bulkButtons: some View {
        SecondaryButton(title: "全部保留本机") {
            for conflict in result.conflicts { choices[conflict.id] = true }
        }
        SecondaryButton(title: "全部使用远端") {
            for conflict in result.conflicts { choices[conflict.id] = false }
        }
    }

    private func row(_ conflict: SyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: choices[conflict.id] == nil ? "circle.dotted" : "checkmark.circle.fill")
                    .foregroundStyle(choices[conflict.id] == nil ? Pal.yellow : Pal.green)
                Text(conflict.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Pal.text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            ForEach(conflict.fields, id: \.label) { field in
                VStack(alignment: .leading, spacing: 7) {
                    Text(field.label).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(field.isDifferent ? Pal.yellow : Pal.subtext)
                    comparison("本机", value: field.local)
                    comparison("远端", value: field.remote)
                }
                .padding(.vertical, 6)
                Divider().overlay(Pal.border)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choiceButtons(for: conflict) }
                VStack(spacing: 8) { choiceButtons(for: conflict) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.border))
    }

    private func comparison(_ label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                .frame(width: 32, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func choiceButtons(for conflict: SyncConflict) -> some View {
        choice("保留本机", selected: choices[conflict.id] == true) { choices[conflict.id] = true }
        choice("使用远端", selected: choices[conflict.id] == false) { choices[conflict.id] = false }
    }

    private func choice(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Pal.mauve : Pal.subtext)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? Pal.mauve.opacity(0.12) : Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Pal.mauve.opacity(0.35) : Pal.border))
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
