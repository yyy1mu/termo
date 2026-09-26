import SwiftUI
import TermoCore

//  扩展伴随面板（P3）：tmux / 系统服务 / 进程 / 网络连接 / Docker。
//  共同模式：经 RemoteFS 借暖连接执行一条远端命令，把输出解析成卡片列表；
//  动作（接入/启停/删除/kill）再走一条短命令后刷新。解析函数为纯静态、与 UI 解耦。

// MARK: - 远端命令状态

/// 伴随面板通用命令状态：出现即执行一次，支持刷新与失败/不支持提示。
@MainActor
final class ExecPanelState: ObservableObject {
    enum Phase: Equatable {
        case loading, loaded
        case failed(String)
        case unsupported(String)
    }

    @Published var phase: Phase = .loading
    @Published var stdout = ""
    @Published var query = ""
    @Published private(set) var isRefreshing = false
    @Published private(set) var isActing = false
    @Published private(set) var updatedAt: Date?

    /// 取最新凭证的闭包：「每次询问」主机输过密码后 host.ssh 会更新，值类型快照会过期，须实时取。
    private let sshProvider: @MainActor () -> SSHConnection
    let command: String

    init(ssh: @escaping @MainActor () -> SSHConnection, command: String) {
        sshProvider = ssh
        self.command = command
    }

    func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if stdout.isEmpty { phase = .loading }
        let r = await RemoteFS(sshProvider()).run(command, timeout: 25)
        let out = String(decoding: r.data, as: UTF8.self)
        if r.code != 0 {
            let msg = String(decoding: r.stderr, as: UTF8.self)
            phase = .failed(msg.isEmpty ? String(localized: "命令执行失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : msg)
            return
        }
        // 面板脚本用哨兵串标记「不支持」（工具未安装），不当作硬错误。
        if out.contains("__UNSUPPORTED__") {
            phase = .unsupported(
                out.replacingOccurrences(of: "__UNSUPPORTED__", with: "").trimmingCharacters(
                    in: .whitespacesAndNewlines))
            return
        }
        stdout = out
        phase = .loaded
        updatedAt = Date()
    }

    func refresh() { Task { await load() } }

    func perform(_ command: String, timeout: Double = 20) async {
        guard !isActing, !isRefreshing else { return }
        isActing = true
        defer { isActing = false }
        let result = await RemoteFS(sshProvider()).run(command, timeout: timeout)
        if result.code == 0 { await load() } else { reportFailure(result.stderr) }
    }

    /// 动作命令失败时把 stderr 反馈为错误状态（骨架顶部刷新按钮可重试恢复）。
    func reportFailure(_ stderr: Data) {
        let msg = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .failed(msg.isEmpty ? String(localized: "命令执行失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : msg)
    }
}

// MARK: - 面板骨架

/// 通用骨架：搜索框 + 刷新按钮 + 按阶段渲染（加载/失败/不支持/列表/空态）。
private struct ExecPanelScaffold<Item: Identifiable, Row: View>: View {
    @ObservedObject var state: ExecPanelState
    var searchPlaceholder = String(localized: "搜索…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
    var extraHeader: (() -> AnyView)? = nil
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Pal.overlay)
                        TextField(searchPlaceholder, text: $state.query)
                            .textFieldStyle(.plain).foregroundStyle(Pal.text)
                        if !state.query.isEmpty {
                            Button {
                                state.query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Pal.overlay)
                            }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                        }
                    }
                    .font(.system(size: 12)).padding(10)
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
                    Button {
                        state.refresh()
                    } label: {
                        ZStack {
                            if state.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 13))
                            }
                        }
                        .foregroundStyle(Pal.subtext).frame(width: 34, height: 34)
                        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain).pointerCursor().disabled(state.isRefreshing || state.isActing)
                    .help(String(localized: "刷新列表", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)).accessibilityLabel("刷新列表")
                }
                if state.phase == .loaded, let extraHeader { extraHeader() }
            }.padding(14)
            Rectangle().fill(Pal.border).frame(height: 1)
            switch state.phase {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("正在读取主机数据…").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ScrollView {
                    PanelEmptyState(
                        symbol: "exclamationmark.triangle", title: String(localized: "读取失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        detail: message, actionTitle: String(localized: "重新加载", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        action: { state.refresh() }, symbolColor: Pal.yellow
                    )
                    .padding(.vertical, 32)
                }
            case .unsupported(let message):
                PanelEmptyState(
                    symbol: "shippingbox", title: String(localized: "此主机暂不支持", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    detail: message, symbolColor: Pal.overlay)
            case .loaded:
                if items.isEmpty {
                    PanelEmptyState(
                        symbol: state.query.isEmpty ? "tray" : "magnifyingglass",
                        title: state.query.isEmpty ? String(localized: "暂无项目", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "没有匹配结果", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                        detail: state.query.isEmpty
                            ? String(localized: "刷新列表，查看最新状态。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "试试其他名称、地址或关键词。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { row($0).disabled(state.isActing || state.isRefreshing) }
                        }.padding(10)
                    }
                }
            }
            if let updatedAt = state.updatedAt {
                HStack(spacing: 6) {
                    if state.isActing { ProgressView().controlSize(.mini) }
                    Text(state.isActing ? String(localized: "正在执行操作…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "最近更新", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    if !state.isActing { Text(updatedAt, style: .time).monospacedDigit() }
                    Spacer(minLength: 0)
                    Text("\(items.count) 项")
                }
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(Pal.border).frame(height: 1) }
            }
        }
    }
}

// MARK: - 通用卡片与控件

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var hover = false
    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 右栏容器是 Pal.mantle：卡片用更亮的 Pal.card 浮起（原先 idle 用更深的 Pal.base，像凹陷）；
            // hover 用主题感知的半透明覆盖层微提亮，而非跳档到 surface0。
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .fill(hover ? Pal.fill(0.06) : Color.clear)
                    .allowsHitTesting(false)
            }
            .onHover { hover = $0 }
    }
}

