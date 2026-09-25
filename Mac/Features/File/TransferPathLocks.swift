import Foundation

/// FIFO destination leases. Cancellation removes a waiter without releasing somebody else's lease.
@MainActor
final class TransferPathLocks {
    private struct Waiter {
        let owner: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var owners: [String: UUID] = [:]
    private var waiters: [String: [Waiter]] = [:]

    func acquire(_ path: String, owner: UUID) async -> Bool {
        if tryAcquire(path, owner: owner) { return true }
        return await withCheckedContinuation { continuation in
            waiters[path, default: []].append(Waiter(owner: owner, continuation: continuation))
        }
    }

    /// Used by best-effort cleanup: never wait to delete another in-flight upload's partial file.
    func tryAcquire(_ path: String, owner: UUID) -> Bool {
        guard owners[path] == nil || owners[path] == owner else { return false }
        owners[path] = owner
        return true
    }

    func release(_ path: String, owner: UUID) {
        guard owners[path] == owner else { return }
        if var pending = waiters.removeValue(forKey: path), !pending.isEmpty {
            let next = pending.removeFirst()
            if !pending.isEmpty { waiters[path] = pending }
            owners[path] = next.owner
            next.continuation.resume(returning: true)
        } else {
            owners[path] = nil
        }
    }

    func cancelWaiting(owner: UUID) {
        for path in Array(waiters.keys) {
            let cancelled = waiters[path, default: []].filter { $0.owner == owner }
            let remaining = waiters[path, default: []].filter { $0.owner != owner }
            waiters[path] = remaining.isEmpty ? nil : remaining
            for waiter in cancelled { waiter.continuation.resume(returning: false) }
        }
    }
}
