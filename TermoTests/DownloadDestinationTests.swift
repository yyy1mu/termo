import Darwin
import XCTest

@testable import Termo

final class DownloadDestinationTests: XCTestCase {
    func testCompleteFileAppearsOnlyAfterCommitAndDiscardPreservesIt() throws {
        let fixture = try Fixture()
        let destination = DownloadDestination(url: fixture.url)
        XCTAssertEqual(try destination.begin(version: DownloadVersion(size: 3)), 0)
        try destination.append(Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
        try destination.finish()
        XCTAssertTrue(destination.discard())
        XCTAssertEqual(try Data(contentsOf: fixture.url), Data("abc".utf8))
        XCTAssertEqual(try fixture.names(), ["download"])
    }

    func testEmptyDownloadCommitsAnEmptyFile() throws {
        let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
        _ = try destination.begin(version: DownloadVersion(size: 0))
        try destination.finish()
        XCTAssertEqual(try Data(contentsOf: fixture.url), Data())
    }

    func testExistingFileDirectoryAndDanglingSymlinkAreNeverOverwritten() throws {
        for kind in 0...2 {
            let fixture = try Fixture()
            switch kind {
            case 0: try Data("existing".utf8).write(to: fixture.url)
            case 1:
                try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
            default:
                try FileManager.default.createSymbolicLink(
                    atPath: fixture.url.path, withDestinationPath: "missing")
            }
            let destination = DownloadDestination(url: fixture.url)
            XCTAssertThrowsError(try destination.begin(version: DownloadVersion(size: 0)))
            XCTAssertTrue(destination.discard())
            XCTAssertEqual(try fixture.names(), ["download"])
            if kind == 0 { XCTAssertEqual(try String(contentsOf: fixture.url), "existing") }
            if kind == 2 {
                XCTAssertEqual(
                    try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path), "missing")
            }
        }
    }

    func testFileAppearingBeforeCommitIsPreserved() throws {
        let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
        _ = try destination.begin(version: DownloadVersion(size: 3))
        try destination.append(Data("abc".utf8))
        try Data("other owner".utf8).write(to: fixture.url)
        XCTAssertThrowsError(try destination.finish())
        XCTAssertTrue(destination.discard())
        XCTAssertEqual(try String(contentsOf: fixture.url), "other owner")
        XCTAssertEqual(try fixture.names(), ["download"])
    }

    func testPauseResumeUsesOwnedCheckpointAndExactOffset() throws {
        let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
        let version = DownloadVersion(size: 6, modified: 20)
        _ = try destination.begin(version: version)
        try destination.append(Data("abc".utf8))
        try destination.suspend()
        XCTAssertEqual(try destination.begin(version: version), 3)
        try destination.append(Data("def".utf8))
        try destination.finish()
        XCTAssertEqual(try String(contentsOf: fixture.url), "abcdef")
    }

    func testMissingOrModifiedPartialCannotResumeWithAHole() throws {
        for remove in [true, false] {
            let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
            let version = DownloadVersion(size: 6)
            _ = try destination.begin(version: version)
            try destination.append(Data("abc".utf8))
            try destination.suspend()
            let partial = try fixture.partial()
            if remove {
                try FileManager.default.removeItem(at: partial)
            } else {
                let file = try FileHandle(forWritingTo: partial)
                try file.truncate(atOffset: 1)
                try file.close()
            }
            XCTAssertThrowsError(try destination.begin(version: version))
            XCTAssertTrue(destination.discard())
            XCTAssertEqual(try fixture.names(), [])
        }
    }

    func testReplacedPartialIsNeitherResumedNorDeleted() throws {
        let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
        let version = DownloadVersion(size: 6)
        _ = try destination.begin(version: version)
        try destination.append(Data("abc".utf8))
        try destination.suspend()
        let partial = try fixture.partial()
        try Data("replacement".utf8).write(to: partial, options: .atomic)
        XCTAssertThrowsError(try destination.begin(version: version))
        XCTAssertTrue(destination.discard())
        XCTAssertEqual(try String(contentsOf: partial), "replacement")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testChangedRemoteVersionAndIncompleteLocalFileCannotCommit() throws {
        let fixture = try Fixture(), destination = DownloadDestination(url: fixture.url)
        _ = try destination.begin(version: DownloadVersion(size: 6, modified: 20))
        try destination.append(Data("abc".utf8))
        XCTAssertThrowsError(try destination.finish())
        try destination.suspend()
        XCTAssertThrowsError(try destination.begin(version: DownloadVersion(size: 6, modified: 21)))
        destination.discard()
        XCTAssertEqual(try fixture.names(), [])
    }

    func testParentReplacementRejectsCommitAndCleansOriginalDirectory() throws {
        let fixture = try Fixture()
        let original = fixture.directory.appendingPathComponent("original")
        let moved = fixture.directory.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let destination = DownloadDestination(url: original.appendingPathComponent("download"))
        _ = try destination.begin(version: DownloadVersion(size: 1))
        try destination.append(Data([1]))
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: original.appendingPathComponent("download"))
        XCTAssertThrowsError(try destination.finish())
        XCTAssertTrue(destination.discard())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), [])
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("download")), "keep")
    }

    func testUnsupportedExclusiveRenameCopiesWithoutOverwriting() throws {
        for collision in [false, true] {
            let fixture = try Fixture()
            let destination = DownloadDestination(
                url: fixture.url, rename: { _, _, _ in throw POSIXError(.ENOTSUP) })
            let data = Data(repeating: 42, count: 150_000)
            _ = try destination.begin(version: DownloadVersion(size: UInt64(data.count)))
            try destination.append(data)
            if collision {
                try Data("keep".utf8).write(to: fixture.url)
                XCTAssertThrowsError(try destination.finish())
                destination.discard()
                XCTAssertEqual(try String(contentsOf: fixture.url), "keep")
            } else {
                try destination.finish()
                XCTAssertEqual(try Data(contentsOf: fixture.url), data)
            }
            XCTAssertEqual(try fixture.names(), ["download"])
        }
    }

    func testOversizedAppendAndCommitIOFailureLeaveNoFinalFile() throws {
        let fixture = try Fixture()
        let destination = DownloadDestination(url: fixture.url, rename: { _, _, _ in throw POSIXError(.EIO) })
        _ = try destination.begin(version: DownloadVersion(size: 1))
        XCTAssertThrowsError(try destination.append(Data([1, 2])))
        try destination.append(Data([1]))
        XCTAssertThrowsError(try destination.finish())
        XCTAssertTrue(destination.discard())
        XCTAssertEqual(try fixture.names(), [])
    }

    private final class Fixture {
        let directory: URL
        var url: URL { directory.appendingPathComponent("download") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        }
        func partial() throws -> URL {
            directory.appendingPathComponent(
                try XCTUnwrap(names().first { $0.hasPrefix(".termo-download-") }))
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }
}