private struct PanelBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct PanelActionButton: View {
    let symbol: String
    let accent: Color
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11)).foregroundStyle(accent)
                .frame(width: 28, height: 28)
                .background(
                    hover ? accent.opacity(0.16) : accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { hover = $0 }.help(help).accessibilityLabel(help)
    }
}

// MARK: - tmux

struct TmuxPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState
    @State private var pendingKill: TmuxSession? = nil  // 删除会话确认弹窗

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(
            wrappedValue: ExecPanelState(
                ssh: { liveSSH(model, host) },
                // 先单独判未安装（输出哨兵串并正常退出）；无会话时 tmux ls 退出码 1，吞掉显示空列表而非误报未安装。
                command:
                    #"sh -lc 'command -v tmux >/dev/null 2>&1 || { echo "__UNSUPPORTED__未安装 tmux"; exit 0; }; tmux ls 2>/dev/null || true'"#
            ))
    }

    private struct TmuxSession: Identifiable {
        let id: String  // 会话名
        var name: String { id }
        let windows: Int
        let attached: Bool
    }

    private static func parse(_ out: String) -> [TmuxSession] {
        out.split(separator: "\n").compactMap { line in
            // "2: 1 windows (created Mon ...) (attached)"
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            var windows = 1
            // 只在首个冒号之后的子串里匹配窗口数，避免会话名本身含「3 windows」字样时取错
            let rest = line[line.index(after: colon)...]
            if let wRange = rest.range(of: #"\d+(?= windows?)"#, options: .regularExpression) {
                windows = Int(rest[wRange]) ?? 1
            }
            return TmuxSession(id: name, windows: windows, attached: line.contains("(attached)"))
        }
    }

    /// 面板动作统一入口：经登录 shell 执行（exec 本身无 PATH 初始化，tmux 可能在 /usr/local/bin 等），
    /// 成功刷新列表；失败把 stderr 反馈到面板错误状态（刷新按钮可重试）。
    private func act(_ script: String, timeout: Double = 15) async {
        await state.perform("sh -lc \(Self.shellQuote(script))", timeout: timeout)
    }

    /// 单引号 shell 转义（' → '\''）：tmux 会话名可含空格/$/反引号等，拼进命令前必须转义。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var body: some View {
        let sessions = Self.parse(state.stdout).filter {
            state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query)
        }
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索会话…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            extraHeader: {
                AnyView(
                    HStack {
                        Button {
                            Task {
                                let next =
                                    (Self.parse(state.stdout).compactMap { Int($0.name) }.max() ?? 0) + 1
                                await act("tmux new -d -s \(next)")
                            }
                        } label: {
                            Label("新建会话", systemImage: "plus").font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain).foregroundStyle(Pal.mauve).disabled(
                            state.isActing || state.isRefreshing)
                        Spacer()
                        Text("\(sessions.count) 个会话").font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    })
            },
            items: sessions
        ) { s in
            PanelCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                            .lineLimit(2).help(s.name)
                        HStack(spacing: 6) {
                            PanelBadge(
                                text: s.attached ? String(localized: "已连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "未连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                                color: s.attached ? Pal.green : Pal.overlay)
                            Text("\(s.windows) 窗口").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        }
                    }
                    Spacer()
                    PanelActionButton(
                        symbol: "terminal", accent: Pal.mauve, help: String(localized: "在新标签接入会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                    ) {
                        model.openTmuxSessionTab(host: host, sessionName: s.name)
                    }
                    PanelActionButton(symbol: "trash", accent: Pal.red, help: String(localized: "删除会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                        pendingKill = s
                    }
                }
            }
        }
        .onAppear { state.refresh() }
        .alert(
            "删除会话？", isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } }),
            presenting: pendingKill
        ) { session in
            Button("取消", role: .cancel) { pendingKill = nil }
            Button("删除", role: .destructive) {
                pendingKill = nil
                Task { await act("tmux kill-session -t \(Self.shellQuote("=" + session.name))") }
            }
        } message: { session in
            Text(
                session.attached
                    ? "会话「\(session.name)」仍有终端接入。删除会立即断开其中所有连接，且不可恢复。"
                    : "会话「\(session.name)」删除后不可恢复。")
        }
    }
}

