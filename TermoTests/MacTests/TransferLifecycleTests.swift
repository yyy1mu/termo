import XCTest

@testable import Termo

@MainActor
final class TransferLifecycleTests: XCTestCase {
    func testCancellingPathWaiterFinishesWithoutWaitingForOwnerOrStartingIO() async {
        let locks = TransferPathLocks(), queue = makeQueue(2)
        let firstFS = FileSystem(), secondFS = FileSystem()
        let first = upload(firstFS, locks: locks), second = upload(secondFS, locks: locks)
        queue.enqueue(first)
        await until { firstFS.uploads == 1 }
        queue.enqueue(second)
        await until { second.isWaitingForPath }
        second.cancel()
        await until { second.phase == .cancelled }
        XCTAssertEqual(secondFS.probes, 0)
        XCTAssertEqual(first.phase, .running)
        XCTAssertEqual(secondFS.closes, 1)
        first.cancel(); firstFS.complete(.cancelled)
        await until { first.phase.isFinished }
    }

    func testPausedOwnerCanResumeWhileSamePathWaiterDoesNotConsumeCapacity() async {
        let locks = TransferPathLocks(), queue = makeQueue(1)
        let firstFS = FileSystem(), sameFS = FileSystem(), otherFS = FileSystem()
        let first = upload(firstFS, locks: locks), same = upload(sameFS, locks: locks)
        let other = upload(otherFS, locks: locks, directory: "/other")
        queue.enqueue(first)
        await until { firstFS.uploads == 1 }
        queue.enqueue(same); queue.enqueue(other)
        queue.pause(first)
        XCTAssertEqual(same.phase, .queued, "Pause is only a request until I/O has stopped")
        firstFS.complete(.paused)
        await until { same.isWaitingForPath && otherFS.uploads == 1 }
        XCTAssertEqual(sameFS.probes, 0)
        queue.resume(first)
        XCTAssertTrue(first.awaitingSlot)
        otherFS.complete(.completed)
        await until { firstFS.uploads == 2 }
        XCTAssertEqual(sameFS.uploads, 0)
        XCTAssertTrue(other.phase.isFinished)
        firstFS.complete(.completed)
        await until { sameFS.uploads == 1 }
        XCTAssertEqual(first.phase, .done)
        sameFS.complete(.completed)
        await until { same.phase == .done }
    }

    func testAcquiringAPathStillWaitsForCapacityAndCancellationReleasesTheLease() async {
        let locks = TransferPathLocks(), queue = makeQueue(1), owner = UUID()
        XCTAssertTrue(locks.tryAcquire("up:host:/target/file", owner: owner))
        let waitingFS = FileSystem(), activeFS = FileSystem()
        let waiting = upload(waitingFS, locks: locks)
        let active = upload(activeFS, locks: locks, directory: "/other")
        queue.enqueue(waiting)
        await until { waiting.isWaitingForPath }
        queue.enqueue(active)
        await until { activeFS.uploads == 1 }
        locks.release("up:host:/target/file", owner: owner)
        await until { waiting.awaitingSlot }
        XCTAssertEqual(waitingFS.probes, 0)
        waiting.cancel()
        await until { waiting.phase == .cancelled }
        XCTAssertTrue(locks.tryAcquire("up:host:/target/file", owner: owner))
        locks.release("up:host:/target/file", owner: owner)
        active.cancel(); activeFS.complete(.cancelled)
        await until { active.phase == .cancelled }
    }

