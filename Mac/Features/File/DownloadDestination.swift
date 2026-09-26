import Darwin
import Foundation

struct DownloadVersion: Equatable, Sendable {
    let size: UInt64
    let modified: UInt32?

    init(_ attributes: SFTPAttrs) throws {
        guard let size = attributes.size, size <= UInt64(Int64.max) else {
            throw RemoteFSError(message: String(localized: "无法确认远端文件大小，下载已停止。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        self.size = size
        self.modified = attributes.mtime
    }

    init(size: UInt64, modified: UInt32? = nil) { self.size = size; self.modified = modified }
}

protocol DownloadSink: AnyObject, Sendable {
    func begin(version: DownloadVersion) throws -> UInt64
    func append(_ data: Data) throws
    func finish() throws
    func suspend() throws
}

/// Owns one private sibling file. Neither failure nor cancellation removes the user's final pathname.
/// All state and local file operations are serialized; SFTP's async worker calls this off the UI thread.
final class DownloadDestination: DownloadSink, @unchecked Sendable {
    private enum Phase { case fresh, active, paused, completed, discarded }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanos: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanos = info.st_birthtimespec.tv_nsec
        }
    }
    private struct Checkpoint: Equatable {
        let identity: Identity
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ info: stat) {
            identity = Identity(info); size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    let url: URL
    private let lock = NSLock()
    // Progress reads on the main actor must not wait for file writes or a fallback copy.
    private let sizeLock = NSLock()
    private var confirmedSize: Int64?
    private let temporaryName = ".termo-download-\(UUID().uuidString).part"
    private let rename: @Sendable (Int32, String, String) throws -> Void
    private var phase: Phase = .fresh
    private var directoryFD: Int32 = -1
    private var directoryIdentity: Identity?
    private var file: FileHandle?
    private var checkpoint: Checkpoint?
    private var version: DownloadVersion?
    private var offset: UInt64 = 0

    init(
        url: URL,
        rename: @escaping @Sendable (Int32, String, String) throws -> Void = { directory, source, target in
            guard renameatx_np(directory, source, directory, target, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    ) {
        self.url = url.standardizedFileURL
        self.rename = rename
    }

    var expectedSize: Int64? {
        sizeLock.lock(); defer { sizeLock.unlock() }
        return confirmedSize
    }

    func begin(version: DownloadVersion) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard phase == .fresh || phase == .paused else { throw changed() }
        guard version.size <= UInt64(Int64.max) else { throw changed() }
        if let previous = self.version, previous != version {
            throw RemoteFSError(message: String(localized: "远端文件已变化，请重新下载。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        if directoryFD < 0 {
            directoryFD = Darwin.open(
                url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard directoryFD >= 0 else { throw ioError() }
            var info = stat()
            guard fstat(directoryFD, &info) == 0 else { throw ioError() }
            directoryIdentity = Identity(info)
        }
        try validateDirectory()
        try requireAbsentFinal()
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (phase == .fresh ? O_CREAT | O_EXCL : 0)
        let descriptor = openat(directoryFD, temporaryName, flags, mode_t(0o666))
        guard descriptor >= 0 else { throw ioError() }
        let opened = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw ioError() }
            guard info.st_mode & S_IFMT == S_IFREG else { throw changed() }
            let current = Checkpoint(info)
            if let checkpoint {
                guard checkpoint == current, info.st_size >= 0, UInt64(info.st_size) == offset else {
                    throw changed()
                }
            } else {
                checkpoint = current
            }
            guard offset <= version.size else { throw changed() }
            try opened.seek(toOffset: offset)
            file = opened
            self.version = version
            sizeLock.lock(); confirmedSize = Int64(version.size); sizeLock.unlock()
            phase = .active
            return offset
        } catch {
            try? opened.close()
            throw error
        }
    }

    func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .active, let file, let version,
            offset <= version.size, UInt64(data.count) <= version.size - offset
        else { throw changed() }
        try validateFile(file)
        try file.write(contentsOf: data)
        offset += UInt64(data.count)
        checkpoint = try snapshot(file)
    }

    func suspend() throws {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        defer { self.file = nil; if phase == .active { phase = .paused } }
        try file.close()
    }

    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        guard phase == .active, let file, offset == version?.size else { throw changed() }
        try validateDirectory()
        try validateFile(file)
        try file.synchronize()
        do {
            try rename(directoryFD, temporaryName, url.lastPathComponent)
        } catch let error as POSIXError where error.code == .ENOTSUP {
            // Some volumes lack exclusive rename. Exclusive creation + bounded copy still never overwrites.
            try copyToExclusiveFinal(file)
        } catch let error as POSIXError where error.code == .EEXIST {
            throw destinationExists()
        }
        phase = .completed
        try? file.close(); self.file = nil
        closeDirectory()
    }

    /// Best-effort removal is limited to our private file and its recorded identity, never the final path.
    @discardableResult
    func discard() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if phase == .completed || phase == .discarded { return true }
        let removed = removeOwned(temporaryName, identity: checkpoint?.identity)
        try? file?.close(); file = nil
        closeDirectory()
        phase = .discarded
        return removed
    }

    private func validateDirectory() throws {
        var info = stat()
        guard fstatat(AT_FDCWD, url.deletingLastPathComponent().path, &info, 0) == 0,
            Identity(info) == directoryIdentity
        else { throw changed() }
    }

    private func requireAbsentFinal() throws {
        var info = stat()
        if fstatat(directoryFD, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw destinationExists()
        }
        guard errno == ENOENT else { throw ioError() }
    }

    private func snapshot(_ file: FileHandle) throws -> Checkpoint {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw ioError() }
        return Checkpoint(info)
    }

