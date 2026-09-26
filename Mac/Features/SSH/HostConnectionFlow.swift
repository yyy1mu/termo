import Combine
import Foundation

/// Owns one foreground authentication/connection request. UI callbacks must carry its immutable ID.
@MainActor
final class HostConnectionFlow: ObservableObject {
    struct Request: Identifiable {
        enum Kind: Equatable { case password, connection }
        let id = UUID()
        let host: Host
        let kind: Kind
        let hint: String
    }

    @Published private(set) var request: Request?
    @Published private(set) var passwordError: String?
    private var continuation: (() -> Void)?
    private let currentHost: (String) -> Host?
    private let isUnlocked: () -> Bool

    init(currentHost: @escaping (String) -> Host?, isUnlocked: @escaping () -> Bool) {
        self.currentHost = currentHost
        self.isUnlocked = isUnlocked
    }

    var isBusy: Bool { request != nil }

    func askPassword(for host: Host, error: String?, then: @escaping () -> Void) {
        begin(host, kind: .password, hint: "", error: error, then: then)
    }

    func connect(to host: Host, hint: String, then: @escaping () -> Void) {
        begin(host, kind: .connection, hint: hint, error: nil, then: then)
    }

    private func begin(_ host: Host, kind: Request.Kind, hint: String, error: String?, then: @escaping () -> Void) {
        guard !isBusy, matchesCurrentHost(host) else { return }
        continuation = then
        passwordError = error
        request = Request(host: host, kind: kind, hint: hint)
    }

    /// The synchronous store publishes credentials only after persistence succeeds.
    /// A failed write keeps the same prompt and continuation available for retry.
    @discardableResult
    func submitPassword(id: UUID, password: String, store: (Host) -> Bool) -> Bool {
        guard let request = validated(id, kind: .password) else { return false }
        guard !password.isEmpty else {
            passwordError = String(localized: "请输入登录密码。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            return false
        }
        guard store(request.host) else { return false }
        guard self.request?.id == id else { return false }
        guard isUnlocked() else { cancelAll(); return false }
        // Storing the password intentionally changes the connection snapshot. Do not revalidate it here.
        complete()
        return true
    }

    func reportPasswordError(_ message: String?, id: UUID) {
        guard request?.id == id, request?.kind == .password else { return }
        passwordError = message
    }

    func finishConnection(id: UUID) {
        guard validated(id, kind: .connection) != nil else { return }
        complete()
    }

    /// Return a snapshot only when cancellation still belongs to the current connection.
    /// Callers may clear its temporary password, but must never clear a newer host's credentials.
    @discardableResult
    func cancel(id: UUID) -> Host? {
        guard let request, request.id == id else { return nil }
        let current = matchesCurrentHost(request.host)
        cancelAll()
        return current ? request.host : nil
    }

    func cancelAll() {
        continuation = nil
        request = nil
        passwordError = nil
    }

    func reconcile() {
        guard let request, !matchesCurrentHost(request.host) else { return }
        cancelAll()
    }

    private func validated(_ id: UUID, kind: Request.Kind) -> Request? {
        guard let request, request.id == id, request.kind == kind else { return nil }
        guard matchesCurrentHost(request.host) else { cancelAll(); return nil }
        return request
    }

    private func matchesCurrentHost(_ host: Host) -> Bool {
        isUnlocked() && host.ssh != nil && currentHost(host.id)?.ssh == host.ssh
    }

    private func complete() {
        let action = continuation
        cancelAll() // Consume before calling back: the action may start the next stage synchronously.
        action?()
    }
}
