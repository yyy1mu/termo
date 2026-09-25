import XCTest

@testable import Termo

final class DownloadStreamTests: XCTestCase {
    func testCompleteAndEmptyStreamsCommitAndCloseExactlyOnce() async throws {
        for payload in [Data(), Data("hello".utf8)] {
            let source = Source(data: payload), sink = Sink(), control = UploadControl()
            let result = try await DownloadStream.run(
                path: "/file", source: source, sink: sink, control: control)
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(sink.contents, payload)
            XCTAssertTrue(sink.committed)
            XCTAssertFalse(sink.isOpen)
            XCTAssertEqual(control.sent, Int64(payload.count))
            let counts = await source.counts()
            XCTAssertEqual(counts.opens, 1)
            XCTAssertEqual(counts.closes, 1)
        }
    }

    func testRemoteAndLocalErrorsAlwaysCloseOpenedHandles() async {
        for fault in [Fault.open, .stat, .read, .begin, .append, .finish] {
            let source = Source(data: Data([1]), fault: fault), sink = Sink(fault: fault)
            do {
                _ = try await DownloadStream.run(
                    path: "/file", source: source, sink: sink, control: UploadControl())
                XCTFail("Expected \(fault) failure")
            } catch {}
            let counts = await source.counts()
            XCTAssertEqual(counts.closes, fault == .open ? 0 : 1)
            XCTAssertFalse(sink.isOpen)
            XCTAssertFalse(sink.committed)
        }
    }

    func testInvalidOrChangedMetadataAndUnexpectedEOFPreventCommit() async {
        for scenario in [
            Scenario.missingSize, .oversizedSize, .shortBody, .longBody, .changedTime, .finalStatFailure,
        ] {
            let source = Source(data: Data([1, 2]), scenario: scenario), sink = Sink()
            do {
                _ = try await DownloadStream.run(
                    path: "/file", source: source, sink: sink, control: UploadControl())
                XCTFail("Expected \(scenario) failure")
            } catch {}
            let counts = await source.counts()
            XCTAssertEqual(counts.closes, 1)
            XCTAssertFalse(sink.committed)
            XCTAssertFalse(sink.isOpen)
        }
    }

    func testPreexistingCancellationAndPauseDoNotOpenRemoteFile() async throws {
        for signal in [UploadSignal.cancel, .pause] {
            let source = Source(data: Data([1])), sink = Sink(), control = UploadControl()
            control.set(signal)
            let result = try await DownloadStream.run(
                path: "/file", source: source, sink: sink, control: control)
            XCTAssertEqual(result, signal == .cancel ? .cancelled : .paused)
            let counts = await source.counts()
            XCTAssertEqual(counts.opens, 0)
            XCTAssertEqual(counts.closes, 0)
        }
    }

    func testCancellationOrPauseDuringReadDoesNotWriteReturnedChunk() async throws {
        for signal in [UploadSignal.cancel, .pause] {
            let control = UploadControl(), sink = Sink()
            let source = Source(data: Data([1, 2]), afterRead: { control.set(signal) })
            let result = try await DownloadStream.run(
                path: "/file", source: source, sink: sink, control: control)
            XCTAssertEqual(result, signal == .cancel ? .cancelled : .paused)
            XCTAssertEqual(sink.contents, Data())
            XCTAssertEqual(control.sent, 0)
            XCTAssertFalse(sink.isOpen)
            let counts = await source.counts()
            XCTAssertEqual(counts.closes, 1)
        }
    }

    func testCancellationDuringFinalStatPreventsCommit() async throws {
        let control = UploadControl(), sink = Sink()
        let source = Source(data: Data([1]), afterFinalStat: { control.set(.cancel) })
        let result = try await DownloadStream.run(path: "/file", source: source, sink: sink, control: control)
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(sink.committed)
        XCTAssertFalse(sink.isOpen)
        let counts = await source.counts()
        XCTAssertEqual(counts.closes, 1)
    }

