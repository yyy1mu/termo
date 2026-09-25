import SwiftUI

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
    private var cancellation: SSHConnectionCancellation?
    private let preflight: (SSHConnection, SSHConnectionCancellation) async -> HostKeyVerifier.Preflight
    private let runTest: SSHConnectionDiagnostic.Run

    init(
        preflight: @escaping (SSHConnection, SSHConnectionCancellation) async -> HostKeyVerifier.Preflight = {
            await HostKeyVerifier.preflight(connection: $0, cancellation: $1)
        }, runTest: @escaping SSHConnectionDiagnostic.Run = SSHConnectionDiagnostic.live
    ) {
        self.preflight = preflight
        self.runTest = runTest
    }

    deinit { cancellation?.cancel() }

    private let stepTitles = [
        String(localized: "初始化配置"),
        String(localized: "解析连接地址"),
        String(localized: "建立连接通道"),
        String(localized: "SSH 协议握手"),
        String(localized: "身份验证"),
        String(localized: "连接成功"),
    ]
    private var concluded = false
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
        let cancellation = SSHConnectionCancellation()
        self.cancellation = cancellation
        let preflight = self.preflight
        preflightTask = Task { [weak self] in
            let result = await preflight(conn, cancellation)
            guard let self, !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
            switch result {
            case .known: break
            case .scanFailed:
                log(String(localized: "无法核对主机指纹，请检查网络连接和 known_hosts 记录。"), color: Pal.red)
                failStep(3)
                return
            case .prompt(let info), .changed(let info):
                let decision = await withCheckedContinuation { continuation in
                    self.trustContinuation = continuation
                    self.pendingHostKey = PendingHostKey(info: info) { [weak self] decision in
                        guard self?.connectionGeneration == generation else { return }
                        self?.resolveHostKey(decision)
                    }
                }
                guard !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
                guard decision != .cancel else { cancel(); return }
                do { try HostKeyVerifier.trust(info, persist: decision == .save) } catch {
                    log(String(localized: "主机信任记录未能保存：\(error.localizedDescription)"), color: Pal.red)
                    failStep(3)
                    return
                }
            }
            guard !Task.isCancelled, generation == connectionGeneration, isRunning else { return }
            connect(conn: conn, generation: generation, cancellation: cancellation)
        }
    }

    private func resolveHostKey(_ decision: HostKeyDecision) {
        let continuation = trustContinuation
        trustContinuation = nil
        pendingHostKey = nil
        continuation?.resume(returning: decision)
    }

    private func connect(conn: SSHConnection, generation: UUID, cancellation: SSHConnectionCancellation) {
        // [SSH 引擎] 进程内分阶段测试（替代 spawn ssh -v）：连接由 App 进程发起，
        // 触发 macOS 本地网络权限弹窗，且内网主机不再因子进程发起连接而被静默拦截。
        let isKey = conn.authMethod == .key
        let keyPath: String? =
            isKey
            ? (conn.keyId.isEmpty
                ? (conn.keyPath.isEmpty ? nil : conn.keyPath) : KeyMaterializer.path(forKeyId: conn.keyId))
            : nil
        guard !isKey || keyPath?.isEmpty == false else {
            log(String(localized: "无法读取所选私钥，请重新选择密钥库条目或私钥文件。"), color: Pal.red)
            failStep(4)
            return
        }
        let runTest = self.runTest
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            runTest(conn, keyPath, cancellation) { [weak self] stage, ok, message in
                Task { @MainActor [weak self] in
                    guard self?.connectionGeneration == generation else { return }
                    self?.onStage(stage: stage, ok: ok, message: message)
                }
            }
        }
    }

    func cancel() {
        connectionGeneration = UUID()
        cancellation?.cancel(); cancellation = nil
        preflightTask?.cancel(); preflightTask = nil
        resolveHostKey(.cancel)
        cancelled = true
        for index in steps.indices where steps[index].state == .running { steps[index].state = .pending }
        isRunning = false
    }

    /// 引擎分阶段回调（C stage 1..5 ↔ UI 步骤 1..5）。
    private func onStage(stage: Int, ok: Bool, message: String?) {
        guard isRunning, !cancelled, stage >= 1, stage < steps.count else { return }
        if let message, !message.isEmpty { log(message, color: ok ? Pal.subtext : Pal.red) }
        if ok {
            markSuccess(stage)
            if stage == steps.count - 1 {  // 末阶段「连接成功」
                log(String(localized: "连接成功 ✓"), color: Pal.green)
                isRunning = false
                conclude(true)
            } else {
                markRunning(stage + 1)
            }
        } else {
            failStep(stage)  // 置失败 + 结束（内部 conclude(false)）
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