// MARK: - 系统服务（systemd）

struct ServicesPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(
            wrappedValue: ExecPanelState(
                ssh: { liveSSH(model, host) },
                command:
                    #"sh -lc 'command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all --plain --no-legend --no-pager 2>/dev/null | head -150 || echo "__UNSUPPORTED__非 systemd 系统"'"#
            ))
    }

    private struct SystemService: Identifiable {
        let id: String  // unit 名
        var unit: String { id }
        let load: String
        let active: String
        let sub: String
        let description: String
        var running: Bool { active == "active" && sub == "running" }
        var failed: Bool { active == "failed" || sub == "failed" }
        var statusTitle: String {
            if running { return String(localized: "运行中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if failed { return String(localized: "失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if active == "active" && sub == "exited" { return String(localized: "已完成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if active == "inactive" { return String(localized: "未运行", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if active == "activating" { return String(localized: "启动中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if active == "deactivating" { return String(localized: "停止中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            return active + " · " + sub
        }
    }

    private static func parse(_ out: String) -> [SystemService] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[0].hasSuffix(".service") else { return nil }
            let desc = parts.count > 4 ? parts[4...].joined(separator: " ") : ""
            return SystemService(
                id: String(parts[0]), load: String(parts[1]),
                active: String(parts[2]), sub: String(parts[3]), description: desc)
        }
    }

    private func act(_ action: String, _ unit: String) {
        Task { await state.perform("systemctl \(action) -- \(shellQuote(unit)) </dev/null") }
    }

    var body: some View {
        let all = Self.parse(state.stdout)
        let filtered = all.filter {
            state.query.isEmpty || $0.unit.localizedCaseInsensitiveContains(state.query)
                || $0.description.localizedCaseInsensitiveContains(state.query)
        }
        ExecPanelScaffold(
            state: state, searchPlaceholder: String(localized: "搜索服务名称或描述…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            extraHeader: {
                AnyView(
                    HStack(spacing: 8) {
                        PanelBadge(
                            text: String(localized: "运行 \(all.filter(\.running).count)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), color: Pal.green)
                        PanelBadge(
                            text: String(localized: "失败 \(all.filter(\.failed).count)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), color: Pal.red)
                        Spacer()
                        Text("前 150 项").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    })
            }, items: filtered
        ) { service in
            PanelCard {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(service.unit).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                            Pal.text
                        )
                        .lineLimit(2).help(service.unit).frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("启动") { act("start", service.unit) }
                            Button("重启") { act("restart", service.unit) }
                            Button("停止", role: .destructive) { act("stop", service.unit) }
                            Divider()
                            Button("启用开机启动") { act("enable", service.unit) }
                            Button("禁用开机启动") { act("disable", service.unit) }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 24)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(
                            String(localized: "服务操作", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    }
                    if !service.description.isEmpty {
                        Text(service.description).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .lineLimit(2).help(service.description)
                    }
                    HStack {
                        PanelBadge(
                            text: service.statusTitle,
                            color: service.running ? Pal.green : (service.failed ? Pal.red : Pal.overlay))
                        Spacer()
                        Text(service.load).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    }
                }
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - 进程

struct ProcessesPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(
            wrappedValue: ExecPanelState(
                ssh: { liveSSH(model, host) },
                command:
                    #"sh -lc 'ps -eo pid=,user=,pcpu=,pmem=,rss=,etime=,comm= --sort=-rss 2>/dev/null | head -45'"#
            ))
    }

    private struct ProcInfo: Identifiable {
        let id: Int  // pid
        var pid: Int { id }
        let user: String
        let cpu: Double
        let mem: Double
        let rssKB: Int
        let etime: String
        let command: String
    }

    private static func parse(_ out: String) -> [ProcInfo] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 7, let pid = Int(p[0]) else { return nil }
            return ProcInfo(
                id: pid, user: String(p[1]),
                cpu: Double(p[2]) ?? 0, mem: Double(p[3]) ?? 0,
                rssKB: Int(p[4]) ?? 0, etime: String(p[5]), command: p[6...].joined(separator: " "))
        }
    }

    @State private var pendingTermination: ProcInfo?

    var body: some View {
        let procs = Self.parse(state.stdout).filter {
            state.query.isEmpty || $0.command.localizedCaseInsensitiveContains(state.query)
                || $0.user.localizedCaseInsensitiveContains(state.query)
                || String($0.pid).contains(state.query)
        }
        ExecPanelScaffold(
            state: state, searchPlaceholder: String(localized: "进程、PID 或用户…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            extraHeader: {
                AnyView(
                    HStack {
                        Text("按内存排序 · 前 45 项").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        Spacer()
                    })
            }, items: procs
        ) { process in
            PanelCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(process.command).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                            Pal.text
                        )
                        .lineLimit(2).help(process.command).frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("结束进程…", role: .destructive) { pendingTermination = process }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 24)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(
                            String(localized: "进程操作", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    }
                    Text("PID \(String(process.pid)) · \(process.user) · \(process.etime)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        metric("CPU", String(format: "%.1f%%", process.cpu), color: Pal.yellow)
                            .help(String(localized: "单个 CPU 核为 100%，多核进程可超过 100%", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        metric(
                            "内存 · \(String(format: "%.1f", process.mem))%", formatSizeKB(process.rssKB),
                            color: Pal.mauve)
                    }
                }
            }
        }
        .onAppear { state.refresh() }
        .alert(
            "结束进程？",
            isPresented: Binding(
                get: { pendingTermination != nil }, set: { if !$0 { pendingTermination = nil } }),
            presenting: pendingTermination
        ) { process in
            Button("取消", role: .cancel) { pendingTermination = nil }
            Button("结束进程", role: .destructive) {
                pendingTermination = nil
                Task { await state.perform("kill -- \(process.pid)", timeout: 15) }
            }
        } message: { process in
            Text("将向 \(process.command)（PID \(process.pid)）发送结束信号，未保存的工作可能丢失。")
        }
    }

    private func metric(_ label: LocalizedStringKey, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(Pal.subtext)
            Text(value).font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 网络连接

struct NetworkPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState
    @State private var stateFilter = 0  // 0=全部 1=监听 2=已连接

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(
            wrappedValue: ExecPanelState(
                ssh: { liveSSH(model, host) },
                command:
                    #"sh -lc 'command -v ss >/dev/null 2>&1 && ss -tunapH 2>/dev/null | head -260 || echo "__UNSUPPORTED__缺少 ss 工具"'"#
            ))
    }

    private struct NetConn: Identifiable {
        let id: String
        let proto: String
        let state: String
        let local: String
        let peer: String
        let process: String
        var isListen: Bool { state == "LISTEN" || state == "UNCONN" }
    }

    private static func parse(_ out: String) -> [NetConn] {
        var occurrences: [String: Int] = [:]
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 6, ["tcp", "udp", "tcp6", "udp6"].contains(String(p[0]).lowercased()) else {
                return nil
            }
            var proc = ""
            if let m = line.range(of: #"\(\("([^"]+)"#, options: .regularExpression) {
                proc = String(line[m].dropFirst(3))
            }
            let key = String(line)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return NetConn(
                id: key + "#" + String(occurrence), proto: String(p[0]).uppercased(), state: String(p[1]),
                local: String(p[4]), peer: String(p[5]), process: proc)
        }
    }

    var body: some View {
        let all = Self.parse(state.stdout)
        let listening = all.filter(\.isListen).count
        let established = all.filter { $0.state == "ESTAB" }.count
        let filtered = all.filter {
            (stateFilter == 0 || (stateFilter == 1 && $0.isListen)
                || (stateFilter == 2 && $0.state == "ESTAB"))
                && (state.query.isEmpty || $0.local.contains(state.query) || $0.peer.contains(state.query)
                    || $0.process.localizedCaseInsensitiveContains(state.query))
        }
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索地址、端口、进程…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            extraHeader: {
                AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        SegmentedControl(
                            options: [
                                (0, String(localized: "全部", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), (1, String(localized: "监听", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
                                (2, String(localized: "已连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
                            ],
                            selection: $stateFilter
                        )
                        .frame(maxWidth: .infinity)
                        Text("\(listening) 监听 · \(established) 已连接").font(.system(size: 10)).foregroundStyle(
                            Pal.overlay)
                    })
            },
            items: filtered
        ) { c in
            PanelCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            PanelBadge(text: c.proto, color: Pal.mauve)
                            PanelBadge(
                                text: c.isListen ? String(localized: "监听", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : c.state,
                                color: c.isListen ? Pal.green : Pal.mauve)
                        }
                        Text("本地 \(c.local)").font(.system(size: 11, design: .monospaced)).foregroundStyle(
                            Pal.text
                        )
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("远端 \(c.peer)").font(.system(size: 11, design: .monospaced)).foregroundStyle(
                            Pal.subtext
                        )
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if !c.process.isEmpty {
                            Text("进程 \(c.process)").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        }
                    }
                    Spacer()
                }
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - Docker

struct DockerPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState
    @State private var tab = 0  // 0=容器 1=镜像 2=卷 3=网络

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(
            wrappedValue: ExecPanelState(
                ssh: { liveSSH(model, host) },
                command:
                    #"sh -lc 'command -v docker >/dev/null 2>&1 && { echo "==PS=="; docker ps -a --format "{{.Names}}|{{.Image}}|{{.Status}}" 2>/dev/null; echo "==IMAGES=="; docker images --format "{{.Repository}}:{{.Tag}}|{{.Size}}" 2>/dev/null; echo "==VOLUMES=="; docker volume ls --format "{{.Name}}" 2>/dev/null; echo "==NETWORKS=="; docker network ls --format "{{.Name}}|{{.Driver}}" 2>/dev/null; } || echo "__UNSUPPORTED__未安装 Docker"'"#
            ))
    }

    private struct Container: Identifiable {
        let id: String  // 名称
        var name: String { id }
        let image: String
        let status: String
        var paused: Bool { status.contains("(Paused)") }
        var running: Bool { status.hasPrefix("Up") && !paused }
        var statusTitle: String {
            if paused { return String(localized: "已暂停", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if running { return String(localized: "运行中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if status.hasPrefix("Restarting") { return String(localized: "重启中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if status.hasPrefix("Created") { return String(localized: "未启动", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            if status.hasPrefix("Dead") { return String(localized: "异常", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
            return String(localized: "已停止", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
    private struct Named: Identifiable {
        let id: String
        var name: String { id }
        var extra = ""
    }

    private func sections() -> (containers: [Container], images: [Named], volumes: [Named], networks: [Named])
    {
        var containers: [Container] = [], images: [Named] = [], volumes: [Named] = [], networks: [Named] = []
        var cur = ""
        for line in state.stdout.split(separator: "\n") {
            let l = String(line)
            if l.hasPrefix("==") { cur = l; continue }
            guard !l.isEmpty else { continue }
            let parts = l.split(separator: "|").map(String.init)
            switch cur {
            case "==PS==":
                guard parts.count >= 3 else { continue }
                containers.append(
                    Container(id: parts[0], image: parts[1], status: parts[2...].joined(separator: "|")))
            case "==IMAGES==": images.append(Named(id: parts[0], extra: parts.count > 1 ? parts[1] : ""))
            case "==VOLUMES==": volumes.append(Named(id: parts[0]))
            case "==NETWORKS==": networks.append(Named(id: parts[0], extra: parts.count > 1 ? parts[1] : ""))
            default: continue
            }
        }
        return (containers, images, volumes, networks)
    }

    private func act(_ action: String, _ name: String) {
        Task { await state.perform("docker \(action) -- \(shellQuote(name)) </dev/null", timeout: 30) }
    }

    private struct Resource: Identifiable {
        let id: String
        let name: String
        let detail: String
        var container: Container?
    }

    var body: some View {
        let (containers, images, volumes, networks) = sections()
        let resources: [Resource] =
            tab == 0
            ? containers.map {
                Resource(id: "container:" + $0.id, name: $0.name, detail: $0.image, container: $0)
            }
            : (tab == 1 ? images : tab == 2 ? volumes : networks).map {
                Resource(id: "\(tab):" + $0.id, name: $0.name, detail: $0.extra)
            }
        let filtered = resources.filter {
            state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query)
                || $0.detail.localizedCaseInsensitiveContains(state.query)
        }
        ExecPanelScaffold(
            state: state, searchPlaceholder: String(localized: "搜索资源名称…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            extraHeader: {
                AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        SegmentedControl(
                            options: [
                                (0, String(localized: "容器", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), (1, String(localized: "镜像", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
                                (2, String(localized: "卷", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)), (3, String(localized: "网络", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)),
                            ], selection: $tab)
                        Text("\(resources.count) 项资源").font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    })
            }, items: filtered
        ) { resource in
            PanelCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(resource.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                            Pal.text
                        )
                        .lineLimit(2).help(resource.name).frame(maxWidth: .infinity, alignment: .leading)
                        if let container = resource.container {
                            Menu {
                                if container.paused {
                                    Button("恢复运行") { act("unpause", container.name) }
                                } else if container.running {
                                    Button("重启") { act("restart", container.name) }
                                    Button("停止", role: .destructive) { act("stop", container.name) }
                                } else {
                                    Button("启动") { act("start", container.name) }
                                }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 28, height: 24)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(
                                String(localized: "容器操作", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        }
                    }
                    if !resource.detail.isEmpty {
                        Text(resource.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                            Pal.subtext
                        )
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    if let container = resource.container {
                        HStack(alignment: .top, spacing: 8) {
                            PanelBadge(
                                text: container.statusTitle,
                                color: container.paused
                                    ? Pal.yellow : (container.running ? Pal.green : Pal.overlay))
                            Text(container.status).font(.system(size: 10)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - 工具

/// 按 hostId 从 AppModel 取最新 SSH 凭证：「每次询问」主机输过密码后，面板持有的 host 是值类型快照（无密码），须实时取。
@MainActor
private func liveSSH(_ model: AppModel, _ host: Host) -> SSHConnection {
    model.host(host.id)?.ssh ?? host.ssh ?? SSHConnection()
}

private func formatSizeKB(_ kb: Int) -> String {
    if kb >= 1024 * 1024 { return String(format: "%.1f GiB", Double(kb) / 1024 / 1024) }
    if kb >= 1024 { return String(format: "%.1f MiB", Double(kb) / 1024) }
    return "\(kb) KiB"
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
