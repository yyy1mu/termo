import XCTest

@testable import Termo
import TermoCore

@MainActor
final class TransferCoordinatorTests: XCTestCase {
    func testTasksShareCapacityAndQueuedWorkStartsInOrder() {
        let queue = TransferCoordinator<Transfer>(limit: 2, pausedReleasesSlot: true)
        let tasks = (0..<4).map { _ in Transfer() }
        tasks.forEach { queue.enqueue($0) }
        XCTAssertEqual(tasks.map(\.starts), [1, 1, 0, 0])
        tasks[1].finish()
        XCTAssertEqual(tasks.map(\.starts), [1, 1, 1, 0])
        tasks[0].finish()
        XCTAssertEqual(tasks.map(\.starts), [1, 1, 1, 1])
        XCTAssertEqual(queue.tasks.count, 4, "Completion retains history")
    }

    func testRetryWaitsForCapacityAndDoesNotRerunSuccessfulWork() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let failed = Transfer(), running = Transfer()
        queue.enqueue(failed)
        failed.finish(failed: true)
        queue.enqueue(running)
        queue.retry(failed, resume: true)
        XCTAssertEqual(failed.phase, .queued)
        XCTAssertEqual(failed.starts, 1)
        XCTAssertEqual(failed.retryModes, [true])
        running.finish()
        XCTAssertEqual(failed.phase, .running)
        XCTAssertEqual(failed.starts, 2)
        queue.retry(running, resume: false)
        XCTAssertEqual(running.starts, 1)
    }

    func testResumeRequestsTakePrecedenceOverNewQueuedWork() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let paused = Transfer(), running = Transfer(), waiting = Transfer()
        [paused, running, waiting].forEach { queue.enqueue($0) }
        queue.pause(paused)
        XCTAssertEqual(running.phase, .running)
        queue.resume(paused)
        XCTAssertTrue(paused.awaitingSlot)
        running.finish()
        XCTAssertEqual(paused.phase, .running)
        XCTAssertEqual(waiting.phase, .queued)
        paused.finish()
        XCTAssertEqual(waiting.phase, .running)
    }

    func testReservedPauseKeepsItsSlotAndCanResumeWhenPoolIsFull() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: false)
        let first = Transfer(), second = Transfer()
        queue.enqueue(first); queue.enqueue(second)
        queue.pause(first)
        XCTAssertEqual(second.phase, .queued)
        queue.resume(first)
        XCTAssertEqual(first.phase, .running)
        XCTAssertFalse(first.awaitingSlot)
        XCTAssertEqual(second.starts, 0)
    }

    func testChangingPausePolicyDoesNotStrandPendingResume() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let first = Transfer(), second = Transfer(), third = Transfer()
        [first, second, third].forEach { queue.enqueue($0) }
        queue.pause(first)
        queue.resume(first)
        XCTAssertTrue(first.awaitingSlot)
        // Changing policy must neither exceed the cap nor strand an already requested resume.
        queue.configure(limit: 1, pausedReleasesSlot: false)
        XCTAssertEqual(first.phase, .paused)
        XCTAssertTrue(first.awaitingSlot)
        XCTAssertEqual(third.phase, .queued)
        second.finish()
        XCTAssertEqual(first.phase, .running)
        XCTAssertFalse(first.awaitingSlot)
        XCTAssertEqual(third.phase, .queued)
        first.finish()
        XCTAssertEqual(third.phase, .running)
    }

    func testCapacityChangesAdmitNewWorkWithoutCancellingExistingWork() {
        let queue = TransferCoordinator<Transfer>(limit: 0, pausedReleasesSlot: true)
        let tasks = (0..<4).map { _ in Transfer() }
        tasks.forEach { queue.enqueue($0) }
        XCTAssertEqual(tasks.map(\.starts), [1, 0, 0, 0])
        queue.configure(limit: 3, pausedReleasesSlot: true)
        XCTAssertEqual(tasks.map(\.starts), [1, 1, 1, 0])
        queue.configure(limit: 1, pausedReleasesSlot: true)
        tasks[0].finish(); tasks[1].finish()
        XCTAssertEqual(tasks[3].starts, 0)
        tasks[2].finish()
        XCTAssertEqual(tasks[3].starts, 1)
        XCTAssertTrue(tasks.allSatisfy { $0.cancellations == 0 })
    }

    func testRetryJoinsQueueBehindAlreadyWaitingTasks() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let failed = Transfer(), running = Transfer(), waiting = Transfer()
        queue.enqueue(failed)
        failed.finish(failed: true)
        queue.enqueue(running); queue.enqueue(waiting)
        queue.retry(failed, resume: false)
        running.finish()
        XCTAssertEqual(waiting.phase, .running)
        XCTAssertEqual(failed.phase, .queued)
        waiting.finish()
        XCTAssertEqual(failed.phase, .running)
    }

    func testLoweringCapacityWithMultipleReservedPausesStillAllowsSerialResume() {
        let queue = TransferCoordinator<Transfer>(limit: 2, pausedReleasesSlot: false)
        let first = Transfer(), second = Transfer()
        queue.enqueue(first); queue.enqueue(second)
        queue.pause(first); queue.pause(second)
        queue.configure(limit: 1, pausedReleasesSlot: false)
        queue.resume(first); queue.resume(second)
        XCTAssertEqual(first.phase, .running)
        XCTAssertEqual(second.phase, .paused)
        XCTAssertTrue(second.awaitingSlot)
        first.finish()
        XCTAssertEqual(second.phase, .running)
    }

    func testRemovalRetainsInFlightTaskAndCapacityUntilCancellationFinishes() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let running = Transfer(), waiting = Transfer()
        queue.enqueue(running); queue.enqueue(waiting)
        queue.remove(running.id)
        XCTAssertEqual(running.cancellations, 1)
        XCTAssertTrue(queue.tasks.contains { $0 === running })
        XCTAssertEqual(waiting.starts, 0)
        running.finish(cancelled: true)
        XCTAssertFalse(queue.tasks.contains { $0 === running })
        XCTAssertEqual(waiting.starts, 1)
        XCTAssertNil(running.onSchedulingChange)
    }

    func testCancelAllNeverStartsQueuedTasksAndOldCallbacksCannotAffectNewQueue() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let old = (0..<3).map { _ in Transfer() }
        old.forEach { queue.enqueue($0) }
        let staleCallback = old[0].onSchedulingChange
        queue.cancelAll()
        XCTAssertTrue(queue.tasks.isEmpty)
        XCTAssertEqual(old.map(\.starts), [1, 0, 0])
        XCTAssertEqual(old.map(\.cancellations), [1, 1, 1])
        XCTAssertTrue(old.allSatisfy { $0.onSchedulingChange == nil })
        let replacement = Transfer(), waiting = Transfer()
        queue.enqueue(replacement); queue.enqueue(waiting)
        old[0].finish(cancelled: true)
        staleCallback?()
        XCTAssertEqual(waiting.starts, 0)
        XCTAssertEqual(queue.tasks.count, 2)
    }

    func testClearingHistoryKeepsRunningAndPausedTasksAndDetachesCallbacks() {
        let queue = TransferCoordinator<Transfer>(limit: 2, pausedReleasesSlot: false)
        let done = Transfer(), paused = Transfer(), running = Transfer()
        queue.enqueue(done); done.finish()
        queue.enqueue(paused); queue.pause(paused)
        queue.enqueue(running)
        XCTAssertEqual(queue.clearFinished(), [done.id])
        XCTAssertNil(done.onSchedulingChange)
        XCTAssertEqual(queue.tasks.map(\.id), [paused.id, running.id])
    }

    func testUnownedAndDuplicateTasksCannotStartOrReserveWork() {
        let queue = TransferCoordinator<Transfer>(limit: 2, pausedReleasesSlot: true)
        let task = Transfer(), outsider = Transfer()
        queue.enqueue(task); queue.enqueue(task)
        queue.pause(outsider); queue.resume(outsider); queue.retry(outsider, resume: false)
        XCTAssertEqual(queue.tasks.count, 1)
        XCTAssertEqual(task.starts, 1)
        XCTAssertEqual(outsider.phase, .queued)
        XCTAssertTrue(outsider.retryModes.isEmpty)
    }

    func testSynchronousCompletionDuringAdmissionDoesNotRecurseOrSkipQueuedTasks() {
        let queue = TransferCoordinator<Transfer>(limit: 1, pausedReleasesSlot: true)
        let first = Transfer(), immediate = Transfer(), last = Transfer()
        immediate.finishesOnStart = true
        [first, immediate, last].forEach { queue.enqueue($0) }
        first.finish()
        XCTAssertEqual(immediate.starts, 1)
        XCTAssertEqual(immediate.phase, .done)
        XCTAssertEqual(last.starts, 1)
        XCTAssertEqual(last.phase, .running)
    }

    func testUploadRetryPreparationQueuesOnlyFailedItemsWithoutStartingIO() {
        let task = UploadTask(
            files: [URL(fileURLWithPath: "/unused/first"), URL(fileURLWithPath: "/unused/second")],
            destDir: "/unused", fs: RemoteFS(SSHConnection()), onAllDone: {})
        task.items[0].state = .done
        task.items[1].state = .failed("fixture")
        task.items[1].interrupted = true
        task.phase = .done
        XCTAssertTrue(task.prepareRetry(resume: false))
        XCTAssertEqual(task.phase, .queued)
        XCTAssertEqual(task.items[0].state, .done)
        XCTAssertEqual(task.items[1].state, .waiting)
        XCTAssertFalse(task.items[1].interrupted)
        XCTAssertFalse(task.prepareRetry(resume: true))
        task.cancel()
        task.start()
        XCTAssertEqual(task.phase, .cancelled, "A cancelled queued task cannot start")
    }

    @MainActor
    private final class Transfer: ScheduledTransfer {
        let id = UUID()
        var phase: SessionPhase = .queued
        var awaitingSlot = false
        var isWaitingForPath = false
        var isPerformingIO = false
        var isCancelling = false
        var onSchedulingChange: (() -> Void)?
        var starts = 0
        var cancellations = 0
        var retryModes: [Bool] = []
        var failed = false
        var finishesOnStart = false

        func start() {
            guard phase == .queued else { XCTFail("Started outside queue"); return }
            starts += 1
            phase = .running
            if finishesOnStart { finish() }
        }
        func pause() {
            guard phase == .running else { return }
            phase = .paused
            onSchedulingChange?()
        }
        func requestResume(slotFree: Bool) {
            guard phase == .paused else { return }
            awaitingSlot = !slotFree
            if slotFree { phase = .running }
            onSchedulingChange?()
        }
        func admitResume() {
            guard phase == .paused, awaitingSlot else { XCTFail("Unexpected resume"); return }
            awaitingSlot = false
            phase = .running
        }
        func prepareRetry(resume: Bool) -> Bool {
            guard phase == .done, failed else { return false }
            retryModes.append(resume)
            phase = .queued
            return true
        }
        func cancel() {
            cancellations += 1
            if phase == .queued { finish(cancelled: true) }
        }
        func finish(failed: Bool = false, cancelled: Bool = false) {
            self.failed = failed
            phase = cancelled ? .cancelled : .done
            onSchedulingChange?()
        }
    }
}
