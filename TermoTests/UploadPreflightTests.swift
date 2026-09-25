import XCTest

@testable import Termo

final class UploadPreflightTests: XCTestCase {
    func testSFTPOnlyNoSuchFileMeansMissingAndZeroMeansExistingEmptyFile() async throws {
        let probe = try await UploadPreflight.read(path: "/file") { path in
            if path.hasSuffix(".part") { throw SFTPError(code: 2, message: "missing") }
            var attrs = SFTPAttrs(); attrs.size = 0; attrs.permissions = 0o100644
            return attrs
        }
        XCTAssertEqual(probe, UploadProbe(partSize: nil, finalSize: 0))
    }

    func testSFTPPermissionAndTransportErrorsCannotProduceMissingSnapshot() async {
        for error in [
            SFTPError(code: 3, message: "denied"),
            SFTPError(code: 0xF000, message: "offline", isTransport: true),
        ] {
            do {
                _ = try await UploadPreflight.read(path: "/file") { _ in throw error }
                XCTFail("An error became an absent file")
            } catch let received as SFTPError {
                XCTAssertEqual(received.code, error.code)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testSFTPRejectsUnknownSizeOverflowAndNonRegularTargets() async {
        let cases: [(UInt64?, UInt32?)] = [
            (nil, 0o100644), (.max, 0o100644), (1, nil), (1, 0o040755), (1, 0o120777),
        ]
        for (size, permissions) in cases {
            do {
                _ = try await UploadPreflight.read(path: "/file") { _ in
                    var attrs = SFTPAttrs(); attrs.size = size; attrs.permissions = permissions; return attrs
                }
                XCTFail("Accepted incomplete or unsupported metadata")
            } catch { XCTAssertTrue(error is RemoteFSError) }
        }
    }

    func testShellParserRejectsMalformedTruncatedOverflowAndNegativeSizes() throws {
        XCTAssertEqual(
            try UploadPreflight.parse(Data("TERMO_UPLOAD_PROBE_1 missing 0\n".utf8)),
            UploadProbe(partSize: nil, finalSize: 0))
        for output in [
            "", "0 0 0", "TERMO_UPLOAD_PROBE_1 1", "TERMO_UPLOAD_PROBE_1 -1 missing",
            "TERMO_UPLOAD_PROBE_1 18446744073709551615 0", "TERMO_UPLOAD_PROBE_1 +1 0",
            "TERMO_UPLOAD_PROBE_1 1 missing extra", "banner\nTERMO_UPLOAD_PROBE_1 1 0",
        ] {
            XCTAssertThrowsError(try UploadPreflight.parse(Data(output.utf8)), output)
        }
    }

    func testShellProbeHandlesQuotedNamesAndDistinguishesMissingAndEmpty() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a 'quoted' $file\n")
        let absent = try runProbe(file.path)
        XCTAssertEqual(absent.code, 0)
        XCTAssertEqual(try UploadPreflight.parse(absent.data), UploadProbe(partSize: nil, finalSize: nil))
        try Data().write(to: file)
        try Data("part".utf8).write(to: URL(fileURLWithPath: file.path + ".part"))
        let present = try runProbe(file.path)
        XCTAssertEqual(present.code, 0)
        XCTAssertEqual(try UploadPreflight.parse(present.data), UploadProbe(partSize: 4, finalSize: 0))
    }

    func testShellProbeFailsForMissingParentDirectoriesAndSymlinks() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNotEqual(try runProbe(directory.appendingPathComponent("absent/file").path).code, 0)
        XCTAssertNotEqual(try runProbe(directory.path).code, 0)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: directory.appendingPathComponent("absent"))
        XCTAssertNotEqual(try runProbe(link.path).code, 0)
    }

    func testShellStatFailureCannotBecomeAnAbsentOrZeroLengthFile() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file"), stat = directory.appendingPathComponent("stat")
        try Data("existing".utf8).write(to: file)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: stat)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stat.path)
        let result = try runProbe(file.path, searchPath: directory.path + ":/usr/bin:/bin")
        XCTAssertNotEqual(result.code, 0)
        XCTAssertThrowsError(try UploadPreflight.parse(result.data))
    }

    func testRestartAndResumeHaveDistinctPlansAndOversizedPartialCannotBeFinalized() throws {
        let partial = UploadProbe(partSize: 4, finalSize: nil)
        XCTAssertEqual(
            try UploadWritePlan.make(probe: partial, localSize: 10, policy: .restart), .write(offset: 0))
        XCTAssertEqual(
            try UploadWritePlan.make(probe: partial, localSize: 10, policy: .resume), .write(offset: 4))
        let complete = UploadProbe(partSize: 10, finalSize: nil)
        XCTAssertEqual(try UploadWritePlan.make(probe: complete, localSize: 10, policy: .resume), .finalize)
        XCTAssertEqual(
            try UploadWritePlan.make(probe: complete, localSize: 10, policy: .automatic), .write(offset: 0))
        let oversized = UploadProbe(partSize: 11, finalSize: nil)
        XCTAssertThrowsError(try UploadWritePlan.make(probe: oversized, localSize: 10, policy: .resume))
        XCTAssertThrowsError(try UploadWritePlan.make(probe: oversized, localSize: 10, policy: .automatic))
        XCTAssertEqual(
            try UploadWritePlan.make(probe: oversized, localSize: 10, policy: .restart), .write(offset: 0))
    }

    private func tempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runProbe(
        _ path: String, searchPath: String = "/usr/bin:/bin"
    ) throws -> (code: Int32, data: Data) {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UploadPreflight.shellCommand(path: path)]
        process.environment = ["PATH": searchPath, "LC_ALL": "C"]
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
