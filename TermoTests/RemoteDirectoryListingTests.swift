import XCTest

@testable import Termo

final class RemoteDirectoryListingTests: XCTestCase {
    func testFramedRecordsPreserveSpecialNamesAndSortDirectoriesFirst() throws {
        let name = " tab\t newline\n quote' $ `星号* @\n"
        let files = try RemoteDirectoryListing.parse(
            stream([
                ["f", "3", "1700000000", name], ["l", "4", "0", "link@"], ["d", "0", "-1", "folder"],
            ]), directory: "/base\n/")
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first?.name, "folder")
        let file = try XCTUnwrap(files.first { $0.name == name })
        XCTAssertEqual(file.path, "/base\n/" + name)
        XCTAssertEqual(file.size, 3)
        XCTAssertEqual(file.modified?.timeIntervalSince1970, 1700000000)
        XCTAssertEqual(files.first { $0.name == "link@" }?.kind, .symlink)
    }

    func testEmptyDirectoryRequiresCompleteFrame() throws {
        XCTAssertEqual(try RemoteDirectoryListing.parse(stream([]), directory: "/"), [])
        for data in [Data(), Data("TERMO_DIRECTORY_1\0".utf8), Data("TERMO_DIRECTORY_1\0END".utf8)] {
            XCTAssertThrowsError(try RemoteDirectoryListing.parse(data, directory: "/"))
        }
    }

    func testEveryTruncatedPrefixAndTrailingGarbageAreRejected() throws {
        let data = stream([["f", "2", "10", "name\n"]])
        for count in 0..<data.count {
            XCTAssertThrowsError(try RemoteDirectoryListing.parse(data.prefix(count), directory: "/"))
        }
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(data + Data("noise".utf8), directory: "/"))
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(Data("banner\n".utf8) + data, directory: "/"))
    }

    func testInvalidFieldsDoNotSilentlyProducePartialOrZeroSizedResults() {
        for record in [
            ["x", "1", "1", "file"], ["f", "-1", "1", "file"], ["f", "+1", "1", "file"],
            ["f", "9223372036854775808", "1", "file"], ["f", "18446744073709551616", "1", "file"],
            ["f", "", "1", "file"], ["f", "1", "nan", "file"], ["f", "1", "inf", "file"],
            ["f", "1", "+1", "file"], ["f", "1", "1"], ["f", "1", "1", "file", "extra"],
        ] {
            XCTAssertThrowsError(
                try RemoteDirectoryListing.parse(stream([record]), directory: "/"), "\(record)")
        }
    }

    func testInvalidNamesAndDuplicatePathsAreRejected() throws {
        for name in ["", ".", "..", "../escape", "a/b", "bad\0name"] {
            XCTAssertThrowsError(
                try RemoteDirectoryListing.parse(stream([["f", "1", "1", name]]), directory: "/"))
            XCTAssertThrowsError(
                try RemoteDirectoryListing.entry(name: name, attributes: attributes(), directory: "/"))
        }
        let record = ["f", "1", "1", "duplicate"]
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(stream([record, record]), directory: "/"))
        let invalidUTF8 = Data("TERMO_DIRECTORY_1\0f\01\01\0".utf8) + Data([0xFF]) + Data("\0END\0".utf8)
        XCTAssertThrowsError(try RemoteDirectoryListing.parse(invalidUTF8, directory: "/"))
    }

    func testSFTPSizeIsCheckedBeforeSignedConversion() throws {
        let max = try RemoteDirectoryListing.entry(
            name: "max", attributes: attributes(size: UInt64(Int64.max)), directory: "/")
        XCTAssertEqual(max.size, Int64.max)
        for size in [UInt64(Int64.max) + 1, UInt64.max] {
            XCTAssertThrowsError(
                try RemoteDirectoryListing.entry(
                    name: "overflow", attributes: attributes(size: size), directory: "/"))
        }
        let unknown = try RemoteDirectoryListing.entry(
            name: "unknown", attributes: SFTPAttrs(), directory: "/")
        XCTAssertEqual(unknown.kind, .other)
        XCTAssertEqual(unknown.size, 0)
        XCTAssertNil(unknown.modified)
    }

    func testSFTPReadSkipsNavigationEntriesAndClosesDirectoryOnce() async throws {
        let session = Session(batches: [
            [(".", attributes()), ("..", attributes()), ("name\n", attributes(size: 7))]
        ])
        let files = try await RemoteDirectoryListing.read("/base", using: session)
        XCTAssertEqual(files.map(\.name), ["name\n"])
        XCTAssertEqual(files.first?.size, 7)
        let counts = await session.counts
        XCTAssertEqual(counts.reads, 2)
        XCTAssertEqual(counts.closes, 1)
    }

    func testSFTPReadAndDecodeFailuresCloseTheOpenedDirectory() async {
        for session in [
            Session(failRead: true), Session(batches: [[("file", attributes(size: UInt64.max))]]),
            Session(batches: [[("same", attributes()), ("same", attributes())]]),
        ] {
            do {
                _ = try await RemoteDirectoryListing.read("/base", using: session);
                XCTFail("Expected failure")
            } catch {}
            let counts = await session.counts
            XCTAssertEqual(counts.reads, 1)
            XCTAssertEqual(counts.closes, 1)
        }
    }

    func testSFTPOpenFailureDoesNotCloseAnUnopenedHandle() async {
        let session = Session(failOpen: true)
        do {
            _ = try await RemoteDirectoryListing.read("/base", using: session); XCTFail("Expected failure")
        } catch {}
        let counts = await session.counts
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.closes, 0)
    }

    private func stream(_ records: [[String]]) -> Data {
        Data((["TERMO_DIRECTORY_1"] + records.flatMap { $0 } + ["END", ""]).joined(separator: "\0").utf8)
    }
    private func attributes(size: UInt64 = 1) -> SFTPAttrs {
        var value = SFTPAttrs(); value.permissions = 0o100644; value.size = size; value.mtime = 10;
        return value
    }

    private actor Session: DirectoryListingSession {
        var counts = (reads: 0, closes: 0)
        var batches: [[(String, SFTPAttrs)]]
        let failOpen: Bool
        let failRead: Bool
        init(batches: [[(String, SFTPAttrs)]] = [], failOpen: Bool = false, failRead: Bool = false) {
            self.batches = batches; self.failOpen = failOpen; self.failRead = failRead
        }
        func opendir(_ path: String) async throws -> Data {
            if failOpen { throw RemoteFSError(message: "open fixture") }
            return Data([1])
        }
        func readdir(_ handle: Data) async throws -> [(name: String, attrs: SFTPAttrs)]? {
            XCTAssertEqual(handle, Data([1])); counts.reads += 1
            if failRead { throw RemoteFSError(message: "read fixture") }
            return batches.isEmpty ? nil : batches.removeFirst()
        }
        func closeHandle(_ handle: Data) async { XCTAssertEqual(handle, Data([1])); counts.closes += 1 }
    }
}
