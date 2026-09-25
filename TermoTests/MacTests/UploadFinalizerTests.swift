import XCTest

@testable import Termo

@MainActor
final class UploadFinalizerTests: XCTestCase {
    func testNewFileUsesNonReplacingRenameEvenWithPriorApproval() async throws {
        for approved in [false, true] {
            let session = Session()
            let outcome = try await UploadFinalizer.commit(request(approved), using: session)
            XCTAssertEqual(outcome, .committed)
            XCTAssertEqual(session.operations, ["stat /file.part", "stat /file", "rename"])
        }
    }

    func testApprovedExistingFileInheritsPermissionBitsAndUsesAtomicReplace() async throws {
        let session = Session(target: attributes(size: 8, permissions: 0o100640))
        let outcome = try await UploadFinalizer.commit(request(true), using: session)
        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(session.operations, ["stat /file.part", "stat /file", "chmod 416", "replace"])
    }

    func testDestinationAppearingDuringUploadRequiresApproval() async {
        let session = Session(target: attributes(size: 8))
        do {
            _ = try await UploadFinalizer.commit(request(false), using: session)
            XCTFail("Unapproved replacement")
        } catch {
            XCTAssertEqual((error as? RemoteFSError)?.message, UploadFinalizer.targetExists().message)
        }
        XCTAssertEqual(session.operations, ["stat /file.part", "stat /file"])
    }

    func testChangedOrUnverifiablePartialCannotBeCommitted() async {
        for partial in [
            attributes(size: 5), attributes(size: 7), attributes(size: nil),
            attributes(size: 6, permissions: nil), attributes(size: 6, permissions: 0o040755),
            attributes(size: 6, permissions: 0o120777),
        ] {
            let session = Session(partial: partial)
            do {
                _ = try await UploadFinalizer.commit(request(true), using: session)
                XCTFail("Invalid partial accepted")
            } catch {
                XCTAssertEqual((error as? RemoteFSError)?.message, UploadFinalizer.invalidPartial().message)
            }
            XCTAssertEqual(session.operations, ["stat /file.part"])
        }
    }

    func testDirectorySymlinkAndUnknownTargetAreNeverOverwritten() async {
        for permissions in [UInt32?(0o040755), UInt32?(0o120777), nil] {
            let session = Session(target: attributes(size: 8, permissions: permissions))
            do {
                _ = try await UploadFinalizer.commit(request(true), using: session)
                XCTFail("Invalid target accepted")
            } catch {
                XCTAssertEqual((error as? RemoteFSError)?.message, UploadFinalizer.invalidTarget().message)
            }
            XCTAssertEqual(session.operations, ["stat /file.part", "stat /file"])
        }
    }

    func testOnlyConfirmedAbsenceAllowsNewFileRename() async {
        for code: UInt32 in [3, 4, 8, 0xF001] {
            let session = Session(fault: .stat, error: failure(code))
            do {
                _ = try await UploadFinalizer.commit(request(false), using: session)
                XCTFail("Unknown target treated as absent")
            } catch { XCTAssertEqual((error as? SFTPError)?.code, code) }
            XCTAssertEqual(session.operations, ["stat /file.part", "stat /file"])
        }
    }

    func testPermissionInheritanceMayBeDeniedButTransportFailureStopsCommit() async throws {
        for code: UInt32 in [3, 8, 4, 0xF001] {
            let session = Session(target: attributes(size: 8), fault: .chmod, error: failure(code))
            do {
                let outcome = try await UploadFinalizer.commit(request(true), using: session)
                XCTAssertTrue(code == 3 || code == 8)
                XCTAssertEqual(outcome, .committed)
                XCTAssertEqual(session.operations.last, "replace")
            } catch {
                XCTAssertTrue(code == 4 || code == 0xF001)
                XCTAssertEqual((error as? SFTPError)?.code, code)
                XCTAssertFalse(session.operations.contains("replace"))
            }
        }
    }

    func testOnlyExplicitUnsupportedOverwriteAllowsShellFallback() async throws {
        for code: UInt32 in [3, 4, 8, 0xF001] {
            let session = Session(target: attributes(size: 8), fault: .rename, error: failure(code))
            do {
                let outcome = try await UploadFinalizer.commit(request(true), using: session)
                XCTAssertEqual(code, 8)
                XCTAssertEqual(outcome, .unsupportedOverwrite)
            } catch { XCTAssertNotEqual(code, 8); XCTAssertEqual((error as? SFTPError)?.code, code) }
            XCTAssertEqual(session.operations.filter { $0 == "replace" }.count, 1)
            XCTAssertFalse(session.operations.contains("rename"))
        }
    }

    func testNonReplacingRenameFailureIsNotRetriedWithOverwrite() async {
        let session = Session(fault: .rename, error: failure(4))
        do {
            _ = try await UploadFinalizer.commit(request(true), using: session)
            XCTFail("Expected concurrent destination failure")
        } catch { XCTAssertEqual((error as? SFTPError)?.code, 4) }
        XCTAssertEqual(session.operations, ["stat /file.part", "stat /file", "rename"])
    }

    private func request(_ approved: Bool) -> UploadCommit {
        .init(path: "/file", size: 6, replaceExisting: approved)
    }
    private func failure(_ code: UInt32) -> SFTPError {
        .init(code: code, message: "fixture", isTransport: code >= 0xF000)
    }
    private func attributes(size: UInt64?, permissions: UInt32? = 0o100644) -> SFTPAttrs {
        Self.attributes(size: size, permissions: permissions)
    }
    nonisolated private static func attributes(size: UInt64?, permissions: UInt32? = 0o100644) -> SFTPAttrs {
        var result = SFTPAttrs(); result.size = size; result.permissions = permissions; return result
    }

    private enum Fault { case stat, chmod, rename }
    private final class Session: UploadCommitSession {
        let partial: SFTPAttrs
        let target: SFTPAttrs?
        let fault: Fault?
        let error: SFTPError
        var operations: [String] = []

        init(
            partial: SFTPAttrs = UploadFinalizerTests.attributes(size: 6), target: SFTPAttrs? = nil,
            fault: Fault? = nil, error: SFTPError = .init(code: 4, message: "fixture")
        ) {
            self.partial = partial; self.target = target; self.fault = fault; self.error = error
        }
        func lstat(_ path: String) async throws -> SFTPAttrs {
            operations.append("stat \(path)")
            if path.hasSuffix(".part") { return partial }
            if fault == .stat { throw error }
            guard let target else { throw SFTPError(code: 2, message: "missing") }
            return target
        }
        func setPermissions(_ path: String, _ mode: UInt32) async throws {
            XCTAssertEqual(path, "/file.part")
            operations.append("chmod \(mode)")
            if fault == .chmod { throw error }
        }
        func rename(from: String, to: String) async throws {
            XCTAssertEqual(from, "/file.part"); XCTAssertEqual(to, "/file")
            operations.append("rename")
            if fault == .rename { throw error }
        }
        func posixRename(from: String, to: String) async throws {
            XCTAssertEqual(from, "/file.part"); XCTAssertEqual(to, "/file")
            operations.append("replace")
            if fault == .rename { throw error }
        }
    }
}
