import SwiftUI

struct TestConnectionView: View {
    @ObservedObject var draft: HostDraft
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tester = ConnectionTester()

    var body: some View {
        VStack(spacing: 0) {
            // 头部
            HStack {
                Text("测试连接")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 24, height: 24)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭连接测试")
                .pointerCursor()
            }
            .padding(.horizontal, 20).padding(.vertical, 16)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            ConnectionProgressView(tester: tester, targetLabel: targetLabel)

            Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

            // 底部
            HStack {
                Spacer()
                if tester.isRunning {
                    SecondaryButton(title: "取消") { tester.cancel(); dismiss() }
                } else {
                    SecondaryButton(title: "关闭") { dismiss() }
                    PrimaryButton(title: "重新测试") { tester.start(conn: draft.buildConnection()) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: 320, idealWidth: 540, maxWidth: 700, minHeight: 360, idealHeight: 600, maxHeight: 760)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            // 用禁用动画的事务填充初始内容，避免内容在 sheet 呈现动画期间「从上滑入」
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { tester.start(conn: draft.buildConnection()) }
        }
        .onDisappear { tester.cancel() }
        .overlay {
            if let pending = tester.pendingHostKey { HostKeyDialog(pending: pending) }
        }
    }

    private var targetLabel: String { draft.targetLabel }
}

/// 目标与状态常驻；进度和诊断日志分别滚动，避免六个步骤挤占日志阅读空间。
struct ConnectionProgressView: View {
    @ObservedObject var tester: ConnectionTester
    let targetLabel: String
    @State private var showLogs = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ConnectionTargetHeader(target: targetLabel, status: tester.overallStatusText, color: tester.overallColor)
            HStack(spacing: 6) {
                sectionButton("连接进度", selected: !showLogs) { showLogs = false }
                sectionButton("日志", selected: showLogs) { showLogs = true }
                Spacer()
                Text("\(tester.steps.filter { $0.state == .success }.count) / \(tester.steps.count)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .accessibilityLabel("已完成 \(tester.steps.filter { $0.state == .success }.count) 个步骤，共 \(tester.steps.count) 个")
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider().overlay(Pal.border)
            if showLogs {
                ConnectionLogView(logs: tester.logs)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let reason = tester.failureMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("连接未完成", systemImage: "exclamationmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(reason).font(.system(size: 12)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("查看完整日志") { showLogs = true }
                                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).pointerCursor()
                            }
                            .foregroundStyle(Pal.red).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Pal.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tester.steps) { step in stepRow(step) }
                        }
                        if tester.cancelled && !tester.failed && !tester.succeeded {
                            Text("已取消本次连接，可以关闭或重新尝试。")
                                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionButton(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Pal.mauve : Pal.subtext)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? Pal.mauve.opacity(0.12) : Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stepRow(_ step: ConnectionStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepIcon(step.state).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text(step.title).font(.system(size: 13, weight: step.state == .running ? .semibold : .regular))
                    .foregroundStyle(step.state == .pending ? Pal.overlay : Pal.text)
                if let detail = step.detail {
                    Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(step.statusLabel).font(.system(size: 11)).foregroundStyle(Pal.subtext)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stepIcon(_ state: ConnectionStep.State) -> some View {
        switch state {
        case .pending: Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(Pal.overlay)
        case .running: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Pal.green)
        case .failure: Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Pal.red)
        }
    }
}

private struct ConnectionTargetHeader: View {
    let target: String
    let status: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(status).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
                Spacer()
            }
            Text(target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }
}

/// 与 AI 阅读行为一致：追加内容不会打断向上阅读，接近底部后恢复跟随。
private struct ConnectionLogView: View {
    let logs: [ConnectionLog]
    @Namespace private var coordinateSpace
    @State private var followingLatest = true
    @State private var lastFrame: CGRect?

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if logs.isEmpty {
                            Text("尚无连接日志").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        } else {
                            combinedLog.font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                    .padding(20)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ConnectionLogFrameKey.self, value: content.frame(in: .named(coordinateSpace)))
                        }
                    }
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(ConnectionLogFrameKey.self) { frame in
                    guard let frame else { return }
                    let previous = lastFrame
                    lastFrame = frame
                    let heightChanged = previous.map { abs($0.height - frame.height) > 0.5 } ?? true
                    let positionChanged = previous.map { abs($0.minY - frame.minY) > 0.5 } ?? false
                    let nearBottom = frame.maxY - viewport.size.height <= 48
                    if let previous, positionChanged {
                        if followingLatest {
                            if !heightChanged, frame.minY > previous.minY, !nearBottom { followingLatest = false }
                        } else if nearBottom { followingLatest = true }
                    }
                    if followingLatest, heightChanged { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
                .onChange(of: logs.first?.id) {
                    followingLatest = true
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
                .onChange(of: viewport.size.height) {
                    if followingLatest { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("log-bottom", anchor: .bottom) }
                .overlay(alignment: .bottom) {
                    if !followingLatest {
                        Button {
                            followingLatest = true
                            proxy.scrollTo("log-bottom", anchor: .bottom)
                        } label: {
                            Label("回到最新日志", systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(Pal.text).background(Pal.surface0, in: Capsule())
                                .overlay(Capsule().strokeBorder(Pal.border))
                        }
                        .buttonStyle(.plain).pointerCursor().padding(.bottom, 10)
                    }
                }
            }
        }
    }

    private var combinedLog: Text {
        logs.reduce(Text(verbatim: "")) { result, log in
            result + Text(verbatim: log.time.isEmpty ? "" : log.time + "  ").foregroundColor(Pal.overlay)
                + Text(verbatim: log.message + "\n").foregroundColor(log.color)
        }
    }
}

private struct ConnectionLogFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// 连接主机时的进度弹窗（复用 ConnectionProgressView），成功后回调进入终端。
struct ConnectingDialog: View {
    let host: Host
    var successHint: String = String(localized: "正在进入终端…")   // 成功后的提示，按动作变化（终端/文件/转发/监控）
    let verify: () async -> Bool   // 指纹验证（可能弹出指纹核对框）；返回是否继续连接
    let onConnected: () -> Void
    let onCancel: () -> Void
    @StateObject private var tester = ConnectionTester()
    @ObservedObject private var theme = ThemeManager.shared
    @State private var verifying = true
    @State private var active = true
    @State private var completionTask: Task<Void, Never>?
    
    private let dialogCornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Text("连接主机").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    Rectangle().fill(Pal.fill(0.06)).frame(height: 1)

                    if verifying {
                        verifyingPanel
                    } else {
                        ConnectionProgressView(tester: tester, targetLabel: targetLabel)
                    }

                    Rectangle().fill(Pal.fill(0.06)).frame(height: 1)
                    HStack {
                        Spacer()
                        if verifying {
                            SecondaryButton(title: "取消", action: cancelConnection).keyboardShortcut(.cancelAction)
                        } else if tester.isRunning {
                            SecondaryButton(title: "取消", action: cancelConnection).keyboardShortcut(.cancelAction)
                        } else if !tester.succeeded {
                            SecondaryButton(title: "取消", action: cancelConnection).keyboardShortcut(.cancelAction)
                            PrimaryButton(title: "重试") { tester.start(conn: host.ssh ?? SSHConnection()) }
                        } else {
                            Text("连接成功，\(successHint)").font(.system(size: 12)).foregroundStyle(Pal.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .frame(width: min(540, max(280, geometry.size.width - 32)), height: min(580, max(280, geometry.size.height - 32)))
                .background(Pal.solidMantle)
                .clipShape(
                    RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: dialogCornerRadius, style: .continuous)
                        .strokeBorder(Pal.fill(0.08), lineWidth: 1)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task {
            tester.onFinished = { success in
                guard success, active else { return }
                completionTask?.cancel()
                completionTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    guard active, !Task.isCancelled else { return }
                    onConnected()
                }
            }
            // 第一阶段：验证主机指纹（已知主机瞬间通过；未知主机会叠加指纹核对框）
            let ok = await verify()
            guard active, !Task.isCancelled else { return }
            if ok {
                verifying = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { tester.start(conn: host.ssh ?? SSHConnection()) }
            } else {
                cancelConnection()
            }
        }
        .onDisappear {
            active = false
            completionTask?.cancel()
            tester.onFinished = nil
            tester.cancel()
        }
        .overlay {
            if let pending = tester.pendingHostKey { HostKeyDialog(pending: pending) }
        }
    }

    private func cancelConnection() {
        active = false
        completionTask?.cancel()
        tester.onFinished = nil
        tester.cancel()
        onCancel()
    }

    private var verifyingPanel: some View {
        VStack(spacing: 0) {
            ConnectionTargetHeader(target: targetLabel, status: String(localized: "核对主机身份"), color: Pal.yellow)
            Spacer()
            VStack(spacing: 14) {
                ProgressView().controlSize(.small)
                Text("正在验证主机指纹…")
                    .font(.system(size: 13)).foregroundStyle(Pal.subtext)
                Text("核对通过后才会发送登录凭证。")
                    .font(.system(size: 12)).foregroundStyle(Pal.overlay)
            }
            .padding(20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetLabel: String {
        guard let s = host.ssh else { return host.addr }
        let u = s.user.isEmpty ? "" : "\(s.user)@"
        let address = s.host.contains(":") ? "[\(s.host)]" : s.host
        return "\(u)\(address):\(s.port)"
    }
}

// MARK: - 连接测试器（消费进程内 SSH 引擎的阶段回调）

struct ConnectionStep: Identifiable {
    enum State { case pending, running, success, failure }
    let id = UUID()
    let title: String
    var state: State = .pending
    var detail: String? = nil
    var statusLabel: String {
        switch state {
        case .pending: return String(localized: "未执行")
        case .running: return String(localized: "进行中")
        case .success: return String(localized: "已完成")
        case .failure: return String(localized: "失败")
        }
    }
}

struct ConnectionLog: Identifiable {
    let id = UUID()
    let time: String
    let message: String
    let color: Color
}

@MainActor
final class ConnectionTester: ObservableObject {
    @Published var steps: [ConnectionStep] = []
    @Published var logs: [ConnectionLog] = []
    @Published var isRunning = false
    @Published var failed = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var cancelled = false
    @Published private(set) var pendingHostKey: PendingHostKey?
    private var trustContinuation: CheckedContinuation<HostKeyDecision, Never>?
    private var preflightTask: Task<Void, Never>?
    private var connectionGeneration = UUID()

    private let stepTitles = [
        String(localized: "初始化配置"),
        String(localized: "解析主机地址"),
        String(localized: "建立 TCP 连接"),
        String(localized: "SSH 协议握手"),
        String(localized: "身份验证"),
        String(localized: "连接成功"),
    ]
    private var concluded = false
    /// C 回调闭包载体（Unmanaged 跨 @convention(c) 边界传递）。
    private final class StageBox {
        let cb: (Int, Bool, String?) -> Void
        init(_ cb: @escaping (Int, Bool, String?) -> Void) { self.cb = cb }
    }
    /// 测试/连接结束时回调一次（true=成功）。
    var onFinished: ((Bool) -> Void)?

    private func conclude(_ success: Bool) {
        guard !concluded else { return }
        concluded = true
        onFinished?(success)
    }

    var succeeded: Bool { !steps.isEmpty && steps.allSatisfy { $0.state == .success } }

    var overallStatusText: String {
        if pendingHostKey != nil { return String(localized: "等待核对主机指纹") }
        if isRunning { return String(localized: "连接中…") }
        if failed { return String(localized: "连接失败") }
        if succeeded { return String(localized: "连接成功") }
        if cancelled { return String(localized: "已取消") }
        return String(localized: "等待中")
    }

    var overallColor: Color {
        if isRunning { return Pal.yellow }
        if failed { return Pal.red }
        if succeeded { return Pal.green }
        return Pal.overlay
    }

    func start(conn: SSHConnection) {
        cancel()
        steps = stepTitles.map { ConnectionStep(title: $0) }
        logs = []
        isRunning = true
        failed = false
        failureMessage = nil
        cancelled = false
        concluded = false

        guard !conn.host.isEmpty else {
            log(String(localized: "未填写主机地址"), color: Pal.red)
            failStep(0); return
        }

        guard (1...65535).contains(conn.port) else {
            log(String(localized: "端口需为 1–65535 之间的整数。"), color: Pal.red)
            failStep(0); return
        }
        markRunning(0)
        log(String(localized: "开始测试连接到 \(conn.host):\(conn.port)（用户 \(conn.user)）"))
        markSuccess(0)
        markRunning(1)

        let generation = connectionGeneration
        preflightTask = Task {
            let result = await Task.detached {
                HostKeyVerifier.preflight(host: conn.host, port: conn.port)
            }.value
            guard !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
            switch result {
            case .known: break
            case .scanFailed:
                log(String(localized: "无法核对主机指纹，请检查网络连接和 known_hosts 记录。"), color: Pal.red)
                failStep(3)
                return
            case .prompt(let info), .changed(let info):
                let decision = await withCheckedContinuation { continuation in
                    trustContinuation = continuation
                    pendingHostKey = PendingHostKey(info: info) { [weak self] decision in
                        guard self?.connectionGeneration == generation else { return }
                        self?.resolveHostKey(decision)
                    }
                }
                guard !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
                guard decision != .cancel else { cancel(); return }
                do { try HostKeyVerifier.trust(info, persist: decision == .save) }
                catch {
                    log(String(localized: "主机信任记录未能保存：\(error.localizedDescription)"), color: Pal.red)
                    failStep(3)
                    return
                }
            }
            guard !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
            connect(conn: conn, generation: generation)
        }
    }

    private func resolveHostKey(_ decision: HostKeyDecision) {
        let continuation = trustContinuation
        trustContinuation = nil
        pendingHostKey = nil
        continuation?.resume(returning: decision)
    }

    private func connect(conn: SSHConnection, generation: UUID) {
        // [SSH 引擎] 进程内分阶段测试（替代 spawn ssh -v）：连接由 App 进程发起，
        // 触发 macOS 本地网络权限弹窗，且内网主机不再因子进程发起连接而被静默拦截。
        let isKey = conn.authMethod == .key
        let keyPath: String? = isKey
            ? (conn.keyId.isEmpty ? (conn.keyPath.isEmpty ? nil : conn.keyPath) : KeyMaterializer.path(forKeyId: conn.keyId))
            : nil
        guard !isKey || keyPath?.isEmpty == false else {
            log(String(localized: "无法读取所选私钥，请重新选择密钥库条目或私钥文件。"), color: Pal.red)
            failStep(4)
            return
        }
        let password: String? = isKey ? nil : conn.password
        let keyPass: String? = isKey ? conn.password : nil
        let (h, p, u) = (conn.host, conn.port, conn.user)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let box = Unmanaged.passRetained(StageBox { stage, ok, msg in
                Task { @MainActor in
                    guard self?.connectionGeneration == generation else { return }
                    self?.onStage(stage: stage, ok: ok, message: msg)
                }
            }).toOpaque()
            termo_ssh_test(h, Int32(p), u, password, keyPath, keyPass,
                           HostKeyVerifier.realKnownHosts, HostKeyVerifier.sessionKnownHosts, { ud, stage, ok, msg in
                guard let ud else { return }
                let b = Unmanaged<StageBox>.fromOpaque(ud).takeUnretainedValue()
                b.cb(Int(stage), ok != 0, msg.map { String(cString: $0) })
            }, box)
            Unmanaged<StageBox>.fromOpaque(box).release()
        }
    }

    func cancel() {
        connectionGeneration = UUID()
        preflightTask?.cancel(); preflightTask = nil
        resolveHostKey(.cancel)
        cancelled = true   // 后台引擎测试会在超时后自行结束；这里停止后续 UI 更新
        for index in steps.indices where steps[index].state == .running { steps[index].state = .pending }
        isRunning = false
    }

    /// 引擎分阶段回调（C stage 1..5 ↔ UI 步骤 1..5）。
    private func onStage(stage: Int, ok: Bool, message: String?) {
        guard isRunning, !cancelled, stage >= 1, stage < steps.count else { return }
        if let message, !message.isEmpty { log(message, color: ok ? Pal.subtext : Pal.red) }
        if ok {
            markSuccess(stage)
            if stage == steps.count - 1 {          // 末阶段「连接成功」
                log(String(localized: "连接成功 ✓"), color: Pal.green)
                isRunning = false
                conclude(true)
            } else {
                markRunning(stage + 1)
            }
        } else {
            failStep(stage)                        // 置失败 + 结束（内部 conclude(false)）
        }
    }

    // MARK: - 步骤状态

    private func markRunning(_ i: Int) {
        guard i < steps.count, steps[i].state == .pending else { return }
        steps[i].state = .running
    }
    private func markSuccess(_ i: Int) {
        guard i < steps.count, steps[i].state != .success else { return }
        steps[i].state = .success
    }
    private func failStep(_ i: Int) {
        guard i < steps.count else { return }
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = .pending
        }
        steps[i].state = .failure
        failureMessage = logs.last?.message ?? String(localized: "连接未完成，请查看日志后重试。")
        failed = true
        isRunning = false
        cancel()
        conclude(false)
    }

    private func log(_ message: String, color: Color = Pal.subtext) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        logs.append(ConnectionLog(time: fmt.string(from: Date()), message: message, color: color))
    }
}
