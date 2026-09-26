import SwiftUI

/// 端口转发管理面板：列出某主机的全部转发规则，可启停、新建、编辑、删除。
/// 隧道复用现有 SSH 凭证，由进程内 SSH 引擎与 ForwardManager 维护。
struct PortForwardView: View {
    @ObservedObject var model: AppModel
    let host: Host
    @ObservedObject private var theme = ThemeManager.shared

    // 非 nil 时进入表单：值为待编辑的规则；新建时为一条该主机的空规则。
    @State private var formRule: ForwardRule? = nil
    @State private var isNew = false
    @State private var query = ""
    // 删除确认：非 nil 时弹确认；dontAskAgain 勾选后写入 model.skipForwardDeleteConfirm（仅本次运行）。
    @State private var pendingDelete: ForwardRule? = nil
    @State private var dontAskAgain = false

    private var manager: ForwardManager { model.forwardManager(for: host) }
    private var rules: [ForwardRule] { model.forwardRules(for: host.id) }

    private var filteredRules: [ForwardRule] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty
            ? rules
            : rules.filter {
                $0.name.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q)
                    || $0.kind.title.localizedCaseInsensitiveContains(q)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            if let rule = formRule {
                ForwardRuleForm(
                    existing: isNew ? nil : rule,
                    hostId: host.id,
                    onSave: { saved in
                        model.saveForwardRule(saved)
                        formRule = nil
                    },
                    onCancel: { formRule = nil }
                )
                .id(rule.id)  // 切换编辑对象时强制重建，避免表单 @State 残留上一条规则
            } else {
                listContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 不刷底色：右栏容器已是 Pal.mantle（CompanionPanel 统一供给），再盖 base 会比相邻面板暗半档。
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay {
            // 无弹窗时整层不吃点击：避免 .transition 淡出期间残留的全屏命中层短暂挡住下方点击。
            ZStack {
                if let rule = pendingDelete {
                    deleteConfirm(rule).transition(.opacity)
                }
            }
            .allowsHitTesting(pendingDelete != nil)
        }
        .animation(.easeOut(duration: 0.15), value: pendingDelete?.id)
    }

    /// 请求删除：本次运行已选「不再询问」则直接删，否则弹确认。
    private func requestDelete(_ rule: ForwardRule) {
        if model.skipForwardDeleteConfirm {
            model.deleteForwardRule(rule)
        } else {
            dontAskAgain = false
            pendingDelete = rule
        }
    }

