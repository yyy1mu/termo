import XCTest

@testable import Termo

@MainActor
final class UploadRecoveryTests: XCTestCase {
    func testProbeFailureIsVisibleWithoutWritingAndOtherFilesCanContinue() async throws {
        let fixture = try Fixture(count: 2)
        fixture.fs.snapshots = [
            .failure(RemoteFSError(message: "permission fixture")),
            .success(.init(partSize: nil, finalSize: nil)),
        ]
        fixture.start()
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .failed("permission fixture"))
        XCTAssertEqual(fixture.task.items[1].state, .done)
        XCTAssertEqual(fixture.fs.offsets, [0])
        XCTAssertEqual(fixture.fs.finalizations, 1)
        XCTAssertNil(fixture.task.pendingAsk)
    }

    func testRestartIgnoresOldPartialAndResetsDisplayedProgress() async throws {
        let fixture = try Fixture()
        fixture.fs.snapshots = [.success(.init(partSize: 4, finalSize: nil))]
        fixture.fs.outcomes = [.failed("interrupted"), .completed]
        fixture.start()
        await done(fixture.task)
        XCTAssertEqual(fixture.fs.offsets, [4])
        fixture.task.items[0].sent = 7
        fixture.queue.retry(fixture.task, resume: false)
        XCTAssertEqual(fixture.task.items[0].sent, 0)
        await done(fixture.task)
        XCTAssertEqual(fixture.fs.offsets, [4, 0])
        XCTAssertEqual(fixture.task.items[0].state, .done)
    }

    func testResumeUsesFreshRemoteSizeInsteadOfLastDisplayedProgress() async throws {
        let fixture = try Fixture()
        fixture.fs.outcomes = [.failed("interrupted"), .completed]
        fixture.start()
        await done(fixture.task)
        fixture.task.items[0].sent = 9
        fixture.fs.snapshots = [.success(.init(partSize: 3, finalSize: nil))]
        fixture.queue.retry(fixture.task, resume: true)
        await done(fixture.task)
        XCTAssertEqual(fixture.fs.offsets, [0, 3])
    }

    func testFinalizationFailureRetainsCompletePartialAndRetryCanFinalizeWithoutReuploading() async throws {
        let fixture = try Fixture()
        fixture.fs.finalResults = [.failure(RemoteFSError(message: "rename denied")), .success(())]
        fixture.start()
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .failed("rename denied"))
        XCTAssertTrue(fixture.task.hasPartials)
        fixture.fs.snapshots = [.success(.init(partSize: 10, finalSize: nil))]
        fixture.queue.retry(fixture.task, resume: true)
        await done(fixture.task)
        XCTAssertEqual(fixture.fs.offsets, [0])
        XCTAssertEqual(fixture.fs.finalizations, 2)
        XCTAssertFalse(fixture.task.hasPartials)
        XCTAssertEqual(fixture.task.items[0].state, .done)
    }

    func testOversizedPartialFailsWithoutWritingUntilUserChoosesRestart() async throws {
        let fixture = try Fixture()
        fixture.fs.snapshots = [.success(.init(partSize: 11, finalSize: nil))]
        fixture.start()
        await done(fixture.task)
        XCTAssertTrue(fixture.task.hasFailures)
        XCTAssertTrue(fixture.fs.offsets.isEmpty)
        XCTAssertEqual(fixture.fs.finalizations, 0)
        fixture.queue.retry(fixture.task, resume: false)
        await done(fixture.task)
        XCTAssertEqual(fixture.fs.offsets, [0])
        XCTAssertEqual(fixture.task.items[0].state, .done)
    }

    func testResumeStillRequiresOverwriteApprovalWhenFinalFileExists() async throws {
        let fixture = try Fixture()
        fixture.fs.outcomes = [.failed("interrupted"), .completed]
        fixture.start()
        await done(fixture.task)
        fixture.fs.snapshots = [.success(.init(partSize: 4, finalSize: 6))]
        fixture.queue.retry(fixture.task, resume: true)
        await until { fixture.task.pendingAsk != nil }
        XCTAssertEqual(fixture.fs.offsets, [0])
        XCTAssertEqual(fixture.fs.finalizations, 0)
        fixture.task.resolveAsk(.skip)
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .skipped)
        XCTAssertEqual(fixture.fs.offsets, [0])
    }

    func testChangedLocalFileCannotResumeOrFinalizeOldPartialButExplicitRestartWorks() async throws {
        let fixture = try Fixture()
        fixture.fs.outcomes = [.failed("interrupted"), .completed]
        fixture.start()
        await done(fixture.task)
        let original = try XCTUnwrap(fixture.task.items[0].uploadSource)
        try Data(repeating: 66, count: 10).write(to: fixture.task.items[0].url, options: .atomic)
        fixture.fs.snapshots = [.success(.init(partSize: 10, finalSize: nil))]
        fixture.queue.retry(fixture.task, resume: true)
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .failed(UploadSource.changed().message))
        XCTAssertEqual(fixture.fs.offsets, [0])
        XCTAssertEqual(fixture.fs.finalizations, 0)
        fixture.queue.retry(fixture.task, resume: false)
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .done)
        XCTAssertEqual(fixture.fs.offsets, [0, 0])
        XCTAssertFalse(original === fixture.task.items[0].uploadSource)
    }

    func testQueuedUploadUsesActualSourceSizeWhenItStarts() async throws {
        let fixture = try Fixture()
        try Data(repeating: 65, count: 5).write(to: fixture.task.items[0].url)
        fixture.start()
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .done)
        XCTAssertEqual(fixture.task.totalBytes, 5)
        XCTAssertEqual(fixture.task.items[0].sent, 5)
    }

    func testSourceChangeAfterUploadPreventsFinalization() async throws {
        let fixture = try Fixture()
        fixture.fs.onUpload = { source in
            try? Data(repeating: 90, count: 10).write(to: source.url, options: .atomic)
        }
        fixture.start()
        await done(fixture.task)
        XCTAssertEqual(fixture.task.items[0].state, .failed(UploadSource.changed().message))
        XCTAssertTrue(fixture.task.hasPartials)
        XCTAssertEqual(fixture.fs.finalizations, 0)
    }

    func testFinalCommitCarriesSourceSizeAndOnlyExplicitOverwriteApproval() async throws {
        for existing in [false, true] {
            let fixture = try Fixture()
            fixture.fs.snapshots = [.success(.init(partSize: nil, finalSize: existing ? 3 : nil))]
            fixture.start()
            if existing {
                await until { fixture.task.pendingAsk != nil }
                fixture.task.resolveAsk(.overwrite)
            }
            await done(fixture.task)
            XCTAssertEqual(fixture.fs.commits, [UploadCommit(path: "/fixture/file0", size: 10,
                                                            replaceExisting: existing)])
        }
    }

    private func done(_ task: UploadTask) async { await until { task.phase.isFinished } }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(predicate(), "Timed out waiting for upload", file: file, line: line)
    }

    @MainActor
    private final class Fixture {
        let directory: URL
        let fs = FileSystem()
        let queue = TransferCoordinator<UploadTask>(limit: 1, pausedReleasesSlot: true)
        let task: UploadTask

        init(count: Int = 1) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            self.directory = directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try (0..<count).map { index in
                let url = directory.appendingPathComponent("file\(index)")
                try Data(repeating: 65, count: 10).write(to: url)
                return url
            }
            task = UploadTask(files: files, destDir: "/fixture", fs: fs, notify: { _, _ in }, onAllDone: {})
        }
        func start() { queue.enqueue(task) }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    @MainActor
    private final class FileSystem: TransferFileSystem {
        var snapshots: [Result<UploadProbe, RemoteFSError>] = [.success(.init(partSize: nil, finalSize: nil))]
        var outcomes: [UploadOutcome] = [.completed]
        var finalResults: [Result<Void, RemoteFSError>] = [.success(())]
        var offsets: [Int64] = []
        var finalizations = 0
        var commits: [UploadCommit] = []
        var onUpload: (UploadSource) -> Void = { _ in }
        func probeUpload(remotePath: String) async throws -> UploadProbe {
            try (snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0]).get()
        }
        func upload(
            source: UploadSource, toRemote remotePath: String, startOffset: Int64, control: UploadControl
        ) async -> UploadOutcome {
            offsets.append(startOffset)
            onUpload(source)
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
        func download(
            _ remotePath: String, to destination: DownloadDestination, control: UploadControl
        ) async -> UploadOutcome {
            XCTFail("Upload invoked download"); return .failed("unexpected")
        }
        func finalizeUpload(_ request: UploadCommit) async -> Result<Void, RemoteFSError> {
            finalizations += 1
            commits.append(request)
            return finalResults.count > 1 ? finalResults.removeFirst() : finalResults[0]
        }
        func cleanupPart(remotePath: String) async {}
        func closeSession() {}
    }
}
