import CTermoSSH
import Foundation
import TermoCore

/// Synchronous engine boundary; only call on a background queue.
public enum SSHConnectionDiagnostic {
    public typealias Stage = @Sendable (Int, Bool, String?) -> Void
    /// known_hosts 路径随 environment 由平台层传入（引擎不引用 HostKeyVerifier 等平台单例）。
    public typealias Run = @Sendable (SSHConnection, String?, SSHConnectionCancellation, SSHConnectionEnvironment, @escaping Stage) -> Void

    public static let live: Run = { connection, keyPath, cancellation, environment, report in
        run(connection: connection, keyPath: keyPath, cancellation: cancellation,
            environment: environment, report: report)
    }

    private final class StageBox {
        let report: Stage
        init(_ report: @escaping Stage) { self.report = report }
    }

    public static func run(
        connection: SSHConnection, keyPath: String?,
        cancellation: SSHConnectionCancellation,
        environment: SSHConnectionEnvironment,
        report: @escaping Stage
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
                environment.realKnownHosts, environment.sessionKnownHosts,
                cancellation.handle, rawOptions,
                { userdata, stage, ok, message in
                    guard let userdata else { return }
                    let box = Unmanaged<StageBox>.fromOpaque(userdata).takeUnretainedValue()
                    box.report(Int(stage), ok != 0, message.map { String(cString: $0) })
                }, box)
        }
    }
}
