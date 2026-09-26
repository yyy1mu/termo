import SwiftUI
import TermoCore

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
    var successHint: String = String(localized: "正在进入终端…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)   // 成功后的提示，按动作变化（终端/文件/转发/监控）
    let onConnected: () -> Void
    let onCancel: () -> Void
    @StateObject private var tester = ConnectionTester()
    @ObservedObject private var theme = ThemeManager.shared
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

                    ConnectionProgressView(tester: tester, targetLabel: targetLabel)

                    Rectangle().fill(Pal.fill(0.06)).frame(height: 1)
                    HStack {
                        Spacer()
                        if tester.isRunning {
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
            // The tester performs one fingerprint preflight before sending credentials.
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { tester.start(conn: host.ssh ?? SSHConnection()) }
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

    private var targetLabel: String {
        guard let s = host.ssh else { return host.addr }
        let u = s.user.isEmpty ? "" : "\(s.user)@"
        let address = s.host.contains(":") ? "[\(s.host)]" : s.host
        return "\(u)\(address):\(s.port)"
    }
}
