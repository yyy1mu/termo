import XCTest

@testable import Termo

final class RemoteFileMutationShellTests: XCTestCase {
    func testCreateRenameChmodAndDeletePreserveExactSpecialPaths() async throws {
        let fixture = try UploadFixture()
        let source = fixture.directory.appendingPathComponent("source '$`\n\n")
        let target = fixture.directory.appendingPathComponent("target '$`\n\n")
        let neighbor = fixture.directory.appendingPathComponent("source '$`")
        let targetNeighbor = fixture.directory.appendingPathComponent("target '$`")
        try Data("keep source neighbor".utf8).write(to: neighbor)
        try Data("keep target neighbor".utf8).write(to: targetNeighbor)
        try await perform(.createFile(source.path)).get()
        try Data("content".utf8).write(to: source)
        try await perform(.permissions(source.path, try XCTUnwrap(FilePermissionMode("600")))).get()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try await perform(.rename(from: source.path, to: target.path)).get()
        XCTAssertEqual(try String(contentsOf: target), "content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        try await perform(.remove(target.path, recursive: false)).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try String(contentsOf: neighbor), "keep source neighbor")
        XCTAssertEqual(try String(contentsOf: targetNeighbor), "keep target neighbor")
    }

    func testCreateAndRecursivelyRemoveDirectoryDoNotTouchTrimmedNeighbor() async throws {
        let fixture = try UploadFixture(), directory = fixture.directory.appendingPathComponent("folder\n")
        let neighbor = fixture.directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: neighbor.appendingPathComponent("child"))
        try await perform(.createDirectory(directory.path)).get()
        try Data("remove".utf8).write(to: directory.appendingPathComponent("child"))
        try await perform(.remove(directory.path, recursive: true)).get()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: neighbor.appendingPathComponent("child")), "keep")
    }

    func testRenameRefusesExistingFileDirectoryAndDanglingSymlink() async throws {
        for kind in 0..<3 {
            let fixture = try UploadFixture(), target = fixture.directory.appendingPathComponent("target")
            let missing = fixture.directory.appendingPathComponent("missing")
            switch kind {
            case 0: try Data("keep".utf8).write(to: target)
            case 1: try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)
            }
            let result = try await perform(.rename(from: fixture.url.path, to: target.path))
            guard case .failure(let error) = result else { return XCTFail("Overwrote target") }
            XCTAssertEqual(error.message, String(localized: "目标名称已存在"))
            XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
            switch kind {
            case 0: XCTAssertEqual(try String(contentsOf: target), "keep")
            case 1: XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
            default:
                XCTAssertEqual(
                    try FileManager.default.destinationOfSymbolicLink(atPath: target.path), missing.path)
            }
        }
    }

    func testExclusiveCreateDoesNotOverwriteFileOrFollowDanglingSymlink() async throws {
        let fixture = try UploadFixture(), target = fixture.directory.appendingPathComponent("target")
        let missing = fixture.directory.appendingPathComponent("missing")
        let exists = try await perform(.createFile(fixture.url.path))
        guard case .failure = exists else { return XCTFail("Truncated existing file") }
        XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)
        let symlink = try await perform(.createFile(target.path))
        guard case .failure = symlink else { return XCTFail("Followed dangling symlink") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testMovingDanglingSourceSymlinkIsAllowed() async throws {
        let fixture = try UploadFixture(), source = fixture.directory.appendingPathComponent("source")
        let target = fixture.directory.appendingPathComponent("target")
        let missing = fixture.directory.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: missing)
        try await perform(.rename(from: source.path, to: target.path)).get()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSkippedOrFailedRenameIsNotReportedAsSuccessAndNeverDeletesSource() async throws {
        for status in [0, 1] {
            let fixture = try UploadFixture(), target = fixture.directory.appendingPathComponent("target")
            let mv = fixture.directory.appendingPathComponent("mv")
            try Data("#!/bin/sh\nexit \(status)\n".utf8).write(to: mv)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mv.path)
            let result = try await perform(
                .rename(from: fixture.url.path, to: target.path),
                searchPath: fixture.directory.path + ":/usr/bin:/bin")
            guard case .failure = result else { return XCTFail("False rename success") }
            XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    private func perform(
        _ operation: RemoteFileMutation, searchPath: String = "/usr/bin:/bin"
    ) async throws -> Result<Void, RemoteFSError> {
        await operation.perform(
            using: nil,
            shell: { command in
                do { return try self.execute(command, searchPath: searchPath) } catch {
                    XCTFail("Unable to run fixture: \(error)");
                    return .init(data: Data(), stderr: Data(), code: -1)
                }
            }, didLoseSFTP: { XCTFail("Shell operation invalidated SFTP") })
    }

    private func execute(_ command: String, searchPath: String) throws -> RemoteFS.OpResult {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": searchPath, "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .init(data: data, stderr: stderr, code: process.terminationStatus)
    }
}
