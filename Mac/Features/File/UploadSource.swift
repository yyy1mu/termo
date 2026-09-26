import Darwin
import Foundation

protocol UploadInput: AnyObject, Sendable {
    func open(at offset: Int64) throws -> Int64
    func read(upToCount count: Int) throws -> Data?
    func validate() throws
    func close()
}

/// Pins the local file version for one upload attempt, including pause and explicit resume.
/// A restart creates a new source. Metadata validation is not a content checksum or a filesystem lock.
final class UploadSource: UploadInput, @unchecked Sendable {
    private struct Snapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let birthSeconds: Int
        let birthNanos: Int
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanos = info.st_birthtimespec.tv_nsec
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    let url: URL
    private let lock = NSLock()
    private var checkpoint: Snapshot?
    private var file: FileHandle?
    private var offset: Int64 = 0

    init(url: URL) { self.url = url }

    /// Nonisolated async work runs off the main actor; no file descriptor is held while awaiting UI decisions.
    func prepare() async throws -> Int64 {
        defer { close() }
        return try open(at: 0)
    }

    func open(at offset: Int64) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard file == nil, offset >= 0 else { throw Self.changed() }
        // O_NONBLOCK prevents a replaced pathname such as a FIFO from hanging the worker before fstat.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            let current = try snapshot(descriptor: descriptor)
            guard checkpoint == nil || checkpoint == current, offset <= current.size else {
                throw Self.changed()
            }
            try validatePath(expected: current)
            try opened.seek(toOffset: UInt64(offset))
            checkpoint = current
            file = opened
            self.offset = offset
            return current.size
        } catch {
            try? opened.close()
            throw error
        }
    }

    func read(upToCount count: Int) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard count > 0, let file, let checkpoint else { throw Self.changed() }
        try validateLocked()
        if offset == checkpoint.size { return nil }
        let wanted = Int(min(Int64(count), checkpoint.size - offset))
        guard let data = try file.read(upToCount: wanted), !data.isEmpty else { throw Self.changed() }
        try validateLocked()
        offset += Int64(data.count)
        return data
    }

    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        try validateLocked()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        try? file?.close()
        file = nil
    }

    private func validateLocked() throws {
        guard let file, let checkpoint,
            try snapshot(descriptor: file.fileDescriptor) == checkpoint
        else { throw Self.changed() }
        try validatePath(expected: checkpoint)
    }

    private func validatePath(expected: Snapshot) throws {
        var info = stat()
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0, Snapshot(info) == expected else {
            throw Self.changed()
        }
    }

    private func snapshot(descriptor: Int32) throws -> Snapshot {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw RemoteFSError(message: String(localized: "上传源必须是可读取的普通文件。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        return Snapshot(info)
    }

    static func changed() -> RemoteFSError {
        RemoteFSError(message: String(localized: "本地文件已变化或续传位置无效，请选择从头重传。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }

    deinit { close() }
}
