import CTermoSSH
import Foundation

/// A single attempt owns this token. Background calls retain it until Rust has returned,
/// so cancelling a replaced attempt can never free a token still in use or cancel its replacement.
public final class SSHConnectionCancellation: @unchecked Sendable {
    public let handle: OpaquePointer
    private let lock = NSLock()
    private var cancelled = false

    public init() {
        handle = termo_ssh_connection_cancellation_new()!
    }

    public var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            termo_ssh_connection_cancellation_cancel(handle)
        }
    }

    deinit {
        termo_ssh_connection_cancellation_free(handle)
    }
}