    func testTaskCancellationBeforeRunDoesNotOpenFile() async throws {
        let source = Source(data: Data([1])), sink = Sink()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DownloadStream.run(
                path: "/file", source: source, sink: sink, control: UploadControl())
        }
        let result = try await task.value
        XCTAssertEqual(result, .cancelled)
        let counts = await source.counts()
        XCTAssertEqual(counts.opens, 0)
    }

    func testPausedDestinationResumesFromItsVerifiedOffset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("download"), control = UploadControl()
        let sink = DownloadDestination(url: url)
        _ = try sink.begin(version: DownloadVersion(size: 5, modified: 1))
        try sink.append(Data("he".utf8))
        try sink.suspend()
        let source = Source(data: Data("hello".utf8))
        let result = try await DownloadStream.run(path: "/file", source: source, sink: sink, control: control)
        XCTAssertEqual(result, .completed)
        let offsets = await source.offsets
        XCTAssertEqual(offsets, [2, 5])
        XCTAssertEqual(try String(contentsOf: url), "hello")
        XCTAssertEqual(control.sent, 5)
    }

    private enum Fault: Error { case open, stat, read, begin, append, finish }
    private enum Scenario {
        case missingSize, oversizedSize, shortBody, longBody, changedTime, finalStatFailure
    }

    private actor Source: DownloadSource {
        let data: Data
        let fault: Fault?
        let scenario: Scenario?
        let afterRead: @Sendable () -> Void
        let afterFinalStat: @Sendable () -> Void
        var offsets: [UInt64] = []
        var opens = 0, closes = 0, stats = 0

        init(
            data: Data, fault: Fault? = nil, scenario: Scenario? = nil,
            afterRead: @escaping @Sendable () -> Void = {},
            afterFinalStat: @escaping @Sendable () -> Void = {}
        ) {
            self.data = data; self.fault = fault; self.scenario = scenario
            self.afterRead = afterRead; self.afterFinalStat = afterFinalStat
        }
        func open(_ path: String, pflags: UInt32) throws -> Data {
            opens += 1
            if fault == .open { throw Fault.open }
            return Data([42])
        }
        func fstat(_ handle: Data) throws -> SFTPAttrs {
            stats += 1
            if fault == .stat || (stats > 1 && scenario == .finalStatFailure) { throw Fault.stat }
            var attributes = SFTPAttrs()
            attributes.size = UInt64(data.count)
            attributes.mtime = stats > 1 && scenario == .changedTime ? 2 : 1
            switch scenario {
            case .missingSize: attributes.size = nil
            case .oversizedSize: attributes.size = UInt64.max
            case .shortBody: attributes.size = UInt64(data.count + 1)
            case .longBody: attributes.size = UInt64(data.count - 1)
            default: break
            }
            if stats > 1 { afterFinalStat() }
            return attributes
        }
        func read(_ handle: Data, offset: UInt64, length: UInt32) throws -> Data? {
            offsets.append(offset)
            if fault == .read { throw Fault.read }
            afterRead()
            guard offset < data.count else { return nil }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))
        }
        func closeHandle(_ handle: Data) { closes += 1 }
        func counts() -> (opens: Int, closes: Int) { (opens, closes) }
    }

    /// Writes are sequential within the stream; snapshots are read only after awaiting its completion.
    private final class Sink: DownloadSink, @unchecked Sendable {
        let fault: Fault?
        var contents = Data()
        var committed = false
        var isOpen = false
        init(fault: Fault? = nil) { self.fault = fault }
        func begin(version: DownloadVersion) throws -> UInt64 {
            if fault == .begin { throw Fault.begin }
            isOpen = true
            return UInt64(contents.count)
        }
        func append(_ data: Data) throws {
            if fault == .append { throw Fault.append }
            contents.append(data)
        }
        func finish() throws {
            if fault == .finish { throw Fault.finish }
            committed = true
            isOpen = false
        }
        func suspend() { isOpen = false }
    }
}
