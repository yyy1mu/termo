import XCTest

@testable import Termo

final class RemoteDirectoryShellTests: XCTestCase {
    func testActualListingPreservesNamesMetadataAndSymlinkTypes() throws {
        let fixture = try UploadFixture()
        let directory = fixture.directory.appendingPathComponent("listing\n")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let names = ["a\nb", "a\tb", " quote' $`* @\n", ".hidden", "suffix@", "END"]
        for name in names { try Data("abc".utf8).write(to: directory.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("dangling"),
            withDestinationURL: directory.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("dir-link"),
            withDestinationURL: directory.appendingPathComponent("folder"))
        let result = try execute(directory.path)
        XCTAssertEqual(result.code, 0, String(decoding: result.stderr, as: UTF8.self))
        let files = try RemoteDirectoryListing.parse(result.data, directory: directory.path)
        XCTAssertEqual(Set(files.map(\.name)), Set(names + ["folder", "dangling", "dir-link"]))
        XCTAssertEqual(files.first?.name, "folder")
        for name in names {
            let file = try XCTUnwrap(files.first { $0.name == name })
            XCTAssertEqual(file.path, directory.path + "/" + name)
            XCTAssertEqual(file.kind, .file)
            XCTAssertEqual(file.size, 3)
            XCTAssertNotNil(file.modified)
        }
        XCTAssertEqual(files.first { $0.name == "dangling" }?.kind, .symlink)
        XCTAssertEqual(files.first { $0.name == "dir-link" }?.kind, .symlink)
    }

    func testDirectoryPathEndingInNewlineDoesNotReadItsTrimmedNeighbor() throws {
        let fixture = try UploadFixture(), directory = fixture.directory.appendingPathComponent("folder\n")
        let neighbor = fixture.directory.appendingPathComponent("folder")
        for path in [directory, neighbor] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        }
        try Data().write(to: directory.appendingPathComponent("correct"))
        try Data().write(to: neighbor.appendingPathComponent("wrong"))
        let result = try execute(directory.path)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(
            try RemoteDirectoryListing.parse(result.data, directory: directory.path).map(\.name), ["correct"])
    }

    func testEmptyDirectoryAndDirectorySymlinkHaveCompleteListings() throws {
        let fixture = try UploadFixture(), directory = fixture.directory.appendingPathComponent("empty")
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var result = try execute(directory.path)
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(try RemoteDirectoryListing.parse(result.data, directory: directory.path), [])
        try Data().write(to: directory.appendingPathComponent("child"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        result = try execute(alias.path)
        XCTAssertEqual(result.code, 0)
        let files = try RemoteDirectoryListing.parse(result.data, directory: alias.path)
        XCTAssertEqual(files.map(\.path), [alias.path + "/child"])
    }

    func testMissingDirectoryAndFileAreNotReportedAsEmptyDirectories() throws {
        let fixture = try UploadFixture()
        for path in [fixture.url.path, fixture.directory.appendingPathComponent("missing").path] {
            let result = try execute(path)
            XCTAssertNotEqual(result.code, 0)
            XCTAssertThrowsError(try RemoteDirectoryListing.parse(result.data, directory: path))
        }
    }

    func testFailedMetadataBatchDoesNotProduceACompletePartialListing() throws {
        let fixture = try UploadFixture(), bin = fixture.directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        try tool(
            "find", in: bin,
            body: """
                case "$*" in *-printf*) exit 1 ;; esac
                exec /usr/bin/find "$@"
                """)
        try tool(
            "stat", in: bin,
            body: """
                for argument do last=$argument; done
                if [ "$last" != . ]; then exit 1; fi
                exec /usr/bin/stat "$@"
                """)
        let result = try execute(fixture.directory.path, searchPath: bin.path + ":/usr/bin:/bin")
        XCTAssertNotEqual(result.code, 0)
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(result.data, directory: fixture.directory.path))
    }

    func testGNUFastBranchDoesNotInvokePerFileStat() throws {
        let fixture = try UploadFixture(), bin = fixture.directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        // The local host is BSD; emulate GNU find's wire output to exercise the capability branch.
        try tool(
            "find", in: bin,
            body: """
                if [ "$3" = 0 ]; then exit 0; fi
                printf 'f\\0' ; printf '3\\0' ; printf '123\\0' ; printf 'name\\n\\0'
                """)
        try tool("stat", in: bin, body: "exit 99")
        let result = try execute(fixture.directory.path, searchPath: bin.path + ":/usr/bin:/bin")
        XCTAssertEqual(result.code, 0)
        let files = try RemoteDirectoryListing.parse(result.data, directory: fixture.directory.path)
        XCTAssertEqual(files.map(\.name), ["name\n"])
        XCTAssertEqual(files.first?.size, 3)
    }

    func testGNUListingFailureDoesNotAcquireAnEndMarkerOrFallBackToEmptySuccess() throws {
        let fixture = try UploadFixture(), bin = fixture.directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: false)
        try tool(
            "find", in: bin,
            body: """
                if [ "$3" = 0 ]; then exit 0; fi
                printf 'f\\0' ; printf '3\\0' ; printf '123\\0' ; printf 'partial\\0'
                exit 1
                """)
        let result = try execute(fixture.directory.path, searchPath: bin.path + ":/usr/bin:/bin")
        XCTAssertNotEqual(result.code, 0)
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(result.data, directory: fixture.directory.path))
    }

    private func tool(_ name: String, in directory: URL, body: String) throws {
        let url = directory.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func execute(_ path: String, searchPath: String = "/usr/bin:/bin") throws -> RemoteFS.OpResult {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", RemoteDirectoryListing.shellCommand(path: path)]
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