    func testPauseDuringProbeIsAcknowledgedBeforeReleasingSlotAndPreventsWrites() async {
        let locks = TransferPathLocks(), queue = makeQueue(1)
        let probingFS = FileSystem(), otherFS = FileSystem()
        probingFS.holdProbe = true
        let probing = upload(probingFS, locks: locks),
            other = upload(otherFS, locks: locks, directory: "/other")
        queue.enqueue(probing)
        await until { probingFS.probes == 1 }
        queue.enqueue(other); queue.pause(probing)
        XCTAssertEqual(other.phase, .queued)
        XCTAssertTrue(probing.isPerformingIO)
        probingFS.finishProbe()
        await until { otherFS.uploads == 1 }
        XCTAssertEqual(probingFS.uploads, 0)
        XCTAssertEqual(probing.phase, .paused)
        queue.resume(probing)
        XCTAssertTrue(probing.awaitingSlot)
        otherFS.complete(.completed)
        await until { probingFS.uploads == 1 }
        probingFS.complete(.completed)
        await until { probing.phase == .done }
    }

    func testCancelDuringProbeCannotOpenOverwritePromptOrWriteAfterProbeReturns() async {
        let locks = TransferPathLocks(), queue = makeQueue(1), fs = FileSystem()
        fs.holdProbe = true
        let task = upload(fs, locks: locks)
        queue.enqueue(task)
        await until { fs.probes == 1 }
        task.cancel()
        fs.finishProbe(existing: true)
        await until { task.phase == .cancelled }
        XCTAssertNil(task.pendingAsk)
        XCTAssertEqual(fs.uploads, 0)
        XCTAssertEqual(fs.finalizations, 0)
    }

    func testCancelCannotBeUndoneByResumeWhileIOIsStillStopping() async {
        let locks = TransferPathLocks(), queue = makeQueue(1), fs = FileSystem()
        let task = upload(fs, locks: locks)
        queue.enqueue(task)
        await until { fs.uploads == 1 }
        queue.pause(task); task.cancel(); queue.resume(task)
        XCTAssertEqual(fs.control?.signal, .cancel)
        XCTAssertTrue(task.isCancelling)
        fs.complete(.cancelled)
        await until { task.phase == .cancelled }
        XCTAssertEqual(fs.uploads, 1)
    }

    func testCancelDownloadWaitingForPathDoesNotDeleteAFileItNeverOpened() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("existing owner".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let locks = TransferPathLocks(), owner = UUID(), queue = makeQueue(1), fs = FileSystem()
        let key = "down:\(url.standardizedFileURL.path)"
        XCTAssertTrue(locks.tryAcquire(key, owner: owner))
        let task = download(fs, locks: locks, url: url)
        queue.enqueue(task)
        await until { task.isWaitingForPath }
        task.cancel()
        await until { task.phase == .cancelled }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing owner")
        XCTAssertEqual(fs.downloads, 0)
        locks.release(key, owner: owner)
    }