    private func validateFile(_ file: FileHandle) throws {
        var named = stat()
        guard let checkpoint, try snapshot(file) == checkpoint,
            fstatat(directoryFD, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0,
            named.st_mode & S_IFMT == S_IFREG, Identity(named) == checkpoint.identity
        else { throw changed() }
    }

    private func copyToExclusiveFinal(_ source: FileHandle) throws {
        let descriptor = openat(
            directoryFD, url.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o666))
        guard descriptor >= 0 else { if errno == EEXIST { throw destinationExists() }; throw ioError() }
        let target = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var targetInfo = stat()
        let identity = fstat(descriptor, &targetInfo) == 0 ? Identity(targetInfo) : nil
        do {
            guard identity != nil else { throw ioError() }
            try source.seek(toOffset: 0)
            var copied: UInt64 = 0
            while copied < offset {
                guard let chunk = try source.read(upToCount: Int(min(64 * 1024, offset - copied))),
                    !chunk.isEmpty
                else { throw changed() }
                try target.write(contentsOf: chunk)
                copied += UInt64(chunk.count)
            }
            try validateFile(source)
            try validateDirectory()
            try target.synchronize()
            var named = stat()
            guard fstatat(directoryFD, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
                Identity(named) == identity, named.st_size == offset
            else { throw changed() }
            try target.close()
            _ = removeOwned(temporaryName, identity: checkpoint?.identity)
        } catch {
            _ = removeOwned(url.lastPathComponent, identity: identity)
            try? target.close()
            throw error
        }
    }

    private func removeOwned(_ name: String, identity: Identity?) -> Bool {
        guard directoryFD >= 0, let identity else { return true }
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFREG, Identity(info) == identity else { return true }
        return unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT
    }

    private func closeDirectory() {
        if directoryFD >= 0 { Darwin.close(directoryFD); directoryFD = -1 }
    }
    private func destinationExists() -> RemoteFSError {
        RemoteFSError(message: String(localized: "下载目标已存在，请重新选择保存位置。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }
    private func changed() -> RemoteFSError {
        RemoteFSError(message: String(localized: "下载临时文件或保存位置已变化，请重新下载。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }
    private func ioError() -> RemoteFSError {
        RemoteFSError(message: String(localized: "本地文件操作失败：\(String(cString: strerror(errno)))", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }
    deinit { discard() }
}
