import Foundation
import TermoEngine
import TermoCore

/// A credential-free snapshot. Changing connection identity or cwd invalidates approval.
struct AIExecutionTarget: Equatable {
    let hostID: String
    let title: String
    let host: String
    let port: Int
    let user: String
    let authMethod: AuthMethod
    let keyID: String
    let keyPath: String
    let cwd: String

    init?(_ host: Host) {
        guard let ssh = host.ssh, !ssh.defaultPath.contains("\0") else { return nil }
        hostID = host.id; title = host.name
        self.host = ssh.host; port = ssh.port; user = ssh.user
        authMethod = ssh.authMethod; keyID = ssh.keyId; keyPath = ssh.keyPath
        cwd = ssh.defaultPath.isEmpty ? "~" : ssh.defaultPath
    }

    var destination: String { "\(user)@\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    /// Explicit cwd, a fresh noninteractive shell per request. Never inherits terminal env/cwd.
    func shellCommand(_ command: String) -> String {
        let directory: String
        if cwd == "~" { directory = "\"$HOME\"" }
        else if cwd.hasPrefix("~/") { directory = "\"$HOME\"/" + Self.quote(String(cwd.dropFirst(2))) }
        else { directory = Self.quote(cwd) }
        return "cd -- \(directory) && exec sh -c \(Self.quote(command))"
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

struct AIToolRequest: Identifiable {
    enum Decision { case pending, approved, rejected, expired }
    let id: UUID
    let version: Int
    let callID: String
    let command: String
    let purpose: String
    let target: AIExecutionTarget
    let timeout: Int
    let expiresAt: Date
    var decision: Decision = .pending

    static func decode(callID: String, name: String, arguments: String,
                       target: AIExecutionTarget?, now: Date = Date()) -> AIToolRequest? {
        guard name == "request_shell_command", let target, let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(json.keys).isSubset(of: ["command", "purpose"]),
              let command = json["command"] as? String, let purpose = json["purpose"] as? String,
              valid(command), !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              purpose.count <= 1000 else { return nil }
        return AIToolRequest(id: UUID(), version: 1, callID: callID, command: command,
            purpose: purpose, target: target, timeout: 60, expiresAt: now.addingTimeInterval(600))
    }

    static func valid(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && command.utf8.count <= 16_384 &&
        !command.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" }
    }
}

/// Thread-safe bounded output and cancellation; cancellation owns only this SSH operation.
final class AICommandIO: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SSHSession?
    private var cancelled = false
    private var out = Data(), err = Data()
    private var truncated = false
    private let limit = 128 * 1024

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ session: SSHSession) {
        lock.lock(); self.session = session; let stop = cancelled; lock.unlock()
        if stop { session.cancel() }
    }
    func detach() { lock.lock(); session = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let operation = session; lock.unlock()
        operation?.cancel()
    }
    func append(stderr: Bool, data: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - (stderr ? err.count : out.count))
        if data.count > remaining { truncated = true }
        if stderr { err.append(data.prefix(remaining)) } else { out.append(data.prefix(remaining)) }
    }
    var snapshot: (stdout: String, stderr: String, truncated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), truncated)
    }
}

@MainActor
final class AICommandRun {
    enum State { case connecting, running, completed, failed, unknown, stopped, timedOut }
    let request: AIToolRequest
    let io = AICommandIO()
    private(set) var state: State = .connecting
    private(set) var exitCode: Int32?
    private(set) var detail = ""
    private(set) var finished = false
    var task: Task<Void, Never>?

    init(request: AIToolRequest) { self.request = request }
    func stop() { io.cancel() }
    func didDispatch() { state = .running }
    func finish(_ state: State, exitCode: Int32? = nil, detail: String = "") {
        self.state = state; self.exitCode = exitCode; self.detail = detail; finished = true
        task = nil
    }
}

/// Backend approval gate. UI supplies only ID/version; command and target come from the ledger.
/// Runs survive panel/tab changes. No automatic retry, no PTY, no credentials in model messages.
@MainActor
final class AICommandService {
    static let shared = AICommandService(journalURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("termo/ai-action-receipts.json"))
    private var requests: [UUID: AIToolRequest] = [:]
    private var runs: [UUID: AICommandRun] = [:]
    typealias Runner = (AICommandRun, SSHConnection, @escaping @MainActor () -> Bool) async -> Void
    private let runner: Runner

    // Receipts contain no commands, output or credentials. Relaunch never replays an action.
    private struct Receipt: Codable {
        let id: UUID
        let hostID: String
        var state: String
        let date: Date
    }
    private let journalURL: URL?
    private var receipts: [Receipt] = []
    private(set) var interruptedHostIDs: Set<String> = []

