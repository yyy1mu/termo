import Darwin
import XCTest

@testable import Termo

final class UploadSourceTests: XCTestCase {
    func testSourceSeeksExactlyAndReopensTheSameVersion() async throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        let size = try await source.prepare()
        XCTAssertEqual(size, 6)
        XCTAssertEqual(try source.open(at: 2), 6)
        XCTAssertEqual(try source.read(upToCount: 2), Data("cd".utf8))
        XCTAssertEqual(try source.read(upToCount: 100), Data("ef".utf8))
        XCTAssertNil(try source.read(upToCount: 1))
        source.close()
        XCTAssertEqual(try source.open(at: 4), 6)
        XCTAssertEqual(try source.read(upToCount: 100), Data("ef".utf8))
        source.close()
    }

    func testInvalidOffsetsAndNonRegularFilesAreRejected() throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        XCTAssertThrowsError(try source.open(at: -1))
        XCTAssertThrowsError(try source.open(at: 7))
        XCTAssertEqual(try source.open(at: 0), 6)
        source.close()
        XCTAssertThrowsError(try UploadSource(url: fixture.directory).open(at: 0))
        let fifo = fixture.directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try UploadSource(url: fifo).open(at: 0))
    }

    func testMissingOrReplacedPathCannotResumeButANewAttemptCan() async throws {
        for remove in [false, true] {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
            _ = try await source.prepare()
            if remove {
                try FileManager.default.removeItem(at: fixture.url)
            } else {
                try Data("uvwxyz".utf8).write(to: fixture.url, options: .atomic)
            }
            XCTAssertThrowsError(try source.open(at: 3))
            if !remove {
                let restart = UploadSource(url: fixture.url)
                XCTAssertEqual(try restart.open(at: 0), 6)
                XCTAssertEqual(try restart.read(upToCount: 6), Data("uvwxyz".utf8))
                restart.close()
            }
        }
    }

    func testTruncationGrowthAndSameSizeModificationRejectFurtherReads() throws {
        for mutation in 0...2 {
            let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
            _ = try source.open(at: 0)
            XCTAssertEqual(try source.read(upToCount: 2), Data("ab".utf8))
            let writer = try FileHandle(forWritingTo: fixture.url)
            switch mutation {
            case 0: try writer.truncate(atOffset: 1)
            case 1: try writer.seekToEnd(); try writer.write(contentsOf: Data([1]))
            default: try writer.write(contentsOf: Data("123456".utf8))
            }
            try writer.close()
            XCTAssertThrowsError(try source.read(upToCount: 4))
            XCTAssertThrowsError(try source.validate())
            source.close()
        }
    }

    func testReplacingPathWhileOpenDoesNotSilentlyUploadDetachedInode() throws {
        let fixture = try UploadFixture(), source = UploadSource(url: fixture.url)
        _ = try source.open(at: 0)
        try Data("new".utf8).write(to: fixture.url, options: .atomic)
        XCTAssertThrowsError(try source.read(upToCount: 3))
        source.close()
    }

    func testEmptySourceAndSymlinkToARegularFileAreReadable() throws {
        let fixture = try UploadFixture(data: Data())
        let link = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.url)
        let source = UploadSource(url: link)
        XCTAssertEqual(try source.open(at: 0), 0)
        XCTAssertNil(try source.read(upToCount: 1))
        source.close()
    }
}

/// A real local file, shared by upload transport tests; no SSH credentials or application singleton.
final class UploadFixture {
    let directory: URL
    var url: URL { directory.appendingPathComponent("file") }
    init(data: Data = Data("abcdef".utf8)) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
