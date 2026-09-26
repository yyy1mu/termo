import CTermoSSH
import Foundation
import TermoCore
import TermoEngine

/// 一个终端标签的 SSH shell 通道：持有引擎 FFI shell 与其借用的操作句柄。
/// 结构参照 macOS 的 SSHTerminalChannel，但面向 iOS 自带最小回调（无转录/编码转换——远端按 UTF-8）。
final class IOSTerminalSession: @unchecked Sendable {
    struct Callbacks: Sendable {
        let isActive: @Sendable () -> Bool
        let output: @Sendable ([UInt8]) -> Void
        let ended: @Sendable (Int32) -> Void
    }

    private let lock = NSLock()
    private var shell: OpaquePointer?
    private let session: SSHSession
    private let hub: SSHConnectionHub

    private init(shell: OpaquePointer, session: SSHSession, hub: SSHConnectionHub) {
        self.shell = shell
        self.session = session
        self.hub = hub
    }

    /// 同步阻塞（建连 + 开 PTY），务必在后台调用。
    static func open(
        connection: SSHConnection, hub: SSHConnectionHub, cols: Int, rows: Int,
        callbacks: Callbacks
    ) throws -> IOSTerminalSession {
        guard callbacks.isActive() else { throw CancellationError() }
        let session = try hub.acquire(connection)
        guard callbacks.isActive(), let raw = session.rawHandle else {
            session.close()
            throw CancellationError()
        }
        let box = Unmanaged.passRetained(CallbackBox(callbacks)).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        guard
            let shell = termo_ssh_shell_open(
                raw, Int32(cols), Int32(rows), nil,
                onData, onClosed, box, &error, 256)
        else {
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            hub.invalidate(session)
            session.close()
            throw SSHSession.SSHError(message: String(cString: error))
        }
        return IOSTerminalSession(shell: shell, session: session, hub: hub)
    }

    func write(_ bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let shell, !bytes.isEmpty else { return false }
        return bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                termo_ssh_shell_write(shell, $0, Int32(buffer.count)) == buffer.count
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let shell else { return }
        _ = termo_ssh_shell_resize(shell, Int32(cols), Int32(rows))
    }

    func close(reportingDisconnect: Bool) {
        lock.lock()
        let shell = self.shell
        self.shell = nil
        lock.unlock()
        guard let shell else { return }
        if reportingDisconnect { hub.invalidate(session) }
        termo_ssh_shell_close(shell)
        session.close()
    }

    deinit { close(reportingDisconnect: false) }

    private final class CallbackBox {
        let callbacks: Callbacks
        init(_ callbacks: Callbacks) { self.callbacks = callbacks }
    }

    private static let onData: TermoSSHDataCallback = { userData, bytes, count in
        guard let userData, let bytes, count > 0 else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
        let chunk = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(count)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(count)))
        }
        box.callbacks.output(chunk)
    }

    private static let onClosed: TermoSSHClosedCallback = { userData, code in
        guard let userData else { return }
        // 成功开壳后这个 retain 的 box 移交 pump，由其保证恰好关闭一次。
        let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeRetainedValue()
        box.callbacks.ended(code)
    }
}
