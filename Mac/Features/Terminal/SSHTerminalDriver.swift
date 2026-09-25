import AppKit
import SwiftTerm

/// SwiftTerm UI adapter. Channel ownership, late callbacks and delayed setup belong to the session controller.
@MainActor
final class SSHTerminalDriver: NSObject, @preconcurrency TerminalViewDelegate {
    private let ssh: SSHConnection
    private let hub: SSHConnectionHub
    private let session: TerminalSessionController

    var onCwd: ((String) -> Void)?
    var onReady: (() -> Void)? {
        get { session.onReady }
        set { session.onReady = newValue }
    }
    var onTerminated: ((Int32) -> Void)? {
        get { session.onTerminated }
        set { session.onTerminated = newValue }
    }

    init(
        tv: LocalProcessTerminalView, ssh: SSHConnection, hub: SSHConnectionHub,
        transcript: TerminalTranscript? = nil
    ) {
        self.ssh = ssh
        self.hub = hub
        session = TerminalSessionController(transcript: transcript)
        super.init()
        session.onOutput = { [weak tv] bytes in tv?.feed(byteArray: bytes[...]) }
    }

    func connect(cols: Int, rows: Int, initialLine: String, command: String? = nil) {
        let connection = ssh, hub = hub
        let command = command.flatMap { $0.isEmpty ? nil : $0 }
        session.start(initialLine: command == nil ? initialLine : nil) { callbacks in
            try SSHTerminalChannel.open(
                connection: connection, hub: hub, cols: cols, rows: rows,
                command: command, callbacks: callbacks)
        }
    }

    func close() { session.close() }

    @discardableResult
    func sendText(_ text: String) -> Bool { session.send(Array(text.utf8)) }

    @discardableResult
    func sendInput(_ bytes: [UInt8]) -> Bool { session.send(bytes, recordInput: true) }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sendInput(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        session.resize(cols: newCols, rows: newRows)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard session.isActive else { return }
        if let p = TerminalSessionDelegate.parsePath(directory) { onCwd?(p) }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let s = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
