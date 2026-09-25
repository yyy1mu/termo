import Foundation

/// The file-task lifecycle can be exercised without a network connection or the application singleton.
@MainActor
protocol TransferFileSystem: AnyObject {
    func probeUpload(remotePath: String) async throws -> UploadProbe
    func upload(
        source: UploadSource, toRemote remotePath: String, startOffset: Int64, control: UploadControl
    ) async -> UploadOutcome
    func download(
        _ remotePath: String, to destination: DownloadDestination, control: UploadControl
    ) async -> UploadOutcome
    func finalizeUpload(_ request: UploadCommit) async -> Result<Void, RemoteFSError>
    func cleanupPart(remotePath: String) async
    func closeSession()
}

extension RemoteFS: TransferFileSystem {}