    init(journalURL: URL? = nil, runner: Runner? = nil) {
        self.runner = runner ?? Self.runSSH
        self.journalURL = journalURL
        if let journalURL, let data = try? Data(contentsOf: journalURL),
           let saved = try? JSONDecoder().decode([Receipt].self, from: data) {
            receipts = saved.map { value in
                var receipt = value
                if receipt.state == "approved" { receipt.state = "unknown" }
                return receipt
            }
            interruptedHostIDs = Set(receipts.filter { $0.state == "unknown" }.map(\.hostID))
        }
    }

    private func saveReceipt(_ request: AIToolRequest, state: String) throws {
        guard let journalURL else { return }
        var updated = receipts.filter { $0.id != request.id }
        updated.append(Receipt(id: request.id, hostID: request.target.hostID, state: state, date: Date()))
        if updated.count > 200 { updated = Array(updated.suffix(200)) }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: journalURL, options: .atomic)
        receipts = updated
    }

    func register(_ request: AIToolRequest) { if requests[request.id] == nil { requests[request.id] = request } }
    func decision(_ id: UUID) -> AIToolRequest.Decision? { requests[id]?.decision }
    func invalidate(_ id: UUID, rejected: Bool = false) {
        guard requests[id]?.decision == .pending else { return }
        requests[id]?.decision = rejected ? .rejected : .expired
    }
    func revise(_ id: UUID, command: String, now: Date = Date()) -> AIToolRequest? {
        guard let old = requests[id], old.decision == .pending, AIToolRequest.valid(command) else { return nil }
        invalidate(id)
        let revised = AIToolRequest(id: UUID(), version: old.version + 1, callID: old.callID,
            command: command, purpose: old.purpose, target: old.target, timeout: old.timeout,
            expiresAt: now.addingTimeInterval(600))
        register(revised)
        return revised
    }

    struct ApprovalError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func approve(id: UUID, expectedVersion: Int, now: Date = Date(),
                 currentTarget: @escaping @MainActor () -> AIExecutionTarget?,
                 unlocked: @escaping @MainActor () -> Bool,
                 connection: () throws -> SSHConnection) throws -> AICommandRun {
        guard var request = requests[id], request.version == expectedVersion,
              request.decision == .pending, AIToolRequest.valid(request.command),
              (1...300).contains(request.timeout) else {
            throw ApprovalError(message: String(localized: "这条请求已处理，请重新提出命令。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        guard request.expiresAt > now, currentTarget() == request.target else {
            invalidate(id)
            throw ApprovalError(message: String(localized: "请求已过期或主机配置已改变，请重新提出命令。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        guard unlocked() else { throw ApprovalError(message: String(localized: "请先解锁 Termo。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) }
        let ssh = try connection()
        guard ssh.host == request.target.host, ssh.port == request.target.port,
              ssh.user == request.target.user, ssh.authMethod == request.target.authMethod,
              ssh.keyId == request.target.keyID, ssh.keyPath == request.target.keyPath,
              (ssh.defaultPath.isEmpty ? "~" : ssh.defaultPath) == request.target.cwd else {
            invalidate(id)
            throw ApprovalError(message: String(localized: "执行连接与批准的主机不一致。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        try saveReceipt(request, state: "approved")
        // No suspension between validation and consume: duplicate clicks cannot dispatch twice.
        request.decision = .approved
        requests[id] = request
        let run = AICommandRun(request: request)
        runs[id] = run
        run.task = Task {
            await runner(run, ssh, {
                !run.io.isCancelled && unlocked() && request.expiresAt > Date() && currentTarget() == request.target
            })
            try? saveReceipt(request, state: String(describing: run.state))
            runs.removeValue(forKey: id)
        }
        return run
    }

    private static func runSSH(_ run: AICommandRun, _ ssh: SSHConnection,
                               authorize: @escaping @MainActor () -> Bool) async {
        let io = run.io
        let operation: SSHSession
        do { operation = try await Task.detached { try SSHSessionPool.shared.acquireOperation(for: ssh) }.value }
        catch { run.finish(.failed, detail: error.localizedDescription); return }
        io.attach(operation)
        guard authorize() else {
            io.detach()
            await Task.detached { operation.close() }.value
            run.finish(io.isCancelled ? .stopped : .failed,
                       detail: String(localized: "执行前校验未通过，命令没有发送。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            return
        }
        run.didDispatch()
        let request = run.request
        let result = await Task.detached { () -> Result<SSHSession.ExecBytes, Error> in
            defer { io.detach(); operation.close() }
            return Result {
                try operation.execObserved(request.target.shellCommand(request.command), timeout: request.timeout) {
                    io.append(stderr: $0, data: $1)
                }
            }
        }.value
        switch result {
        case .success(let value):
            if value.cancelled { run.finish(.stopped) }
            else if value.timedOut { run.finish(.timedOut) }
            else if value.exitCode < 0 { run.finish(.unknown) }
            else { run.finish(.completed, exitCode: value.exitCode) }
        case .failure(let error): run.finish(.unknown, detail: error.localizedDescription)
        }
    }
}
