import XCTest

@testable import Termo

final class RemoteFileMutationTests: XCTestCase {
    func testSFTPTransportFailureNeverReplaysMutationThroughShell() async throws {
        let permissions = try XCTUnwrap(FilePermissionMode("640"))
        let operations: [RemoteFileMutation] = [
            .createDirectory("/dir"), .remove("/file", recursive: false),
            .rename(from: "/from", to: "/to"), .permissions("/file", permissions),
        ]
        for operation in operations {
            let session = Session(error: SFTPError(code: 0xF001, message: "lost reply", isTransport: true))
            var lost = 0
            let result = await operation.perform(
                using: session,
                shell: { _ in
                    XCTFail("Uncertain mutation was replayed"); return Self.reply()
                }, didLoseSFTP: { lost += 1 })
            guard case .failure(let error) = result else { return XCTFail("False success") }
            XCTAssertTrue(error.message.contains("未确认"))
            XCTAssertEqual(lost, 1)
            XCTAssertEqual(session.mutations, 1)
        }
    }

    func testSFTPBusinessFailureRetainsErrorWithoutChangingTransport() async {
        for code: UInt32 in [3, 4, 8] {
            let session = Session(error: SFTPError(code: code, message: "server fixture"))
            let result = await RemoteFileMutation.remove("/file", recursive: false).perform(
                using: session,
                shell: { _ in
                    XCTFail("Business failure invoked shell"); return Self.reply()
                },
                didLoseSFTP: { XCTFail("Business failure invalidated SFTP") })
            guard case .failure(let error) = result else { return XCTFail("False success") }
            XCTAssertEqual(error.message, code == 3 ? String(localized: "没有删除权限") : "server fixture")
            XCTAssertEqual(session.mutations, 1)
        }
    }

    func testSuccessfulSFTPDoesNotInvokeShell() async throws {
        let session = Session()
        let result = await RemoteFileMutation.createDirectory("/dir").perform(
            using: session,
            shell: { _ in
                XCTFail("Successful SFTP invoked shell"); return Self.reply()
            },
            didLoseSFTP: { XCTFail("Successful SFTP invalidated transport") })
        try result.get()
        XCTAssertEqual(session.mutations, 1)
    }

    func testExistingTargetIncludingDanglingSymlinkStopsRename() async {
        for mode: UInt32 in [0o100644, 0o040755, 0o120777] {
            var attributes = SFTPAttrs(); attributes.permissions = mode
            let session = Session(target: attributes)
            let result = await RemoteFileMutation.rename(from: "/from", to: "/to").perform(
                using: session,
                shell: { _ in
                    XCTFail("Target conflict invoked shell"); return Self.reply()
                }, didLoseSFTP: {})
            guard case .failure(let error) = result else { return XCTFail("Replaced existing target") }
            XCTAssertEqual(error.message, String(localized: "目标名称已存在"))
            XCTAssertEqual(session.mutations, 0)
        }
    }

    func testTargetInspectionFailureCannotBeTreatedAsAbsence() async {
        for code: UInt32 in [3, 4, 0xF001] {
            let error = SFTPError(code: code, message: "inspection fixture", isTransport: code >= 0xF000)
            let session = Session(statError: error)
            var lost = 0
            let result = await RemoteFileMutation.rename(from: "/from", to: "/to").perform(
                using: session,
                shell: { _ in
                    XCTFail("Unknown target invoked shell"); return Self.reply()
                },
                didLoseSFTP: { lost += 1 })
            guard case .failure = result else { return XCTFail("Unknown target accepted") }
            XCTAssertEqual(session.mutations, 0)
            XCTAssertEqual(lost, code >= 0xF000 ? 1 : 0)
        }
    }

    func testMissingRenameSourceIsNotReportedAsExistingDestination() async {
        let session = Session(error: SFTPError(code: 2, message: "missing source"))
        let result = await RemoteFileMutation.rename(from: "/from", to: "/to").perform(
            using: session,
            shell: { _ in
                XCTFail("Missing source invoked shell"); return Self.reply()
            }, didLoseSFTP: {})
        guard case .failure(let error) = result else { return XCTFail("Missing source accepted") }
        XCTAssertEqual(error.message, String(localized: "文件或目录不存在"))
        XCTAssertEqual(session.mutations, 1)
    }

    func testUnavailableSFTPSelectsShellOnceWithoutRetryingFailure() async {
        var calls = 0
        let result = await RemoteFileMutation.remove("/file", recursive: false).perform(
            using: nil,
            shell: { _ in
                calls += 1; return Self.reply(code: -1, error: "disconnected")
            },
            didLoseSFTP: { XCTFail("No SFTP session was used") })
        guard case .failure(let error) = result else { return XCTFail("False success") }
        XCTAssertEqual(error.message, "disconnected")
        XCTAssertEqual(calls, 1)
    }

    func testRecursiveDeleteAndExclusiveCreateChooseShellEvenWhenSFTPIsAvailable() async throws {
        for operation in [RemoteFileMutation.createFile("/file"), .remove("/dir", recursive: true)] {
            let session = Session()
            var calls = 0
            let result = await operation.perform(
                using: session,
                shell: { _ in
                    calls += 1; return Self.reply()
                }, didLoseSFTP: {})
            try result.get()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(session.mutations, 0)
        }
    }

    func testPermissionParsingAcceptsOnlyBoundedOctalValues() throws {
        for value in ["", "888", "10000", "-1", "+755", "755;echo hacked", "700\n", "７００"] {
            XCTAssertNil(FilePermissionMode(value), value)
        }
        XCTAssertEqual(try XCTUnwrap(FilePermissionMode("0000")).value, 0)
        XCTAssertEqual(try XCTUnwrap(FilePermissionMode("4755")).value, 0o4755)
        XCTAssertEqual(try XCTUnwrap(FilePermissionMode("7777")).value, 0o7777)
    }

    private static func reply(code: Int32 = 0, error: String = "") -> RemoteFS.OpResult {
        .init(data: Data(), stderr: Data(error.utf8), code: code)
    }

    private final class Session: FileMutationSession {
        let error: SFTPError?
        let target: SFTPAttrs?
        let statError: SFTPError?
        var mutations = 0
        init(error: SFTPError? = nil, target: SFTPAttrs? = nil, statError: SFTPError? = nil) {
            self.error = error; self.target = target; self.statError = statError
        }
        func lstat(_ path: String) async throws -> SFTPAttrs {
            XCTAssertEqual(path, "/to")
            if let statError { throw statError }
            guard let target else { throw SFTPError(code: 2, message: "missing") }
            return target
        }
        private func mutate() throws { mutations += 1; if let error { throw error } }
        func mkdir(_ path: String) async throws { try mutate() }
        func remove(_ path: String) async throws { try mutate() }
        func rename(from: String, to: String) async throws { try mutate() }
        func setPermissions(_ path: String, _ mode: UInt32) async throws { try mutate() }
    }
}
