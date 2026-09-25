import XCTest

@testable import Termo

final class UploadStreamTests: XCTestCase {
    func testRestartAndResumeUseExactOffsetsAndCloseBothSides() async throws {
        for offset: Int64 in [0, 2, 6] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url),
                control = UploadControl()
            let destination = Destination(initialSize: UInt64(offset))
            let result = try await UploadStream.run(
                source: source, destination: destination, path: "/file", startOffset: offset, control: control
            )
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(control.sent, 6)
            let state = await destination.state()
            XCTAssertEqual(state.closes, 1)
            XCTAssertEqual(state.offsets, offset == 6 ? [] : [UInt64(offset)])
            XCTAssertEqual(state.data, Data("abcdef".utf8).dropFirst(Int(offset)))
            XCTAssertEqual(
                state.flags, offset == 0 ? SFTPFlag.WRITE | SFTPFlag.CREAT | SFTPFlag.TRUNC : SFTPFlag.WRITE)
            XCTAssertEqual(try source.open(at: 0), 6, "The prior attempt closed its local file")
            source.close()
        }
    }

    func testOpenedRemoteHandleClosesOnInitialStatWriteAndFinalStatErrors() async throws {
        for fault in [Fault.open, .initialStat, .write, .finalStat] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
            let destination = Destination(fault: fault)
            do {
                _ = try await UploadStream.run(
                    source: source, destination: destination, path: "/file", startOffset: 0,
                    control: UploadControl())
                XCTFail("Expected \(fault)")
            } catch {}
            let state = await destination.state()
            XCTAssertEqual(state.closes, fault == .open ? 0 : 1)
            XCTAssertEqual(try source.open(at: 0), 6)
            source.close()
        }
    }

    func testMissingSizeChangedOffsetAndNonRegularDestinationRejectWithoutWrites() async throws {
        for scenario in [Scenario.missingSize, .tooShort, .tooLong, .directory] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
            let destination = Destination(initialSize: 2, scenario: scenario)
            do {
                _ = try await UploadStream.run(
                    source: source, destination: destination, path: "/file", startOffset: 2,
                    control: UploadControl())
                XCTFail("Expected metadata failure")
            } catch { XCTAssertTrue(error is RemoteFSError) }
            let state = await destination.state()
            XCTAssertEqual(state.closes, 1)
            XCTAssertTrue(state.offsets.isEmpty)
        }
    }

    func testFinalRemoteSizeMismatchIsNotSuccess() async throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        let destination = Destination(scenario: .wrongFinalSize)
        do {
            _ = try await UploadStream.run(
                source: source, destination: destination, path: "/file", startOffset: 0,
                control: UploadControl())
            XCTFail("Expected verification failure")
        } catch { XCTAssertTrue(error is RemoteFSError) }
        let state = await destination.state()
        XCTAssertEqual(state.closes, 1)
    }

    func testCancelOrPauseDuringStatPreventsWrites() async throws {
        for signal in [UploadSignal.cancel, .pause] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url),
                control = UploadControl()
            let destination = Destination(afterStat: { control.set(signal) })
            let result = try await UploadStream.run(
                source: source, destination: destination, path: "/file", startOffset: 0, control: control)
            XCTAssertEqual(result, signal == .cancel ? .cancelled : .paused)
            let state = await destination.state()
            XCTAssertTrue(state.offsets.isEmpty)
            XCTAssertEqual(state.closes, 1)
        }
    }

    func testCancellationDuringWriteCountsAcknowledgedBytesButDoesNotComplete() async throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url), control = UploadControl()
        let destination = Destination(afterWrite: { control.set(.cancel) })
        let result = try await UploadStream.run(
            source: source, destination: destination, path: "/file", startOffset: 0, control: control)
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(control.sent, 6)
        let state = await destination.state()
        XCTAssertEqual(state.closes, 1)
    }

    func testLocalChangeDuringRemoteWriteRejectsCompletionAndClosesHandles() async throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        let url = fixture.url
        let destination = Destination(afterWrite: {
            try? Data("xxxxxx".utf8).write(to: url, options: .atomic)
        })
        do {
            _ = try await UploadStream.run(
                source: source, destination: destination, path: "/file", startOffset: 0,
                control: UploadControl())
            XCTFail("Expected changed source")
        } catch { XCTAssertTrue(error is RemoteFSError) }
        let state = await destination.state()
        XCTAssertEqual(state.closes, 1)
    }

    func testInvalidSourceAndCancellationCannotOpenRemoteFile() async throws {
        let fixture = try UploadFixture()
        try FileManager.default.removeItem(at: fixture.url)
        let destination = Destination(), source = UploadSource(url: fixture.url)
        do {
            _ = try await UploadStream.run(
                source: source, destination: destination, path: "/file", startOffset: 0,
                control: UploadControl())
            XCTFail("Expected missing local source")
        } catch {}
        let control = UploadControl(); control.set(.cancel)
        let result = try await UploadStream.run(
            source: source, destination: destination, path: "/file", startOffset: 0, control: control)
        XCTAssertEqual(result, .cancelled)
        let state = await destination.state()
        XCTAssertNil(state.flags)
        XCTAssertEqual(state.closes, 0)
    }

    func testEmptyFileStillVerifiesRemoteSizeAndCloses() async throws {
        let fixture = try UploadFixture(data: Data()), destination = Destination()
        let result = try await UploadStream.run(
            source: UploadSource(url: fixture.url), destination: destination, path: "/file", startOffset: 0,
            control: UploadControl())
        XCTAssertEqual(result, .completed)
        let state = await destination.state()
        XCTAssertTrue(state.offsets.isEmpty)
        XCTAssertEqual(state.closes, 1)
    }

    private enum Fault: Error { case open, initialStat, write, finalStat }
    private enum Scenario { case missingSize, tooShort, tooLong, directory, wrongFinalSize }
    private actor Destination: UploadDestination {
        var size: UInt64
        let fault: Fault?
        let scenario: Scenario?
        let afterStat: @Sendable () -> Void
        let afterWrite: @Sendable () -> Void
        var stats = 0, closes = 0
        var offsets: [UInt64] = []
        var flags: UInt32?
        var data = Data()
        init(
            initialSize: UInt64 = 0, fault: Fault? = nil, scenario: Scenario? = nil,
            afterStat: @escaping @Sendable () -> Void = {}, afterWrite: @escaping @Sendable () -> Void = {}
        ) {
            size = initialSize; self.fault = fault; self.scenario = scenario
            self.afterStat = afterStat; self.afterWrite = afterWrite
        }
        func open(_ path: String, pflags: UInt32) throws -> Data {
            flags = pflags
            if fault == .open { throw Fault.open }
            return Data([1])
        }
        func fstat(_ handle: Data) throws -> SFTPAttrs {
            stats += 1
            if stats == 1 && fault == .initialStat { throw Fault.initialStat }
            if stats > 1 && fault == .finalStat { throw Fault.finalStat }
            var attributes = SFTPAttrs()
            attributes.permissions = scenario == .directory ? 0o040755 : 0o100644
            attributes.size = size
            switch scenario {
            case .missingSize: attributes.size = nil
            case .tooShort: attributes.size = 1
            case .tooLong: attributes.size = 3
            case .wrongFinalSize where stats > 1: attributes.size = size + 1
            default: break
            }
            afterStat()
            return attributes
        }
        func write(_ handle: Data, offset: UInt64, data: Data) throws {
            if fault == .write { throw Fault.write }
            offsets.append(offset); self.data.append(data); size = offset + UInt64(data.count)
            afterWrite()
        }
        func closeHandle(_ handle: Data) { closes += 1 }
        func state() -> (closes: Int, offsets: [UInt64], flags: UInt32?, data: Data) {
            (closes, offsets, flags, data)
        }
    }
}
