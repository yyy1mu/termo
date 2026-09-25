import Foundation

/// Owns the FFI shell and its borrowed session together. The controller releases this resource off-main.
final class SSHTerminalChannel: TerminalChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var shell: OpaquePointer?
    private let session: SSHSession
    private let hub: SSHConnectionHub
    private let encoding: TerminalEncodingCodec

    private init(shell: OpaquePointer, session: SSHSession, hub: SSHConnectionHub,
                 encoding: TerminalEncodingCodec) {
        self.shell = shell
        self.session = session
        self.hub = hub
        self.encoding = encoding
    }

    static func open(
        connection: SSHConnection, hub: SSHConnectionHub, cols: Int, rows: Int,
        command: String?, callbacks: TerminalSessionController.Callbacks
    ) throws -> SSHTerminalChannel {
        guard callbacks.isActive() else { throw CancellationError() }
        let encoding = try TerminalEncodingCodec(name: connection.encoding)
        let session = try hub.acquire(connection)
        guard callbacks.isActive(), let raw = session.rawHandle else {
            session.close()
            throw CancellationError()
        }
        let box = Unmanaged.passRetained(CallbackBox(callbacks, encoding: encoding)).toOpaque()
        var error = [CChar](repeating: 0, count: 256)
        guard
            let shell = termo_ssh_shell_open(
                raw, Int32(cols), Int32(rows), command,
                onData, onClosed, box, &error, 256)
        else {
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            hub.invalidate(session)
            session.close()
            throw SSHSession.SSHError(message: String(cString: error))
        }
        return SSHTerminalChannel(shell: shell, session: session, hub: hub, encoding: encoding)
    }

    func write(_ bytes: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let shell, !bytes.isEmpty else { return false }
        let encoded = encoding.encode(bytes)
        guard !encoded.isEmpty else { return true }
        return encoded.withUnsafeBufferPointer { buffer in
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
        let callbacks: TerminalSessionController.Callbacks
        let encoding: TerminalEncodingCodec
        init(_ callbacks: TerminalSessionController.Callbacks, encoding: TerminalEncodingCodec) {
            self.callbacks = callbacks
            self.encoding = encoding
        }
    }

    private static let onData: TermoSSHDataCallback = { userData, bytes, count in
        guard let userData, let bytes, count > 0 else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
        let chunk = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(count)) {
            Array(UnsafeBufferPointer(start: $0, count: Int(count)))
        }
        box.callbacks.output(box.encoding.decode(chunk))
    }

    private static let onClosed: TermoSSHClosedCallback = { userData, code in
        guard let userData else { return }
        // A successful shell open transfers this retained box to the pump, which closes exactly once.
        let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeRetainedValue()
        box.callbacks.ended(code)
    }
}
