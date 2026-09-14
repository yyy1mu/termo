import SwiftUI

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

    private let fs: RemoteFS
    let command: String

    init(ssh: SSHConnection, command: String) {
        fs = RemoteFS(ssh)
        self.command = command
    }

    func load() async {
        phase = .loading
        let r = await fs.run(command, timeout: 25)
        let out = String(decoding: r.data, as: UTF8.self)
        if r.code < 0 {
            let msg = String(decoding: r.stderr, as: UTF8.self)
            phase = .failed(msg.isEmpty ? String(localized: "命令执行失败") : msg)
            return
        }
        // 面板脚本用哨兵串标记「不支持」（工具未安装），不当作硬错误。
        if out.contains("__UNSUPPORTED__") {
            phase = .unsupported(out.replacingOccurrences(of: "__UNSUPPORTED__", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }
        stdout = out
        phase = .loaded
    }

    func refresh() { Task { await load() } }
}

// MARK: - 面板骨架

/// 通用骨架：搜索框 + 刷新按钮 + 按阶段渲染（加载/失败/不支持/列表/空态）。
private struct ExecPanelScaffold<Item: Identifiable, Row: View>: View {
    @ObservedObject var state: ExecPanelState
    var searchPlaceholder = String(localized: "搜索…")
    var extraHeader: (() -> AnyView)? = nil
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                TextField(searchPlaceholder, text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Pal.text)
                Button { state.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        .foregroundStyle(Pal.subtext)
                        .frame(width: 24, height: 24)
                        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.top, 8)

            if let extraHeader { AnyView(extraHeader()).padding(.horizontal, 12).padding(.top, 8) }

            switch state.phase {
            case .loading:
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            case .failed(let msg):
                notice("exclamationmark.triangle", msg, accent: Pal.yellow)
            case .unsupported(let msg):
                notice("shippingbox", msg.isEmpty ? String(localized: "目标机器不支持该功能") : msg, accent: Pal.overlay)
            case .loaded:
                if items.isEmpty {
                    notice("tray", String(localized: "暂无内容"), accent: Pal.overlay)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(items) { row($0) }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    private func notice(_ symbol: String, _ text: String, accent: Color) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(accent)
            Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 通用卡片与控件

private struct PanelCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.border, lineWidth: 1))
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
                .frame(width: 24, height: 24)
                .background(hover ? accent.opacity(0.16) : accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().onHover { hover = $0 }.help(help)
    }
}

// MARK: - tmux

struct TmuxPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(wrappedValue: ExecPanelState(
            ssh: host.ssh ?? SSHConnection(),
            command: #"sh -lc 'command -v tmux >/dev/null 2>&1 && tmux ls 2>/dev/null || echo "__UNSUPPORTED__未安装 tmux"'"#))
    }

    private struct TmuxSession: Identifiable {
        let id: String   // 会话名
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
            if let wRange = line.range(of: #"\d+(?= windows?)"#, options: .regularExpression) {
                windows = Int(line[wRange]) ?? 1
            }
            return TmuxSession(id: name, windows: windows, attached: line.contains("(attached)"))
        }
    }

    var body: some View {
        let sessions = Self.parse(state.stdout).filter {
            state.query.isEmpty || $0.name.localizedCaseInsensitiveContains(state.query)
        }
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索会话…"),
            extraHeader: {
                AnyView(HStack {
                    PanelActionButton(symbol: "plus", accent: Pal.mauve, help: String(localized: "新建会话")) {
                        Task {
                            let next = (Self.parse(state.stdout).compactMap { Int($0.name) }.max() ?? 0) + 1
                            let r = await RemoteFS(host.ssh ?? SSHConnection()).run("tmux new -d -s \(next)", timeout: 15)
                            if r.code == 0 { state.refresh() }
                        }
                    }
                    Spacer()
                })
            },
            items: sessions
        ) { s in
            PanelCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                        HStack(spacing: 6) {
                            PanelBadge(text: s.attached ? String(localized: "已连接") : String(localized: "未连接"),
                                       color: s.attached ? Pal.green : Pal.overlay)
                            Text("\(s.windows) 窗口").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        }
                    }
                    Spacer()
                    PanelActionButton(symbol: "terminal", accent: Pal.mauve, help: String(localized: "接入会话")) {
                        model.openHostTerminal(host)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            model.sendTextToTerminal("tmux attach -t \(s.name)", run: true)
                        }
                    }
                    PanelActionButton(symbol: "trash", accent: Pal.red, help: String(localized: "删除会话")) {
                        Task {
                            let r = await RemoteFS(host.ssh ?? SSHConnection()).run("tmux kill-session -t \(s.name)", timeout: 15)
                            if r.code == 0 { state.refresh() }
                        }
                    }
                }
            }
        }
        .onAppear { state.refresh() }
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
        _state = StateObject(wrappedValue: ExecPanelState(
            ssh: host.ssh ?? SSHConnection(),
            command: #"sh -lc 'command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service --all --plain --no-legend --no-pager 2>/dev/null | head -150 || echo "__UNSUPPORTED__非 systemd 系统"'"#))
    }

    private struct SystemService: Identifiable {
        let id: String   // unit 名
        var unit: String { id }
        let load: String
        let active: String
        let sub: String
        let description: String
        var running: Bool { active == "active" && sub == "running" }
        var failed: Bool { active == "failed" || sub == "failed" }
    }

    private static func parse(_ out: String) -> [SystemService] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[0].hasSuffix(".service") else { return nil }
            let desc = parts.count > 4 ? parts[4...].joined(separator: " ") : ""
            return SystemService(id: String(parts[0]), load: String(parts[1]),
                                 active: String(parts[2]), sub: String(parts[3]), description: desc)
        }
    }

    private func act(_ action: String, _ unit: String) {
        Task {
            let r = await RemoteFS(host.ssh ?? SSHConnection()).run("systemctl \(action) -- \(unit) </dev/null", timeout: 20)
            if r.code == 0 { state.refresh() }
        }
    }

    var body: some View {
        let all = Self.parse(state.stdout)
        let filtered = all.filter {
            state.query.isEmpty || $0.unit.localizedCaseInsensitiveContains(state.query)
                || $0.description.localizedCaseInsensitiveContains(state.query)
        }
        let running = all.filter(\.running).count
        let failed = all.filter(\.failed).count
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索服务名称或描述…"),
            extraHeader: {
                AnyView(HStack(spacing: 12) {
                    Text("全部 \(all.count)").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Text("运行中 \(running)").font(.system(size: 11)).foregroundStyle(Pal.green)
                    Text("失败 \(failed)").font(.system(size: 11)).foregroundStyle(failed > 0 ? Pal.red : Pal.overlay)
                    Spacer()
                })
            },
            items: filtered
        ) { s in
            PanelCard {
                HStack(spacing: 10) {
                    Circle().fill(s.running ? Pal.green : (s.failed ? Pal.red : Pal.overlay)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.unit).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                        if !s.description.isEmpty {
                            Text(s.description).font(.system(size: 10)).foregroundStyle(Pal.overlay).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            PanelBadge(text: s.running ? String(localized: "运行中") : (s.failed ? String(localized: "失败") : String(localized: "已停止")),
                                       color: s.running ? Pal.green : (s.failed ? Pal.red : Pal.overlay))
                            PanelBadge(text: s.load == "loaded" ? String(localized: "已加载") : s.load, color: Pal.overlay)
                        }
                    }
                    Spacer()
                    if s.running {
                        PanelActionButton(symbol: "stop.fill", accent: Pal.red, help: String(localized: "停止")) { act("stop", s.unit) }
                        PanelActionButton(symbol: "arrow.clockwise", accent: Pal.yellow, help: String(localized: "重启")) { act("restart", s.unit) }
                    } else {
                        PanelActionButton(symbol: "play.fill", accent: Pal.green, help: String(localized: "启动")) { act("start", s.unit) }
                    }
                    Menu {
                        Button(s.load == "loaded" ? String(localized: "禁用自启") : String(localized: "启用自启")) { act(s.load == "loaded" ? "disable" : "enable", s.unit) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                            .frame(width: 24, height: 24).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
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
        _state = StateObject(wrappedValue: ExecPanelState(
            ssh: host.ssh ?? SSHConnection(),
            command: #"sh -lc 'ps -eo pid=,user=,pcpu=,pmem=,rss=,etime=,comm= --sort=-rss 2>/dev/null | head -45'"#))
    }

    private struct ProcInfo: Identifiable {
        let id: Int   // pid
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
            return ProcInfo(id: pid, user: String(p[1]),
                            cpu: Double(p[2]) ?? 0, mem: Double(p[3]) ?? 0,
                            rssKB: Int(p[4]) ?? 0, etime: String(p[5]), command: p[6...].joined(separator: " "))
        }
    }

    private var totalMemKB: Int { Self.parse(state.stdout).reduce(0) { $0 + $1.rssKB } }

    var body: some View {
        let procs = Self.parse(state.stdout).filter {
            state.query.isEmpty || $0.command.localizedCaseInsensitiveContains(state.query)
                || $0.user.localizedCaseInsensitiveContains(state.query) || String($0.pid).contains(state.query)
        }
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索进程名称、PID 或用户…"),
            extraHeader: {
                AnyView(HStack {
                    Text("共 \(procs.count) 个进程").font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    Spacer()
                })
            },
            items: procs
        ) { p in
            PanelCard {
                HStack(spacing: 10) {
                    Circle().fill(p.user == "root" ? Pal.yellow : Pal.overlay).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(p.command).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text).lineLimit(1)
                            Text("PID \(p.pid)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay)
                        }
                        Text("\(p.user) · \(p.etime)").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        HStack(spacing: 8) {
                            Text("内存 \(formatSizeKB(p.rssKB))").font(.system(size: 10)).foregroundStyle(Pal.mauve)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Pal.fill(0.08)).frame(height: 3)
                                    RoundedRectangle(cornerRadius: 2).fill(Pal.mauve)
                                        .frame(width: geo.size.width * min(1, totalMemKB > 0 ? Double(p.rssKB) / Double(totalMemKB) : 0), height: 3)
                                }
                            }
                            .frame(height: 3)
                            Text("CPU \(String(format: "%.1f", p.cpu))%").font(.system(size: 10)).foregroundStyle(Pal.yellow)
                        }
                    }
                    Spacer()
                    PanelActionButton(symbol: "xmark", accent: Pal.red, help: String(localized: "结束进程")) {
                        Task {
                            let r = await RemoteFS(host.ssh ?? SSHConnection()).run("kill -- \(p.pid)", timeout: 15)
                            if r.code == 0 { state.refresh() }
                        }
                    }
                }
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - 网络连接

struct NetworkPanel: View {
    @ObservedObject var model: AppModel
    let host: Host
    @StateObject private var state: ExecPanelState
    @State private var stateFilter = 0   // 0=全部 1=监听 2=已连接

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(wrappedValue: ExecPanelState(
            ssh: host.ssh ?? SSHConnection(),
            command: #"sh -lc 'command -v ss >/dev/null 2>&1 && ss -tunapH 2>/dev/null | head -260 || echo "__UNSUPPORTED__缺少 ss 工具"'"#))
    }

    private struct NetConn: Identifiable {
        let id = UUID()
        let proto: String
        let state: String
        let local: String
        let peer: String
        let process: String
        var isListen: Bool { state == "LISTEN" || state == "UNCONN" }
    }

    private static func parse(_ out: String) -> [NetConn] {
        out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 6, ["tcp", "udp", "tcp6", "udp6"].contains(String(p[0]).lowercased()) else { return nil }
            var proc = ""
            if let m = line.range(of: #"\(\("([^"]+)"#, options: .regularExpression) {
                proc = String(line[m].dropFirst(3).dropLast(1))
            }
            return NetConn(proto: String(p[0]).uppercased(), state: String(p[1]),
                           local: String(p[4]), peer: String(p[5]), process: proc)
        }
    }

    var body: some View {
        let all = Self.parse(state.stdout)
        let listening = all.filter(\.isListen).count
        let established = all.count - listening
        let filtered = all.filter {
            (stateFilter == 0 || (stateFilter == 1) == $0.isListen)
                && (state.query.isEmpty || $0.local.contains(state.query) || $0.peer.contains(state.query)
                    || $0.process.localizedCaseInsensitiveContains(state.query))
        }
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索地址、端口、进程…"),
            extraHeader: {
                AnyView(HStack(spacing: 8) {
                    SegmentedControl(
                        options: [(0, String(localized: "全部")), (1, String(localized: "监听")), (2, String(localized: "已连接"))],
                        selection: $stateFilter)
                    .frame(width: 220)
                    Spacer()
                    Text("\(listening) 监听 · \(established) 已连接").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                })
            },
            items: filtered
        ) { c in
            PanelCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            PanelBadge(text: c.proto, color: Pal.mauve)
                            PanelBadge(text: c.isListen ? String(localized: "监听") : c.state,
                                       color: c.isListen ? Pal.green : Pal.mauve)
                        }
                        Text("本地 \(c.local)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                        Text("远端 \(c.peer)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
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
    @State private var tab = 0   // 0=容器 1=镜像 2=卷 3=网络

    init(model: AppModel, host: Host) {
        self.model = model
        self.host = host
        _state = StateObject(wrappedValue: ExecPanelState(
            ssh: host.ssh ?? SSHConnection(),
            command: #"sh -lc 'command -v docker >/dev/null 2>&1 && { echo "==PS=="; docker ps -a --format "{{.Names}}|{{.Image}}|{{.Status}}" 2>/dev/null; echo "==IMAGES=="; docker images --format "{{.Repository}}:{{.Tag}}|{{.Size}}" 2>/dev/null; echo "==VOLUMES=="; docker volume ls --format "{{.Name}}" 2>/dev/null; echo "==NETWORKS=="; docker network ls --format "{{.Name}}|{{.Driver}}" 2>/dev/null; } || echo "__UNSUPPORTED__未安装 Docker"'"#))
    }

    private struct Container: Identifiable {
        let id: String   // 名称
        var name: String { id }
        let image: String
        let status: String
        var running: Bool { status.hasPrefix("Up") }
    }
    private struct Named: Identifiable {
        let id: String
        var name: String { id }
        var extra = ""
    }

    private func sections() -> (containers: [Container], images: [Named], volumes: [Named], networks: [Named]) {
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
                containers.append(Container(id: parts[0], image: parts[1], status: parts[2...].joined(separator: "|")))
            case "==IMAGES==": images.append(Named(id: parts[0], extra: parts.count > 1 ? parts[1] : ""))
            case "==VOLUMES==": volumes.append(Named(id: parts[0]))
            case "==NETWORKS==": networks.append(Named(id: parts[0], extra: parts.count > 1 ? parts[1] : ""))
            default: continue
            }
        }
        return (containers, images, volumes, networks)
    }

    private func act(_ action: String, _ name: String) {
        Task {
            let r = await RemoteFS(host.ssh ?? SSHConnection()).run("docker \(action) -- \(name) </dev/null", timeout: 30)
            if r.code == 0 { state.refresh() }
        }
    }

    var body: some View {
        let (containers, images, volumes, networks) = sections()
        ExecPanelScaffold(
            state: state,
            searchPlaceholder: String(localized: "搜索…"),
            extraHeader: {
                AnyView(SegmentedControl(
                    options: [(0, "容器 \(containers.count)"), (1, "镜像 \(images.count)"),
                              (2, "卷 \(volumes.count)"), (3, "网络 \(networks.count)")],
                    selection: $tab))
            },
            items: tab == 0 ? containers.filter { state.query.isEmpty || $0.name.contains(state.query) || $0.image.contains(state.query) } : []
        ) { c in
            PanelCard {
                HStack(spacing: 10) {
                    Circle().fill(c.running ? Pal.green : Pal.overlay).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        Text(c.image).font(.system(size: 10, design: .monospaced)).foregroundStyle(Pal.overlay).lineLimit(1)
                        PanelBadge(text: c.running ? String(localized: "运行中") : String(localized: "已停止"),
                                   color: c.running ? Pal.green : Pal.overlay)
                    }
                    Spacer()
                    if c.running {
                        PanelActionButton(symbol: "stop.fill", accent: Pal.red, help: String(localized: "停止")) { act("stop", c.name) }
                        PanelActionButton(symbol: "arrow.clockwise", accent: Pal.yellow, help: String(localized: "重启")) { act("restart", c.name) }
                    } else {
                        PanelActionButton(symbol: "play.fill", accent: Pal.green, help: String(localized: "启动")) { act("start", c.name) }
                    }
                }
            }
        }
        .overlay {
            if tab != 0 && state.phase == .loaded {
                let (list, kind) = tab == 1 ? (images, String(localized: "镜像")) : tab == 2 ? (volumes, String(localized: "卷")) : (networks, String(localized: "网络"))
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if list.isEmpty {
                            Text("暂无\(kind)").font(.system(size: 12)).foregroundStyle(Pal.overlay).padding(.top, 40)
                        }
                        ForEach(list) { n in
                            PanelCard {
                                HStack {
                                    Text(n.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text).lineLimit(1)
                                    Spacer()
                                    if !n.extra.isEmpty {
                                        Text(n.extra).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .background(Pal.mantle)
                .padding(.top, 96)   // 与骨架的搜索/切换头部对齐，避免遮挡
            }
        }
        .onAppear { state.refresh() }
    }
}

// MARK: - 工具

private func formatSizeKB(_ kb: Int) -> String {
    if kb >= 1024 * 1024 { return String(format: "%.1f GB", Double(kb) / 1024 / 1024) }
    if kb >= 1024 { return String(format: "%.1f MB", Double(kb) / 1024) }
    return "\(kb) KB"
}
