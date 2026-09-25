import Combine
import Foundation

/// Tasks own their I/O; the coordinator alone admits new runs and retries into the shared slot pool.
@MainActor
protocol ScheduledTransfer: AnyObject {
    var id: UUID { get }
    var phase: SessionPhase { get }
    var awaitingSlot: Bool { get }
    var isWaitingForPath: Bool { get }
    var isPerformingIO: Bool { get }
    var isCancelling: Bool { get }
    var onSchedulingChange: (() -> Void)? { get set }
    func start()
    func pause()
    func requestResume(slotFree: Bool)
    func admitResume()
    func prepareRetry(resume: Bool) -> Bool
    func cancel()
}

extension SessionPhase {
    var isFinished: Bool { self == .done || self == .cancelled }
}

@MainActor
final class TransferCoordinator<Transfer: ScheduledTransfer>: ObservableObject {
    @Published private(set) var tasks: [Transfer] = []
    var onChange: (() -> Void)?
    private var limit: Int
    private var pausedReleasesSlot: Bool
    private var pendingRemoval: Set<UUID> = []
    private var pumping = false
    private var needsPump = false

    init(limit: Int, pausedReleasesSlot: Bool) {
        self.limit = max(1, limit)
        self.pausedReleasesSlot = pausedReleasesSlot
    }

    func configure(limit: Int, pausedReleasesSlot: Bool) {
        self.limit = max(1, limit)
        self.pausedReleasesSlot = pausedReleasesSlot
        changed()
    }

    func enqueue(_ task: Transfer) {
        guard task.phase == .queued, !contains(task) else { return }
        task.onSchedulingChange = { [weak self, weak task] in
            guard let self, let task, self.contains(task) else { return }
            self.changed()
        }
        tasks.append(task)
        changed()
    }

    func pause(_ task: Transfer) {
        guard contains(task), !pendingRemoval.contains(task.id) else { return }
        task.pause()
        changed()
    }

    func resume(_ task: Transfer) {
        guard contains(task), !pendingRemoval.contains(task.id), task.phase == .paused else { return }
        task.requestResume(slotFree: task.isWaitingForPath || canResume(task))
        changed()
    }

    func retry(_ task: Transfer, resume: Bool) {
        guard contains(task), !pendingRemoval.contains(task.id), task.prepareRetry(resume: resume) else {
            return
        }
        tasks = tasks.filter { $0 !== task } + [task]
        changed()
    }

    /// Cancellation can be asynchronous. Keep its slot and destination reservation until I/O has stopped.
    func remove(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        pendingRemoval.insert(id)
        if !task.phase.isFinished { task.cancel() }
        changed()
    }

    @discardableResult
    func clearFinished() -> Set<UUID> {
        let removed = Set(tasks.filter { $0.phase.isFinished }.map(\.id))
        detach(removed)
        changed()
        return removed
    }

    /// Detach every callback before cancelling any task: queued cancellation may complete synchronously.
    func cancelAll() {
        let previous = tasks
        previous.forEach { $0.onSchedulingChange = nil }
        tasks.removeAll()
        pendingRemoval.removeAll()
        for task in previous where !task.phase.isFinished { task.cancel() }
        onChange?()
    }

    private func contains(_ task: Transfer) -> Bool { tasks.contains { $0 === task } }

    private var occupiedSlots: Int {
        tasks.filter {
            $0.isPerformingIO
                || (!$0.isWaitingForPath
                    && (($0.phase == .running && !$0.awaitingSlot)
                        || (!pausedReleasesSlot && $0.phase == .paused)))
        }.count
    }

    private func canResume(_ task: Transfer) -> Bool {
        if task.isPerformingIO { return true }  // A rapid resume keeps the still-running operation's own slot.
        // Reserved pauses block new tasks, but must not block each other forever after a limit reduction.
        if pausedReleasesSlot { return occupiedSlots < limit }
        return tasks.filter {
            $0.isPerformingIO || ($0.phase == .running && !$0.isWaitingForPath && !$0.awaitingSlot)
        }.count < limit
    }

    private func detach(_ ids: Set<UUID>) {
        for task in tasks where ids.contains(task.id) { task.onSchedulingChange = nil }
        tasks.removeAll { ids.contains($0.id) }
        pendingRemoval.subtract(ids)
    }

    private func changed() {
        pump()
        onChange?()
    }

    private func pump() {
        // A task may finish synchronously while being admitted. Reconcile again without recursive starts.
        needsPump = true
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        repeat {
            needsPump = false
            let finishedRemovals = Set(
                tasks.filter { pendingRemoval.contains($0.id) && $0.phase.isFinished }.map(\.id))
            if !finishedRemovals.isEmpty { detach(finishedRemovals) }
            for task in tasks
            where (task.phase == .paused || task.phase == .running) && task.awaitingSlot
                && !task.isWaitingForPath && !task.isCancelling && !pendingRemoval.contains(task.id)
            {
                guard canResume(task) else { continue }
                task.admitResume()
            }
            for task in tasks where task.phase == .queued && !pendingRemoval.contains(task.id) {
                guard occupiedSlots < limit else { break }
                task.start()
            }
        } while needsPump
    }
}
