import Foundation

/// The task carries its verified source size and explicit overwrite decision through to commit.
struct UploadCommit: Equatable {
    let path: String
    let size: Int64
    let replaceExisting: Bool

    var partialPath: String { path + ".part" }
}

protocol UploadCommitSession: AnyObject {
    func lstat(_ path: String) async throws -> SFTPAttrs
    func setPermissions(_ path: String, _ mode: UInt32) async throws
    func rename(from: String, to: String) async throws
    func posixRename(from: String, to: String) async throws
}

extension SFTPSession: UploadCommitSession {}

/// Commit is a single attempt. A failed or ambiguous rename must never become a delete-and-retry.
enum UploadFinalizer {
    enum Outcome: Equatable { case committed, unsupportedOverwrite }

    static func commit(
        _ request: UploadCommit, using session: any UploadCommitSession
    ) async throws -> Outcome {
        let partial = try await session.lstat(request.partialPath)
        guard request.size >= 0, isRegular(partial), partial.size == UInt64(request.size) else {
            throw invalidPartial()
        }

        let target: SFTPAttrs?
        do { target = try await session.lstat(request.path) } catch let error as SFTPError
            where error.isNoSuchFile
        { target = nil }

        if let target {
            guard isRegular(target) else { throw invalidTarget() }
            guard request.replaceExisting else { throw targetExists() }
            if let permissions = target.permissions {
                do { try await session.setPermissions(request.partialPath, permissions & 0o7777) } catch let
                    error as SFTPError where !error.isTransport && (error.isPermission || error.code == 8)
                {
                    // Permission inheritance is best effort; transport and unknown failures are not.
                }
            }
            do { try await session.posixRename(from: request.partialPath, to: request.path) } catch let error
                as SFTPError where error.code == 8 && !error.isTransport
            {
                return .unsupportedOverwrite
            }
        } else {
            // Standard SFTP rename refuses an intervening destination, even after prior approval.
            try await session.rename(from: request.partialPath, to: request.path)
        }
        return .committed
    }

    private static func isRegular(_ attributes: SFTPAttrs) -> Bool {
        guard let permissions = attributes.permissions else { return false }
        return permissions & 0o170000 == 0o100000
    }

    static func invalidPartial() -> RemoteFSError {
        RemoteFSError(message: String(localized: "上传残留文件大小或类型已变化，未提交，请重新检查后重试。"))
    }

    static func invalidTarget() -> RemoteFSError {
        RemoteFSError(message: String(localized: "目标已变为目录、符号链接或未知类型，未覆盖。"))
    }

    static func targetExists() -> RemoteFSError {
        RemoteFSError(message: String(localized: "上传期间出现了同名文件，未获得覆盖批准，请重试并确认。"))
    }
}
