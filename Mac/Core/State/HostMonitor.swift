import SwiftUI
import TermoEngine
import TermoCore

/// 每台主机一份运行状态，由终端设置控制；采集使用共享 SSH 传输上的独立 exec 通道。
/// 离开面板不停止，用户停止或删除主机时只释放监控通道，不影响终端和文件。
@MainActor
final class HostMonitor: ObservableObject {
    enum Phase: Equatable { case stopped, connecting, live, unsupported, error }

    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var errorMessage: String?
    @Published private(set) var trustBlocked = false
    @Published private(set) var verifiedFingerprint: String?
    @Published private(set) var netHistory: [NetSample] = []   // 最近若干帧网速，供波动折线图
    @Published private(set) var netHistoryByInterface: [String: [NetSample]] = [:]
    @Published private(set) var netTick = 0                    // 每追加一帧自增，驱动折线整条左滑一格

    /// 每解析出一帧调用一次，供上层做阈值告警；监控本身只产数据、不判定告警。
    var onSample: ((HostMetrics) -> Void)?

    private var ssh: SSHConnection
    private var session: SSHSession?     // 本监控独占操作句柄，底层传输共享
    private var launchGen = 0            // 每次 launch 自增；旧连接的回调据此失效（替代 Process 的 terminationHandler=nil）
    private let parser = HostMetricsParser()   // 采样帧解析（含上一帧计数器与网速历史），与 iOS 共用
    @Published private(set) var isEnabled = false
    @Published private(set) var monitoringAllowed: Bool
    private var restartWork: DispatchWorkItem?


    /// 一帧采样的间隔秒数；供折线图把左滑动画时长对齐采样节奏，保证连续不顿挫。
    var sampleInterval: Double { Double(HostMonitorScript.interval) }

    init(ssh: SSHConnection) {
        self.ssh = ssh
        self.monitoringAllowed = ssh.monitoringEnabled ?? true
    }

    /// 兜底回收：正常流程靠 stop() 清理。万一对象未 stop 即被释放（如所有者将来漏调 stop），
    /// 远端采样脚本是 `while :; sleep` 永不自行结束 —— 这里必须打断流（cancel 线程安全），
    /// 否则后台阻塞线程 + TCP 连接 + 远端进程会永久泄漏。
    deinit {
        session?.cancel()
        restartWork?.cancel()
    }

    /// 用最新连接信息刷新（如「每次询问」先输错密码、缓存的监控仍持旧密码，改对后需更新）。
    /// 关键字段变化时若正在运行则立即用新信息重连，避免缓存的监控一直用旧/错密码连接失败。
    func updateConnection(_ s: SSHConnection) {
        let targetChanged = s.host != ssh.host || s.port != ssh.port
        let changed = s.password != ssh.password || s.host != ssh.host
            || s.port != ssh.port || s.user != ssh.user || s.keyId != ssh.keyId || s.keyPath != ssh.keyPath
            || s.authMethod != ssh.authMethod
        ssh = s
        monitoringAllowed = s.monitoringEnabled ?? true
        if targetChanged {
            parser.clear()
            metrics = nil; netHistory = []; netHistoryByInterface = [:]; verifiedFingerprint = nil
            trustBlocked = false; errorMessage = nil
        }
        guard monitoringAllowed else { stop(); return }
        guard changed, isEnabled else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    func start(allowTrustRetry: Bool = false) {
        guard monitoringAllowed, !isEnabled else { return }
        guard !trustBlocked || allowTrustRetry else { phase = .error; return }
        guard !ssh.host.isEmpty else { phase = .unsupported; return }
        isEnabled = true
        phase = .connecting
        launch()
    }

    func stop() {
        isEnabled = false
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        parser.reset()
        phase = .stopped
        if !trustBlocked { errorMessage = nil }
    }

    /// 网络切换时调用：立刻丢弃当前连接重连，不等 keepalive 超时。
    /// launch 内部已对离线自守，离线则置 error 等下次网络恢复再连。
    func handleNetworkChange() {
        guard isEnabled else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    private func teardownProcess() {
        launchGen &+= 1        // 使旧 stream 的回调（ingest/结束重连）失效
        session?.cancel()      // 打断流；其后台线程会自行 close 收尾
        session = nil
    }

    private func launch() {
        // 离线时不发起连接，等网络恢复由 handleNetworkChange 触发重连，避免离线期间空转重试。
        guard NetworkMonitor.shared.isOnline else { phase = .error; return }
        let cmd = HostMonitorScript.command
        errorMessage = nil
        trustBlocked = false
        // 统一入口会在首次认证前验证指纹；复用时继承已验证连接。
        let connection = ssh

        parser.reset()
        launchGen &+= 1
        let gen = launchGen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let session: SSHSession
            do {
                session = try SSHSessionPool.shared.acquireOperation(for: connection)
            } catch {
                Task { @MainActor in self?.connectionFailed(error, gen: gen) }
                return
            }
            Task { @MainActor in
                guard let self else { session.cancel(); return }
                self.adoptSession(session, gen: gen)
            }
            session.execStream(cmd) { data in                        // 同步阻塞直到 cancel/EOF
                Task { @MainActor in guard gen == self?.launchGen else { return }; self?.ingest(data) }
            }
            session.close()                                          // 只归还监控操作，不断开其他通道
            Task { @MainActor in self?.streamEnded(gen: gen) }
        }
    }

    /// 后台线程连上后回主线程认领会话；若此次 launch 已被取代/停止则就地取消。
    private func adoptSession(_ s: SSHSession, gen: Int) {
        if gen == launchGen {
            session = s
            verifiedFingerprint = s.fingerprintSHA256
        } else { s.cancel() }
    }

    private func connectionFailed(_ error: Error, gen: Int) {
        guard gen == launchGen, isEnabled else { return }
        phase = .error
        errorMessage = error.localizedDescription
        trustBlocked = (error as? SSHSession.SSHError)?.isHostKeyFailure == true
        if trustBlocked {
            // 未知/变更指纹需要明确确认；网络恢复不能自动绕过或反复重试。
            isEnabled = false
            restartWork?.cancel(); restartWork = nil
        } else { scheduleRestart() }
    }

    /// 流结束（EOF/错误/连接失败）。仅当前代际有效；我方未停止则延迟重连。
    private func streamEnded(gen: Int) {
        guard gen == launchGen else { return }   // 已被新 launch 取代 → 忽略
        session = nil
        guard isEnabled else { return }            // 我方主动停止，不重连
        phase = .error
        scheduleRestart()
    }

    /// 连接意外断开后延迟重连；用户停止后不再重试。
    private func scheduleRestart() {
        guard isEnabled, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            if self.isEnabled { self.phase = .connecting; self.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func ingest(_ data: Data) {
        for frame in parser.ingest(data) { apply(frame) }
    }

    /// 解析一帧（委托共享解析器；测试直接驱动此入口）。
    func parse(_ frame: String) {
        apply(parser.parse(frame))
    }

    private func apply(_ frame: HostMetricsParser.Frame) {
        switch frame {
        case .unsupported:
            phase = .unsupported
            isEnabled = false            // 远端无 /proc，已 exit，不再重连
        case .metrics(let m):
            metrics = m
            netHistory = parser.netHistory
            netHistoryByInterface = parser.netHistoryByInterface
            netTick = parser.netTick
            phase = .live
            onSample?(m)
        }
    }

}
