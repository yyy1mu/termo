import Foundation

/// Owns one lazily created session. Late failures may retire only the session they actually used.
/// Creation must be cheap (no network I/O); retirement runs outside the storage lock.
final class RemoteSFTPStore<Session: AnyObject & Sendable>: @unchecked Sendable {
    private enum State {
        case available(Session?)
        case unavailable
    }

    private let lock = NSLock()
    private var state: State = .available(nil)
    private let create: @Sendable () -> Session
    private let retire: @Sendable (Session) -> Void

    init(create: @escaping @Sendable () -> Session, retire: @escaping @Sendable (Session) -> Void) {
        self.create = create
        self.retire = retire
    }

    deinit {
        if case .available(let session?) = state { retire(session) }
    }

    /// Availability and creation are one decision; callers cannot race a separate availability check.
    func acquire() -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard case .available(let current) = state else { return nil }
        if let current { return current }
        let session = create()
        state = .available(session)
        return session
    }

    /// Returns false for a retired session, including a delayed error after close or reconnect.
    @discardableResult
    func markUnavailable(ifCurrent session: Session) -> Bool {
        lock.lock()
        guard case .available(let current?) = state, current === session else {
            lock.unlock()
            return false
        }
        state = .unavailable
        lock.unlock()
        retire(session)
        return true
    }

    /// Release resources while retaining the current transport policy (including shell fallback).
    func close() { detach(reset: false) }

    /// Network recovery permits SFTP again, but does not connect until the next request.
    func reset() { detach(reset: true) }

    private func detach(reset: Bool) {
        let old: Session?
        lock.lock()
        switch state {
        case .available(let session):
            old = session
            state = .available(nil)
        case .unavailable:
            old = nil
            if reset { state = .available(nil) }
        }
        lock.unlock()
        if let old { retire(old) }
    }
}
