import Foundation
import TermoCore
import TermoEngine

/// iOS 主机监控：共享 SSH 传输上独占一条 exec 通道跑内联 /proc 采样循环。
/// 采样脚本与解析在 TermoEngine（HostMonitorScript/HostMetricsParser），与 macOS 完全一致；
/// 本类只负责生命周期（页面可见期间运行）与断线重连。参照 Mac/Core/State/HostMonitor.swift。
@MainActor
final class IOSHostMonitor: ObservableObject {
    enum Phase: Equatable {
        case stopped, connecting, live, unsupported
        case failed(String)
    }

    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var phase: Phase = .stopped

    private let connection: SSHConnection
    private var session: SSHSession?     // 本监控独占操作句柄，底层传输共享
    private let parser = HostMetricsParser()
    private var generation = UUID()      // 每次 launch 更换；旧流的回调据此失效
    private var restartTask: Task<Void, Never>?
    private var stopped = true

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// 兜底回收：远端采样脚本是 `while :; sleep` 永不自行结束，必须打断流避免泄漏。
    deinit {
        session?.cancel()
        restartTask?.cancel()
    }

    func start() {
        guard stopped, !connection.host.isEmpty else { return }
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        generation = UUID()
        restartTask?.cancel(); restartTask = nil
        session?.cancel()      // 打断流；其后台线程会自行 close 收尾
        session = nil
        phase = .stopped
    }

    private func launch() {
        parser.reset()
        phase = .connecting
        generation = UUID()
        let gen = generation
        let conn = connection
        Task.detached { [weak self] in
            let session: SSHSession
            do {
                session = try SSHSessionPool.shared.acquireOperation(for: conn)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.connectionFailed(error, gen: gen)
                }
                return
            }
            // 回主 actor 认领会话；若此次 launch 已被取代/停止则就地取消。
            let adopted = await MainActor.run { [weak self] () -> Bool in
                guard let self, !self.stopped, self.generation == gen else { return false }
                self.session = session
                return true
            }
            guard adopted else { session.cancel(); return }
            session.execStream(HostMonitorScript.command) { data in   // 同步阻塞直到 cancel/EOF
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.ingest(data)
                }
            }
            session.close()                                          // 只归还监控操作，不断开其他通道
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.streamEnded(gen: gen)
            }
        }
    }

    private func ingest(_ data: Data) {
        for frame in parser.ingest(data) {
            switch frame {
            case .unsupported:
                phase = .unsupported
                stopped = true           // 远端无 /proc，已 exit，不再重连
            case .metrics(let m):
                metrics = m
                phase = .live
            }
        }
    }

    private func connectionFailed(_ error: Error, gen: UUID) {
        guard gen == generation, !stopped else { return }
        if (error as? SSHSession.SSHError)?.isHostKeyFailure == true {
            // 未知/变更指纹需要明确确认；不自动重试，引导用户先连一次终端完成信任。
            stopped = true
            phase = .failed(String(localized: "主机指纹尚未信任。请先连接一次终端完成确认。"))
            return
        }
        phase = .failed(error.localizedDescription)
        scheduleRestart()
    }

    private func streamEnded(gen: UUID) {
        guard gen == generation else { return }
        session = nil
        guard !stopped else { return }
        phase = .failed(String(localized: "连接已断开"))
        scheduleRestart()
    }

    /// 连接意外断开后延迟重连；页面离开（stop）后不再重试。
    private func scheduleRestart() {
        guard !stopped, restartTask == nil else { return }
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, !Task.isCancelled, !self.stopped else { return }
            self.restartTask = nil
            self.launch()
        }
    }
}
