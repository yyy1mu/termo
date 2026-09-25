import Foundation

protocol UploadDestination: AnyObject, Sendable {
    func open(_ path: String, pflags: UInt32) async throws -> Data
    func fstat(_ handle: Data) async throws -> SFTPAttrs
    func write(_ handle: Data, offset: UInt64, data: Data) async throws
    func closeHandle(_ handle: Data) async
}

extension SFTPSession: UploadDestination {}

enum UploadStream {
    static func run(
        source: any UploadInput, destination: any UploadDestination,
        path: String, startOffset: Int64, control: UploadControl
    ) async throws -> UploadOutcome {
        if let stopped = interruption(control) { return stopped }
        let size = try source.open(at: startOffset)
        defer { source.close() }
        guard startOffset >= 0, startOffset <= size else { throw UploadSource.changed() }
        if let stopped = interruption(control) { return stopped }
        let flags = SFTPFlag.WRITE | (startOffset == 0 ? SFTPFlag.CREAT | SFTPFlag.TRUNC : 0)
        let handle = try await destination.open(path + ".part", pflags: flags)
        do {
            let outcome = try await copy(
                source: source, destination: destination, handle: handle,
                size: size, offset: startOffset, control: control)
            await destination.closeHandle(handle)
            return outcome
        } catch {
            await destination.closeHandle(handle)
            throw error
        }
    }

    private static func copy(
        source: any UploadInput, destination: any UploadDestination, handle: Data,
        size: Int64, offset: Int64, control: UploadControl
    ) async throws -> UploadOutcome {
        if let stopped = interruption(control) { return stopped }
        try check(try await destination.fstat(handle), size: offset)
        var sent = offset
        control.setSent(sent)
        while true {
            if let stopped = interruption(control) { return stopped }
            guard let data = try source.read(upToCount: 32 * 1024), !data.isEmpty else { break }
            guard Int64(data.count) <= size - sent else { throw UploadSource.changed() }
            if let stopped = interruption(control) { return stopped }
            try await destination.write(handle, offset: UInt64(sent), data: data)
            sent += Int64(data.count)
            control.setSent(sent)
        }
        guard sent == size else { throw UploadSource.changed() }
        if let stopped = interruption(control) { return stopped }
        try check(try await destination.fstat(handle), size: size)
        try source.validate()
        if let stopped = interruption(control) { return stopped }
        return .completed
    }

    private static func check(_ attributes: SFTPAttrs, size: Int64) throws {
        guard attributes.size == UInt64(size), let permissions = attributes.permissions,
            permissions & 0o170000 == 0o100000
        else { throw changedDestination() }
    }

    static func interruption(_ control: UploadControl) -> UploadOutcome? {
        if Task.isCancelled || control.signal == .cancel { return .cancelled }
        return control.signal == .pause ? .paused : nil
    }

    static func changedDestination() -> RemoteFSError {
        RemoteFSError(message: String(localized: "远端残留文件大小或类型已变化，请重新检查后重试。"))
    }
}