    func testCancelledPausedDownloadDeletesOnlyItsOwnPartialBeforeReleasingPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download")
        let locks = TransferPathLocks(), queue = makeQueue(1), fs = FileSystem()
        let task = download(fs, locks: locks, url: url)
        queue.enqueue(task)
        await until { fs.downloads == 1 }
        let destination = try XCTUnwrap(fs.destination)
        _ = try destination.begin(version: DownloadVersion(size: 100))
        try destination.append(Data("partial".utf8))
        try destination.suspend()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        queue.pause(task); fs.complete(.paused)
        await until { task.phase == .paused && !task.isPerformingIO }
        // A different operation may create the final pathname while this download is paused.
        try Data("keep me".utf8).write(to: url)
        task.cancel()
        await until { task.phase == .cancelled }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep me")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["download"])
        let owner = UUID(), key = "down:\(url.standardizedFileURL.path)"
        XCTAssertTrue(locks.tryAcquire(key, owner: owner))
        locks.release(key, owner: owner)
    }

    func testFailedDownloadCleansOnlyStagingAndRetryStartsWithANewDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download"), fs = FileSystem(), queue = makeQueue(1)
        let task = download(fs, locks: TransferPathLocks(), url: url)
        queue.enqueue(task)
        await until { fs.downloads == 1 }
        let first = try XCTUnwrap(fs.destination)
        _ = try first.begin(version: DownloadVersion(size: 100))
        try first.append(Data("partial".utf8))
        try first.suspend()
        fs.control?.setSent(7)
        try Data("unrelated".utf8).write(to: url)
        fs.complete(.failed("read failed"))
        await until { task.phase == .done }
        XCTAssertEqual(task.items[0].state, .failed("read failed"))
        XCTAssertNil(task.items[0].downloadDestination)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["download"])
        XCTAssertEqual(try String(contentsOf: url), "unrelated")
        XCTAssertTrue(task.prepareRetry(resume: true))
        XCTAssertEqual(task.items[0].sent, 0)
        // The caller removes its fixture file, then explicitly starts the retry.
        try FileManager.default.removeItem(at: url)
        task.start()
        await until { fs.downloads == 2 }
        let second = try XCTUnwrap(fs.destination)
        XCTAssertFalse(first === second)
        XCTAssertEqual(try second.begin(version: DownloadVersion(size: 100)), 0)
        try second.suspend()
        task.cancel(); fs.complete(.cancelled)
        await until { task.phase == .cancelled }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCompletedDownloadUsesOpenedRemoteSizeInsteadOfStaleListingSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download"), fs = FileSystem(), queue = makeQueue(1)
        let task = download(fs, locks: TransferPathLocks(), url: url)
        XCTAssertEqual(task.totalBytes, 100)
        queue.enqueue(task)
        await until { fs.downloads == 1 }
        let destination = try XCTUnwrap(fs.destination)
        _ = try destination.begin(version: DownloadVersion(size: 4))
        try destination.append(Data("done".utf8))
        try destination.finish()
        fs.control?.setSent(4)
        fs.complete(.completed)
        await until { task.phase == .done }
        XCTAssertEqual(task.items[0].state, .done)
        XCTAssertEqual(task.items[0].localSize, 4)
        XCTAssertEqual(task.totalBytes, 4)
        XCTAssertEqual(task.overallSent, 4)
        XCTAssertNil(task.items[0].downloadDestination)
        XCTAssertEqual(try String(contentsOf: url), "done")
    }

    func testCancellationImmediatelyAfterLeaseHandoffReturnsItToNextWaiter() async {
        let locks = TransferPathLocks(), owner = UUID(), queue = makeQueue(2)
        let fs = FileSystem(), task = upload(fs, locks: locks)
        let key = "up:host:/target/file"
        XCTAssertTrue(locks.tryAcquire(key, owner: owner))
        queue.enqueue(task)
        await until { task.isWaitingForPath }
        locks.release(key, owner: owner)
        task.cancel()  // Lease granted, but acquire's continuation has not resumed on the main actor yet.
        await until { task.phase == .cancelled }
        XCTAssertTrue(locks.tryAcquire(key, owner: owner))
        XCTAssertEqual(fs.probes, 0)
        locks.release(key, owner: owner)
    }

    func testLeaseOwnerChecksAndFIFOHandOffPreventStaleRelease() async {
        let locks = TransferPathLocks(), first = UUID(), second = UUID(), third = UUID()
        let key = "fixture"
        XCTAssertTrue(locks.tryAcquire(key, owner: first))
        var entered: [UUID] = [], granted: [UUID] = []
        let waiter2 = Task {
            entered.append(second); if await locks.acquire(key, owner: second) { granted.append(second) }
        }
        await until { entered.count == 1 }
        let waiter3 = Task {
            entered.append(third); if await locks.acquire(key, owner: third) { granted.append(third) }
        }
        await until { entered.count == 2 }
        locks.release(key, owner: UUID())
        XCTAssertTrue(granted.isEmpty)
        locks.release(key, owner: first)
        await waiter2.value
        XCTAssertEqual(granted, [second])
        locks.release(key, owner: first)
        XCTAssertFalse(locks.tryAcquire(key, owner: first))
        locks.release(key, owner: second)
        await waiter3.value
        XCTAssertEqual(granted, [second, third])
        locks.release(key, owner: third)
    }

    func testPartialCleanupDoesNotDeleteAFileOwnedByAnotherTransfer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let locks = TransferPathLocks(), fs = FileSystem(), owner = UUID()
        let task = UploadTask(
            files: [url], destDir: "/target", fs: fs, pathLocks: locks, notify: { _, _ in }, onAllDone: {})
        task.hostId = "host"
        task.items[0].state = .cancelled
        task.items[0].sent = 1
        task.items[0].partialMayExist = true
        let key = "up:host:/target/\(url.lastPathComponent)"
        XCTAssertTrue(locks.tryAcquire(key, owner: owner))
        task.cleanupPartials()
        await until { fs.closes == 1 }
        XCTAssertEqual(fs.cleanups, 0)
        locks.release(key, owner: owner)
    }

    private func makeQueue(_ limit: Int) -> TransferCoordinator<UploadTask> {
        TransferCoordinator(limit: limit, pausedReleasesSlot: true)
    }

    private func upload(
        _ fs: FileSystem, locks: TransferPathLocks, directory: String = "/target"
    ) -> UploadTask {
        let localDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = localDirectory.appendingPathComponent("file")
        do { try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true) }
        catch { XCTFail("Cannot create fixture: \(error)") }
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        addTeardownBlock { try? FileManager.default.removeItem(at: localDirectory) }
        let task = UploadTask(
            files: [url], destDir: directory,
            fs: fs, pathLocks: locks, notify: { _, _ in }, onAllDone: {})
        task.hostId = "host"
        return task
    }

    private func download(_ fs: FileSystem, locks: TransferPathLocks, url: URL) -> UploadTask {
        let file = RemoteFile(name: "file", path: "/source/file", kind: .file, size: 100, modified: nil)
        return UploadTask(
            download: [file], toLocalURLs: [url], inDir: url.deletingLastPathComponent(),
            fs: fs, pathLocks: locks, notify: { _, _ in }, onAllDone: {})
    }

    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), "Timed out waiting for lifecycle transition", file: file, line: line)
    }

    @MainActor
    private final class FileSystem: TransferFileSystem {
        var holdProbe = false
        var probes = 0, uploads = 0, downloads = 0, finalizations = 0, closes = 0, cleanups = 0
        var control: UploadControl?
        var destination: DownloadDestination?
        private var probeWaiter: CheckedContinuation<UploadProbe, Never>?
        private var ioWaiter: CheckedContinuation<UploadOutcome, Never>?

        func probeUpload(remotePath: String) async -> UploadProbe {
            probes += 1
            if holdProbe { return await withCheckedContinuation { probeWaiter = $0 } }
            return UploadProbe(partSize: nil, finalSize: nil)
        }
        func finishProbe(existing: Bool = false) {
            holdProbe = false
            let waiter = probeWaiter; probeWaiter = nil
            waiter?.resume(returning: UploadProbe(partSize: nil, finalSize: existing ? 10 : nil))
        }
        func upload(
            source: UploadSource, toRemote remotePath: String, startOffset: Int64, control: UploadControl
        ) async -> UploadOutcome {
            uploads += 1; self.control = control
            return await withCheckedContinuation { ioWaiter = $0 }
        }
        func download(
            _ remotePath: String, to destination: DownloadDestination, control: UploadControl
        ) async -> UploadOutcome {
            downloads += 1; self.control = control; self.destination = destination
            return await withCheckedContinuation { ioWaiter = $0 }
        }
        func complete(_ outcome: UploadOutcome) {
            let waiter = ioWaiter; ioWaiter = nil
            XCTAssertNotNil(waiter)
            waiter?.resume(returning: outcome)
        }
        func finalizeUpload(_ request: UploadCommit) async -> Result<Void, RemoteFSError> {
            finalizations += 1; return .success(())
        }
        func cleanupPart(remotePath: String) async { cleanups += 1 }
        func closeSession() { closes += 1 }
    }
}
