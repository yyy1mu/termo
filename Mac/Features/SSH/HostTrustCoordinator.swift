import Combine
import Foundation

struct PendingHostKey: Identifiable {
    let id: UUID
    let info: HostKeyInfo
    let respond: (HostKeyDecision) -> Void

    init(id: UUID = UUID(), info: HostKeyInfo, respond: @escaping (HostKeyDecision) -> Void) {
        self.id = id
        self.info = info
        self.respond = respond
    }
}

/// Coordinates explicit trust requests from saved hosts (such as a paused monitor).
/// ConnectionTester owns the equivalent lifecycle for its unsaved connection draft.
@MainActor
final class HostTrustCoordinator: ObservableObject {
    @Published private(set) var pending: PendingHostKey?
    private var active: (id: UUID, host: Host)?
    private var scanTask: Task<HostKeyVerifier.Preflight, Never>?
    private var continuation: CheckedContinuation<HostKeyDecision, Never>?
    private let currentHost: (String) -> Host?
    private let isUnlocked: () -> Bool
    private let preflight: (SSHConnection) async -> HostKeyVerifier.Preflight
    private let trust: (HostKeyInfo, Bool) throws -> Void

    init(currentHost: @escaping (String) -> Host?, isUnlocked: @escaping () -> Bool,
         preflight: @escaping (SSHConnection) async -> HostKeyVerifier.Preflight = { connection in
             await HostKeyVerifier.preflight(connection: connection)
         },
         trust: @escaping (HostKeyInfo, Bool) throws -> Void = { info, persist in
             try HostKeyVerifier.trust(info, persist: persist)
         }) {
        self.currentHost = currentHost
        self.isUnlocked = isUnlocked
        self.preflight = preflight
        self.trust = trust
    }

    func verify(_ host: Host) async throws -> Bool {
        guard active == nil, matchesCurrentHost(host), let connection = host.ssh,
              !connection.host.isEmpty, !Task.isCancelled else { return false }
        let id = UUID()
        active = (id, host)
        defer { cancel(id: id) }
        return try await withTaskCancellationHandler {
            let scan = Task { await preflight(connection) }
            scanTask = scan
            let result = await scan.value
            guard isCurrent(id), !Task.isCancelled else { return false }
            scanTask = nil
            switch result {
            case .known, .scanFailed:
                // A failed scan never grants trust. The real SSH handshake still verifies known_hosts.
                return true
            case .prompt(let info), .changed(let info):
                let decision = await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    pending = PendingHostKey(id: id, info: info) { [weak self] decision in
                        self?.resolve(id: id, decision: decision)
                    }
                }
                guard isCurrent(id), !Task.isCancelled, decision != .cancel else { return false }
                try trust(info, decision == .save)
                return true
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    func cancelAll() {
        guard let active else { return }
        cancel(id: active.id)
    }

    func reconcile() {
        guard let active, !matchesCurrentHost(active.host) else { return }
        cancel(id: active.id)
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard let active, active.id == id else { return false }
        return matchesCurrentHost(active.host)
    }

    private func matchesCurrentHost(_ host: Host) -> Bool {
        isUnlocked() && host.ssh != nil && currentHost(host.id)?.ssh == host.ssh
    }

    private func resolve(id: UUID, decision: HostKeyDecision) {
        guard active?.id == id, pending?.id == id else { return }
        let reply = continuation
        continuation = nil
        pending = nil
        reply?.resume(returning: isCurrent(id) ? decision : .cancel)
    }

    private func cancel(id: UUID) {
        guard active?.id == id else { return }
        scanTask?.cancel()
        scanTask = nil
        resolve(id: id, decision: .cancel)
        active = nil
    }
}
