import Foundation

protocol DownloadSource: AnyObject, Sendable {
    func open(_ path: String, pflags: UInt32) async throws -> Data
    func fstat(_ handle: Data) async throws -> SFTPAttrs
    func read(_ handle: Data, offset: UInt64, length: UInt32) async throws -> Data?
    func closeHandle(_ handle: Data) async
}

extension SFTPSession: DownloadSource {}

enum DownloadStream {
    static func run(
        path: String, source: any DownloadSource, sink: any DownloadSink, control: UploadControl
    ) async throws -> UploadOutcome {
        if let stopped = interruption(control) { return stopped }
        let handle = try await source.open(path, pflags: SFTPFlag.READ)
        do {
            let result = try await copy(handle: handle, source: source, sink: sink, control: control)
            await source.closeHandle(handle)
            return result
        } catch {
            await source.closeHandle(handle)
            throw error
        }
    }

    private static func copy(
        handle: Data, source: any DownloadSource, sink: any DownloadSink, control: UploadControl
    ) async throws -> UploadOutcome {
        defer { try? sink.suspend() }  // Includes read/write/stat/commit errors and cancellation.
        if let stopped = interruption(control) { return stopped }
        let version = try DownloadVersion(await source.fstat(handle))
        if let stopped = interruption(control) { return stopped }
        var offset = try sink.begin(version: version)
        guard offset <= version.size else { throw changed() }
        control.setSent(Int64(offset))
        while true {
            if let stopped = interruption(control) { try sink.suspend(); return stopped }
            let chunk = try await source.read(handle, offset: offset, length: 32768)
            if let stopped = interruption(control) { try sink.suspend(); return stopped }
            guard let chunk, !chunk.isEmpty else { break }
            guard UInt64(chunk.count) <= version.size - offset else { throw changed() }
            try sink.append(chunk)
            offset += UInt64(chunk.count)
            control.setSent(Int64(offset))
        }
        guard offset == version.size, try DownloadVersion(await source.fstat(handle)) == version else {
            throw changed()
        }
        if let stopped = interruption(control) { try sink.suspend(); return stopped }
        try sink.finish()
        return .completed
    }

    private static func interruption(_ control: UploadControl) -> UploadOutcome? {
        if Task.isCancelled || control.signal == .cancel { return .cancelled }
        return control.signal == .pause ? .paused : nil
    }
    private static func changed() -> RemoteFSError {
        RemoteFSError(message: String(localized: "远端文件在下载期间发生变化，请重新下载。"))
    }
}
