import Foundation

/// Each terminal owns one channel; closing it must not disconnect sibling channels on the shared transport.
protocol TerminalChannel: AnyObject, Sendable {
    func write(_ bytes: [UInt8]) -> Bool
    func resize(cols: Int, rows: Int)
    func close(reportingDisconnect: Bool)
}

private func releaseTerminalChannel(_ channel: any TerminalChannel, reportingDisconnect: Bool) {
    DispatchQueue.global(qos: .utility).async { channel.close(reportingDisconnect: reportingDisconnect) }
}

/// Owns one connection attempt. Main-actor state handles navigation and writes; the stream gate
/// prevents a cancelled pump from recording output even before the background open has returned.
@MainActor
final class TerminalSessionController {
    struct Callbacks: Sendable {
        let isActive: @Sendable () -> Bool
        let output: @Sendable ([UInt8]) -> Void
        let ended: @Sendable (Int32) -> Void
    }

    private enum Phase { case idle, opening, active, ended, closed }
    private var phase: Phase = .idle
    private var channel: (any TerminalChannel)?
    private var exitCode: Int32?
    private var openingTask: Task<Void, Never>?
    private let stream: OutputStream

    var onOutput: (([UInt8]) -> Void)?
    var onReady: (() -> Void)?
    var onTerminated: ((Int32) -> Void)?
    var isActive: Bool { phase == .active }

    init(transcript: TerminalTranscript? = nil) { stream = OutputStream(transcript: transcript) }

    func start(open: @escaping @Sendable (Callbacks) throws -> any TerminalChannel) {
        guard phase == .idle else { return }
        phase = .opening
        stream.beginSession()
        let callbacks = Callbacks(
            isActive: { [stream] in stream.isActive },
            output: { [weak self, stream] bytes in
                let clean = stream.receive(bytes)
                guard !clean.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.phase == .opening || self.phase == .active else { return }
                    self.onOutput?(clean)
                }
            },
            ended: { [weak self] code in
                DispatchQueue.main.async { self?.finish(code) }
            })
        openingTask = Task { [weak self] in
            let result = await Task.detached {
                Result {
                    guard callbacks.isActive() else { throw CancellationError() }
                    return try open(callbacks)
                }
            }.value
            guard let self else {
                if case .success(let channel) = result {
                    releaseTerminalChannel(channel, reportingDisconnect: false)
                }
                return
            }
            self.openingTask = nil
            switch result {
            case .success(let channel):
                guard self.phase == .opening else {
                    releaseTerminalChannel(channel, reportingDisconnect: self.exitCode == 255)
                    return
                }
                self.channel = channel
                self.phase = .active
                self.onReady?()
            case .failure:
                self.finish(255)
            }
        }
    }

    /// Stop receiving immediately. Joining the pump and returning its operation happens off the UI thread.
    func close() {
        guard phase != .closed else { return }
        phase = .closed
        stream.close()
        openingTask?.cancel()
        releaseChannel(reportingDisconnect: false)
    }

    @discardableResult
    func send(_ bytes: [UInt8], recordInput: Bool = false) -> Bool {
        guard isActive, !bytes.isEmpty, channel?.write(bytes) == true else { return false }
        if recordInput { stream.recordInput(bytes) }
        return true
    }

    func resize(cols: Int, rows: Int) {
        guard isActive else { return }
        channel?.resize(cols: cols, rows: rows)
    }

    private func finish(_ code: Int32) {
        guard phase == .opening || phase == .active else { return }
        phase = .ended
        exitCode = code
        stream.close()
        releaseChannel(reportingDisconnect: code == 255)
        onTerminated?(code)
    }

    private func releaseChannel(reportingDisconnect: Bool) {
        guard let channel else { return }
        self.channel = nil
        releaseTerminalChannel(channel, reportingDisconnect: reportingDisconnect)
    }

    deinit {
        stream.close()
        openingTask?.cancel()
        if let channel { releaseTerminalChannel(channel, reportingDisconnect: false) }
    }

    /// Lock scope includes transcript writes: close returns only after the last accepted write finishes.
    private final class OutputStream: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private let transcript: TerminalTranscript?

        init(transcript: TerminalTranscript?) { self.transcript = transcript }
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }

        func beginSession() { transcript?.beginSession() }
        func close() { lock.lock(); active = false; lock.unlock() }

        func receive(_ bytes: [UInt8]) -> [UInt8] {
            lock.lock(); defer { lock.unlock() }
            guard active else { return [] }
            if !bytes.isEmpty { transcript?.appendOutput(bytes) }
            return bytes
        }

        func recordInput(_ bytes: [UInt8]) { transcript?.appendInput(bytes) }
    }
}
