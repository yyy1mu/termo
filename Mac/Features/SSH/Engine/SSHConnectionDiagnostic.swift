import Foundation

/// Synchronous engine boundary; only call on a background queue.
enum SSHConnectionDiagnostic {
    typealias Stage = @Sendable (Int, Bool, String?) -> Void
    typealias Run = @Sendable (SSHConnection, String?, SSHConnectionCancellation, @escaping Stage) -> Void

    static let live: Run = { connection, keyPath, cancellation, report in
        run(connection: connection, keyPath: keyPath, cancellation: cancellation, report: report)
    }

    private final class StageBox {
        let report: Stage
        init(_ report: @escaping Stage) { self.report = report }
    }

    static func run(
        connection: SSHConnection, keyPath: String?,
        cancellation: SSHConnectionCancellation, report: @escaping Stage
    ) {
        let options: SSHTransportOptions
        do { options = try SSHTransportOptions(connection) } catch {
            report(1, false, error.localizedDescription)
            return
        }
        let box = Unmanaged.passRetained(StageBox(report)).toOpaque()
        defer { Unmanaged<StageBox>.fromOpaque(box).release() }
        let isKey = connection.authMethod == .key
        options.withRawOptions { rawOptions in
            termo_ssh_test(
                connection.host, Int32(connection.port), connection.user,
                isKey ? nil : connection.password, keyPath, isKey ? connection.password : nil,
                HostKeyVerifier.realKnownHosts, HostKeyVerifier.sessionKnownHosts,
                cancellation.handle, rawOptions,
                { userdata, stage, ok, message in
                    guard let userdata else { return }
                    let box = Unmanaged<StageBox>.fromOpaque(userdata).takeUnretainedValue()
                    box.report(Int(stage), ok != 0, message.map { String(cString: $0) })
                }, box)
        }
    }
}
