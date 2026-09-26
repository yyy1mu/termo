import SwiftTerm
import SwiftUI
import TermoCore
import TermoEngine
import UIKit

/// iOS 终端页的连接编排：密码询问（「每次询问」）→ 主机指纹核对 → 开壳 → 掉线自动重连。
/// 结构参照 macOS 的 TerminalSessionController + HostTrustCoordinator，按 iOS 单页生命周期简化。
@MainActor
final class IOSTerminalViewModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case connecting       // 指纹核对与建连中
        case live             // 已连接
        case dropped          // 掉线（255），自动重连中
        case failed(String)   // 失败/已结束，可手动重连
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var reconnecting = false
    @Published var pendingHostKey: IOSHostKeyInfo?
    @Published var showPasswordPrompt = false
    @Published private(set) var terminalTitle = ""

    let host: IOSHost

    /// 工作副本：会话密码只存在于内存（「每次询问」不落盘）。
    private var connection: SSHConnection
    private var channel: IOSTerminalSession?
    private weak var terminalView: TerminalView?
    /// 代际令牌：重连/关闭后，旧通道迟到的回调不再写终端。
    private var generation = UUID()
    private var reconnectTask: Task<Void, Never>?
    private var gate: Gate?
    private var attempt = 0       // 连续重连失败的退避代数，连上后清零
    private var closed = false

    init(host: IOSHost) {
        self.host = host
        self.connection = host.ssh
        super.init()
    }

    func attach(_ tv: TerminalView) {
        terminalView = tv
    }

    // MARK: - 连接流程

    func start() {
        guard channel == nil, !closed else { return }
        // 「每次询问」且本会话尚未输入密码 → 先弹密码框。
        if connection.authMethod == .ask, connection.password.isEmpty {
            showPasswordPrompt = true
            return
        }
        verifyHostKey()
    }

    /// 密码框提交：空密码视为取消。
    func submitPassword(_ password: String) {
        showPasswordPrompt = false
        guard !password.isEmpty else {
            phase = .failed(String(localized: "已取消连接"))
            return
        }
        connection.password = password
        verifyHostKey()
    }

    func cancelPasswordPrompt() {
        showPasswordPrompt = false
        phase = .failed(String(localized: "已取消连接"))
    }

    private func verifyHostKey() {
        phase = .connecting
        let conn = connection
        let gen = generation
        Task {
            let result = await IOSHostKeyVerifier.preflight(connection: conn)
            guard !closed, generation == gen else { return }
            switch result {
            case .known:
                openShell()
            case .prompt(let info), .changed(let info):
                pendingHostKey = info
            case .scanFailed:
                let cause = await Task.detached { IOSHostKeyVerifier.diagnose(connection: conn) }.value
                guard !closed, generation == gen else { return }
                phase = .failed(cause.map {
                    String(localized: "无法核对主机指纹：\($0)")
                } ?? String(localized: "无法核对主机指纹，请检查网络连接后重试。"))
            }
        }
    }

    /// 指纹弹窗「信任并连接」：写入持久 known_hosts 后继续。
    func trustHostKey() {
        guard let info = pendingHostKey else { return }
        pendingHostKey = nil
        do {
            try IOSHostKeyVerifier.trust(info)
        } catch {
            phase = .failed(String(localized: "主机信任记录未能保存：\(error.localizedDescription)"))
            return
        }
        openShell()
    }

    func cancelHostKey() {
        pendingHostKey = nil
        phase = .failed(String(localized: "已取消连接"))
    }

    private func openShell() {
        reconnecting = true
        let conn = connection
        let hub = SSHSessionPool.shared.connectionHub(for: conn)
        let gen = generation
        let gate = Gate()
        self.gate = gate
        let cols = terminalView?.getTerminal().cols ?? 80
        let rows = terminalView?.getTerminal().rows ?? 24
        let callbacks = IOSTerminalSession.Callbacks(
            isActive: { gate.isActive },
            output: { [weak self] bytes in
                DispatchQueue.main.async {
                    guard let self, !self.closed, self.generation == gen else { return }
                    self.terminalView?.feed(byteArray: bytes[...])
                }
            },
            ended: { [weak self] code in
                DispatchQueue.main.async { self?.didEnd(code: code, generation: gen) }
            })
        Task.detached { [weak self] in
            let result = Result {
                try IOSTerminalSession.open(
                    connection: conn, hub: hub, cols: cols, rows: rows, callbacks: callbacks)
            }
            await MainActor.run { [weak self] in
                guard let self, !self.closed, self.generation == gen else {
                    // 页面已关闭/已被新通道取代：迟到的通道不能泄露。
                    if let channel = try? result.get() {
                        DispatchQueue.global(qos: .utility).async {
                            channel.close(reportingDisconnect: false)
                        }
                    }
                    return
                }
                switch result {
                case .success(let channel):
                    self.channel = channel
                    self.phase = .live
                    self.reconnecting = false
                    self.attempt = 0
                case .failure(let error):
                    self.reconnecting = false
                    let msg = (error as? SSHSession.SSHError)?.message ?? error.localizedDescription
                    self.phase = .failed(msg)
                }
            }
        }
    }

    /// shell 结束回调（pump 线程 → 已切主线程）：255=掉线走自动重连；其余为远端正常退出。
    private func didEnd(code: Int32, generation gen: UUID) {
        guard !closed, generation == gen else { return }
        channel = nil
        reconnecting = false
        if code == 255 {
            phase = .dropped
            scheduleReconnect()
        } else {
            phase = .failed(String(localized: "远端会话已结束（退出码 \(code)）"))
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        attempt += 1
        let delay = min(pow(2.0, Double(attempt - 1)) * 2, 30)   // 2, 4, 8, …, 30s 封顶
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // 自动重连直接建连：known_hosts 已核对，凭证仍在会话内存。
            self.openShell()
        }
    }

    /// 覆盖层「立即重连」：失败态回到完整流程（重新核对指纹），掉线态跳过等待立即建连。
    func reconnectNow() {
        reconnectTask?.cancel()
        if phase == .dropped {
            openShell()
        } else {
            attempt = 0
            verifyHostKey()
        }
    }

    func close() {
        closed = true
        generation = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingHostKey = nil
        showPasswordPrompt = false
        gate?.close()
        gate = nil
        let channel = channel
        self.channel = nil
        if let channel {
            DispatchQueue.global(qos: .utility).async { channel.close(reportingDisconnect: false) }
        }
    }

    /// 线程安全的存活门闩：建连回调在后台线程读它。
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
        func close() { lock.lock(); active = false; lock.unlock() }
    }
}

// MARK: - TerminalViewDelegate（SwiftTerm 主线程回调 → 引擎 shell 通道）

extension IOSTerminalViewModel: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in self.channel?.write(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor in self.channel?.resize(cols: newCols, rows: newRows) }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        UIPasteboard.general.string = s
    }

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        Task { @MainActor in UIApplication.shared.open(url) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in self.terminalTitle = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
