import XCTest

@testable import Termo

final class UploadShellStreamTests: XCTestCase {
    func testBinaryPullUsesVerifiedOffsetAndRequiresEOF() throws {
        let fixture = try UploadFixture(data: Data([0, 1, 2, 255, 10])), control = UploadControl()
        let source = UploadSource(url: fixture.url)
        var received = Data()
        let result = UploadShellStream.run(source: source, path: "/file", startOffset: 2, control: control) {
            _, pull in
            received = try self.drain(pull)
            return (0, 0)
        }
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(received, Data([2, 255, 10]))
        XCTAssertEqual(control.sent, 5)
        XCTAssertEqual(try source.open(at: 0), 5)
        source.close()
    }

    func testEarlySuccessAndRemoteFailureCannotBeReportedAsCompleted() throws {
        for code in [0, 1, 9] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
            let result = UploadShellStream.run(
                source: source, path: "/file", startOffset: 0, control: UploadControl()
            ) { _, _ in
                (0, code)  // A server may exit before consuming the input, even with exit code zero.
            }
            guard case .failed = result else { return XCTFail("Unexpected success") }
            XCTAssertEqual(try source.open(at: 0), 6)
            source.close()
        }
    }

    func testPauseAndCancellationRetainTheirMeaningWhenExecutorThrows() throws {
        for signal in [UploadSignal.cancel, .pause] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url),
                control = UploadControl()
            let result = UploadShellStream.run(
                source: source, path: "/file", startOffset: 0, control: control
            ) { _, pull in
                control.set(signal)
                _ = try self.drain(pull)
                return (0, 0)
            }
            XCTAssertEqual(result, signal == .cancel ? .cancelled : .paused)
            XCTAssertEqual(control.sent, 0)
            XCTAssertEqual(try source.open(at: 0), 6)
            source.close()
        }
    }

    func testLocalReadFailureRemainsVisibleAfterCallbackAbort() throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        let result = UploadShellStream.run(
            source: source, path: "/file", startOffset: 0, control: UploadControl()
        ) { _, pull in
            try Data("replacement".utf8).write(to: fixture.url, options: .atomic)
            _ = try self.drain(pull)
            return (0, 0)
        }
        XCTAssertEqual(result, .failed(UploadSource.changed().message))
    }

    func testSourceIsValidatedAfterRemoteCompletion() throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        let result = UploadShellStream.run(
            source: source, path: "/file", startOffset: 0, control: UploadControl()
        ) { _, pull in
            _ = try self.drain(pull)
            try Data("abcdef".utf8).write(to: fixture.url, options: .atomic)
            return (0, 0)
        }
        XCTAssertEqual(result, .failed(UploadSource.changed().message))
    }

    func testInvalidSourceAndCancelledRequestNeverExecuteRemoteCommand() throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url), control = UploadControl()
        try FileManager.default.removeItem(at: fixture.url)
        let failed = UploadShellStream.run(source: source, path: "/file", startOffset: 0, control: control) {
            _, _ in
            XCTFail("Missing source started remote command"); return (0, 0)
        }
        guard case .failed = failed else { return XCTFail("Expected missing source failure") }
        control.set(.cancel)
        let cancelled = UploadShellStream.run(source: source, path: "/file", startOffset: 0, control: control)
        { _, _ in
            XCTFail("Cancelled upload started remote command"); return (0, 0)
        }
        XCTAssertEqual(cancelled, .cancelled)
    }

    func testShellCommandRestartsResumesAndPreservesSpecialPathCharacters() throws {
        let fixture = try UploadFixture()
        let remote = fixture.directory.appendingPathComponent("a 'quoted' $file `literal`\n")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        XCTAssertEqual(try execute(path: remote.path, data: Data("abc".utf8), offset: 0, size: 3), 0)
        XCTAssertEqual(try Data(contentsOf: partial), Data("abc".utf8))
        XCTAssertEqual(try execute(path: remote.path, data: Data("def".utf8), offset: 3, size: 6), 0)
        XCTAssertEqual(try Data(contentsOf: partial), Data("abcdef".utf8))
        XCTAssertEqual(try execute(path: remote.path, data: Data(), offset: 0, size: 0), 0)
        XCTAssertEqual(try Data(contentsOf: partial), Data())
    }

    func testShellResumeRejectsMissingOrChangedPartialWithoutAppending() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        XCTAssertEqual(try execute(path: remote.path, data: Data("x".utf8), offset: 3, size: 4), 9)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try Data("other".utf8).write(to: partial)
        XCTAssertEqual(try execute(path: remote.path, data: Data("x".utf8), offset: 3, size: 4), 9)
        XCTAssertEqual(try String(contentsOf: partial), "other")
    }

    func testShellRejectsSymlinkDirectoryAndIncompleteInput() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: fixture.url)
        XCTAssertEqual(try execute(path: remote.path, data: Data([1]), offset: 0, size: 1), 9)
        XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
        try FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        XCTAssertEqual(try execute(path: remote.path, data: Data([1]), offset: 0, size: 1), 9)
        try FileManager.default.removeItem(at: partial)
        XCTAssertEqual(try execute(path: remote.path, data: Data([1]), offset: 0, size: 2), 9)
    }

    func testShellStatFailureCannotBecomeAValidResume() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part"),
            stat = fixture.directory.appendingPathComponent("stat")
        try Data("part".utf8).write(to: partial)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: stat)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stat.path)
        XCTAssertEqual(
            try execute(
                path: remote.path, data: Data([1]), offset: 4, size: 5,
                searchPath: fixture.directory.path + ":/usr/bin:/bin"), 9)
        XCTAssertEqual(try String(contentsOf: partial), "part")
    }

    func testProbeWriteFinalizeAndCleanupUseTheSamePathWithoutTouchingTrimmedNeighbor() throws {
        let fixture = try UploadFixture()
        let remote = fixture.directory.appendingPathComponent("name\n")
        let neighbor = fixture.directory.appendingPathComponent("name")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        let neighborPartial = URL(fileURLWithPath: neighbor.path + ".part")
        try Data("keep final".utf8).write(to: neighbor)
        try Data("keep partial".utf8).write(to: neighborPartial)
        let probe = try executeCommand(UploadPreflight.shellCommand(path: remote.path))
        XCTAssertEqual(probe.code, 0)
        XCTAssertEqual(try UploadPreflight.parse(probe.output), UploadProbe(partSize: nil, finalSize: nil))
        XCTAssertEqual(try execute(path: remote.path, data: Data("abc".utf8), offset: 0, size: 3), 0)
        XCTAssertEqual(try executeCommand(UploadShellCommands.finalize(.init(path: remote.path, size: 3, replaceExisting: false))).code, 0)
        XCTAssertEqual(try String(contentsOf: remote), "abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try Data("new partial".utf8).write(to: partial)
        XCTAssertEqual(try executeCommand(RemoteFileMutation.remove(remote.path + ".part", recursive: false).shellCommand).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try String(contentsOf: remote), "abc")
        XCTAssertEqual(try String(contentsOf: neighbor), "keep final")
        XCTAssertEqual(try String(contentsOf: neighborPartial), "keep partial")
    }

    func testShellCommitRequiresApprovalToReplaceAnExistingFile() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        try Data("original".utf8).write(to: remote)
        try Data("new".utf8).write(to: partial)
        let rejected = UploadShellCommands.finalize(.init(path: remote.path, size: 3, replaceExisting: false))
        XCTAssertEqual(try executeCommand(rejected).code, 11)
        XCTAssertEqual(try String(contentsOf: remote), "original")
        XCTAssertEqual(try String(contentsOf: partial), "new")
        let approved = UploadShellCommands.finalize(.init(path: remote.path, size: 3, replaceExisting: true))
        XCTAssertEqual(try executeCommand(approved).code, 0)
        XCTAssertEqual(try String(contentsOf: remote), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testShellCommitRejectsIncompleteMissingAndSymlinkPartial() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        try Data("original".utf8).write(to: remote)
        let command = UploadShellCommands.finalize(.init(path: remote.path, size: 6, replaceExisting: true))
        XCTAssertEqual(try executeCommand(command).code, 9)
        try Data("short".utf8).write(to: partial)
        XCTAssertEqual(try executeCommand(command).code, 9)
        XCTAssertEqual(try String(contentsOf: partial), "short")
        try FileManager.default.removeItem(at: partial)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: fixture.url)
        XCTAssertEqual(try executeCommand(command).code, 9)
        XCTAssertEqual(try String(contentsOf: remote), "original")
        XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
    }

    func testShellCommitDoesNotMovePartialInsideDirectoryOrReplaceSymlink() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        try Data("new".utf8).write(to: partial)
        let command = UploadShellCommands.finalize(.init(path: remote.path, size: 3, replaceExisting: true))
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: false)
        XCTAssertEqual(try executeCommand(command).code, 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: remote.path), [])
        try FileManager.default.removeItem(at: remote)
        let missing = fixture.directory.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: remote, withDestinationURL: missing)
        XCTAssertEqual(try executeCommand(command).code, 10)
        XCTAssertEqual(try String(contentsOf: partial), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testShellCommitDoesNotDeleteTargetWhenRenameFailsOrSkips() throws {
        for status in [0, 1] {
            let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("remote")
            let partial = URL(fileURLWithPath: remote.path + ".part")
            try Data("original".utf8).write(to: remote)
            try Data("new".utf8).write(to: partial)
            let mv = fixture.directory.appendingPathComponent("mv")
            try Data("#!/bin/sh\nexit \(status)\n".utf8).write(to: mv)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mv.path)
            let command = UploadShellCommands.finalize(.init(path: remote.path, size: 3, replaceExisting: true))
            XCTAssertNotEqual(try executeCommand(command, searchPath: fixture.directory.path + ":/usr/bin:/bin").code, 0)
            XCTAssertEqual(try String(contentsOf: remote), "original")
            XCTAssertEqual(try String(contentsOf: partial), "new")
        }
    }

    func testShellCommitAcceptsEmptyUploadedFile() throws {
        let fixture = try UploadFixture(), remote = fixture.directory.appendingPathComponent("empty")
        let partial = URL(fileURLWithPath: remote.path + ".part")
        try Data().write(to: partial)
        let command = UploadShellCommands.finalize(.init(path: remote.path, size: 0, replaceExisting: false))
        XCTAssertEqual(try executeCommand(command).code, 0)
        XCTAssertEqual(try Data(contentsOf: remote), Data())
    }

    private func drain(_ pull: UploadShellStream.Pull) throws -> Data {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 4)
        defer { buffer.deallocate() }
        var data = Data()
        while true {
            let count = pull(buffer, 4)
            if count < 0 { throw RemoteFSError(message: "executor aborted") }
            if count == 0 { return data }
            data.append(Data(bytes: buffer, count: Int(count)))
        }
    }

    private func execute(
        path: String, data: Data, offset: Int64, size: Int64,
        searchPath: String = "/usr/bin:/bin"
    ) throws -> Int32 {
        try executeCommand(
            UploadShellCommands.write(path: path, offset: offset, size: size),
            data: data, searchPath: searchPath
        ).code
    }

    private func executeCommand(
        _ command: String, data: Data = Data(),
        searchPath: String = "/usr/bin:/bin"
    ) throws -> (code: Int32, output: Data) {
        let input = try UploadFixture(data: data)
        let file = try FileHandle(forReadingFrom: input.url)
        defer { try? file.close() }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": searchPath, "LC_ALL": "C"]
        process.standardInput = file
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let received = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, received)
    }
}