    /// 删除确认弹窗（含「不再询问」复用设置里的自定义 checkbox；勾选只在本次运行生效）。
    @ViewBuilder
    private func deleteConfirm(_ rule: ForwardRule) -> some View {
        let name = rule.name.isEmpty ? (rule.kind.title + String(localized: "转发", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) : rule.name
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { pendingDelete = nil }
            VStack(alignment: .leading, spacing: 14) {
                Text("删除转发规则「\(name)」？")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Text("将停止其运行中的隧道并移除该规则，不可恢复。")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ThemedCheckbox(isOn: dontAskAgain) { dontAskAgain.toggle() }
                    Text("本次不再询问")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        .onTapGesture { dontAskAgain.toggle() }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消") { pendingDelete = nil }
                    Button {
                        if dontAskAgain { model.skipForwardDeleteConfirm = true }
                        model.deleteForwardRule(rule)
                        pendingDelete = nil
                    } label: {
                        Text("删除").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Pal.red, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .padding(12)
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            if formRule != nil {
                Button {
                    formRule = nil
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(isNew ? String(localized: "新建规则", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "编辑规则", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Pal.overlay)
                    TextField("搜索规则或端口", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(Pal.overlay).help("清除搜索")
                    }
                }
                .font(.system(size: 12)).padding(8)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                Button(action: startNew) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).foregroundStyle(Pal.mauve)
                .help("新建规则").accessibilityLabel("新建规则")
            }
        }
        .padding(12)
    }

    // MARK: - 规则列表

    @ViewBuilder
    private var listContent: some View {
        if rules.isEmpty {
            emptyState
        } else if filteredRules.isEmpty {
            PanelEmptyState(
                symbol: "magnifyingglass", title: String(localized: "没有匹配的规则", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                detail: String(localized: "可以按名称、地址或端口搜索。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                actionTitle: String(localized: "清除搜索", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: { query = "" })
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text("\(filteredRules.count) 条规则")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    ForEach(filteredRules) { rule in
                        ForwardRow(
                            rule: rule,
                            manager: manager,
                            onToggle: { model.toggleForward(rule) },
                            onEdit: { startEdit(rule) },
                            onDelete: { requestDelete(rule) }
                        )
                    }
                }
                .padding(12)
            }
        }
    }

    private var emptyState: some View {
        PanelEmptyState(
            symbol: "arrow.left.arrow.right",
            title: String(localized: "还没有转发规则", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            detail: String(localized: "通过 SSH 隧道安全访问服务器内网服务，无需在服务器安装任何东西。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            actionTitle: String(localized: "新建规则", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            action: startNew
        )
    }

    private func startNew() {
        formRule = ForwardRule(hostId: host.id)
        isNew = true
    }
    private func startEdit(_ rule: ForwardRule) {
        formRule = rule
        isNew = false
    }
}

/// 分离名称、流量方向与运行操作，窄面板也能完整阅读地址。
private struct ForwardRow: View {
    let rule: ForwardRule
    @ObservedObject var manager: ForwardManager
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    private var status: ForwardManager.RuleStatus { manager.status(rule.id) }
    private var enabled: Bool { manager.isEnabled(rule.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(rule.name.isEmpty ? rule.kind.title + String(localized: "转发", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : rule.name)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("编辑", action: onEdit).disabled(enabled)
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Pal.subtext).help("规则操作（运行时需先停止再编辑）")
            }
            ForwardRoute(
                kind: rule.kind,
                listener: Self.endpoint(
                    rule.bindAddress.isEmpty ? "127.0.0.1" : rule.bindAddress, rule.listenPort),
                destination: Self.endpoint(rule.destHost, rule.destPort))
            if case .failed(let reason) = status {
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Pal.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText).font(.system(size: 11)).foregroundStyle(statusColor)
                Spacer(minLength: 4)
                Button(action: onToggle) {
                    Label(
                        enabled ? String(localized: "停止", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "启动", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        systemImage: enabled ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).foregroundStyle(enabled ? Pal.red : Pal.mauve)
            }
        }
        .padding(12)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func endpoint(_ host: String, _ port: Int) -> String {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(address):\(port)"
    }

    private var statusColor: Color {
        switch status {
        case .stopped: return Pal.overlay
        case .starting: return Pal.yellow
        case .active: return Pal.green
        case .failed: return enabled ? Pal.yellow : Pal.red
        }
    }
    private var statusText: String {
        switch status {
        case .stopped: return String(localized: "已停止", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .starting: return String(localized: "正在连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .active: return String(localized: "运行中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .failed: return enabled ? String(localized: "等待重连", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "连接失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

/// 方向按监听端 → 目标端呈现，明确 localhost 对应哪一端。
private struct ForwardRoute: View {
    let kind: ForwardKind
    let listener: String
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            endpoint(
                kind == .remote ? String(localized: "服务器监听", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "本机监听", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                address: listener, symbol: kind == .remote ? "server.rack" : "laptopcomputer")
            HStack(spacing: 8) {
                Image(systemName: "arrow.down").frame(width: 16)
                Text(kind == .dynamic
                     ? String(localized: "SOCKS5 · 通过服务器访问网络", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                     : String(localized: "通过 SSH 隧道", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            }
            .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            if kind != .dynamic {
                endpoint(
                    kind == .remote ? String(localized: "本机侧目标", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "服务器侧目标", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    address: destination, symbol: "arrow.turn.down.right")
            }
        }
    }

    private func endpoint(_ title: String, address: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Pal.mauve)
                .frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                Text(address).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

/// 新建/编辑规则表单。
private struct ForwardRuleForm: View {
    let existing: ForwardRule?
    let hostId: String
    let onSave: (ForwardRule) -> Void
    let onCancel: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    @State private var kind: ForwardKind
    @State private var name: String
    @State private var bind: String
    @State private var listen: String
    @State private var destHost: String
    @State private var destPort: String
    @State private var error: String?

    init(
        existing: ForwardRule?, hostId: String,
        onSave: @escaping (ForwardRule) -> Void, onCancel: @escaping () -> Void
    ) {
        self.existing = existing
        self.hostId = hostId
        self.onSave = onSave
        self.onCancel = onCancel
        let r = existing ?? ForwardRule(hostId: hostId)
        _kind = State(initialValue: r.kind)
        _name = State(initialValue: r.name)
        _bind = State(initialValue: r.bindAddress)
        _listen = State(initialValue: r.listenPort == 0 ? "" : String(r.listenPort))
        _destHost = State(initialValue: r.destHost)
        _destPort = State(initialValue: r.destPort == 0 ? "" : String(r.destPort))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                labeled(String(localized: "类型", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), hint: kind.hint) {
                    SegmentedControl(
                        options: ForwardKind.allCases.map { (value: $0, verbatim: $0.title) },
                        selection: $kind
                    )
                    .frame(maxWidth: .infinity)
                    Text(directionHint).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }

                labeled(String(localized: "别名（可选）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), hint: String(localized: "便于识别，如「生产库」。留空则显示类型。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                    ThemedTextField(placeholder: "可选", text: $name).frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 12) {
                    labeled(
                        kind == .remote ? String(localized: "服务器监听地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "本机监听地址", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        hint: String(localized: "监听端绑定的网卡地址。仅本机访问填 127.0.0.1；开放给局域网填 0.0.0.0。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    ) {
                        ThemedTextField(placeholder: "127.0.0.1", text: $bind).frame(maxWidth: .infinity)
                    }
                    labeled(
                        kind == .dynamic ? String(localized: "代理端口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "监听端口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        hint: String(localized: "在监听端开放的端口，连接它的流量进入隧道。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    ) {
                        ThemedTextField(placeholder: "如 8080", text: $listen).frame(maxWidth: .infinity)
                    }
                }

                if kind != .dynamic {
                    VStack(alignment: .leading, spacing: 12) {
                        labeled(
                            kind == .remote ? String(localized: "本机侧目标主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "服务器侧目标主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                            hint: destHostHint
                        ) {
                            ThemedTextField(placeholder: "localhost", text: $destHost).frame(
                                maxWidth: .infinity)
                        }
                        labeled(String(localized: "目标端口", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), hint: String(localized: "目标服务监听的端口。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                            ThemedTextField(placeholder: "如 3306", text: $destPort).frame(maxWidth: .infinity)
                        }
                    }
                }

                previewLine

            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(Pal.border)
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Pal.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 10)
                }
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: existing == nil ? "添加规则" : "保存更改", action: save)
                }
                .padding(12)
            }
            .background(Pal.solidMantle)
        }
    }

    private var directionHint: String {
        switch kind {
        case .local: return String(localized: "通过本机端口访问服务器侧的服务。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .remote: return String(localized: "通过服务器端口访问本机侧的服务。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .dynamic: return String(localized: "在本机建立 SOCKS5 代理，流量从服务器转出。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private var destHostHint: String {
        kind == .remote
            ? String(localized: "从本机视角解析的地址。localhost 指本机自身。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            : String(localized: "从服务器视角解析的地址。localhost 指服务器自身——这正是访问只监听内网的远程数据库的用法。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
    }

    private var previewLine: some View {
        let address = bind.trimmingCharacters(in: .whitespaces)
        let listener = address.isEmpty ? "127.0.0.1" : address
        return VStack(alignment: .leading, spacing: 10) {
            Text("流量方向").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
            ForwardRoute(
                kind: kind,
                listener: "\(listener):\(listen.isEmpty ? "…" : listen)",
                destination: "\(destHost.isEmpty ? "…" : destHost):\(destPort.isEmpty ? "…" : destPort)")
            Text("保存后在规则列表中启动。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labeled<C: View>(_ title: String, hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .tooltip(hint)
            }
            content()
        }
    }

    private func save() {
        var r = existing ?? ForwardRule(hostId: hostId)
        r.kind = kind
        r.name = name.trimmingCharacters(in: .whitespaces)
        let b = bind.trimmingCharacters(in: .whitespaces)
        r.bindAddress = b.isEmpty ? "127.0.0.1" : b
        r.listenPort = Int(listen.trimmingCharacters(in: .whitespaces)) ?? 0
        r.destHost = destHost.trimmingCharacters(in: .whitespaces)
        r.destPort = Int(destPort.trimmingCharacters(in: .whitespaces)) ?? 0
        if let e = r.validationError { error = e; return }
        onSave(r)
    }
}
