import Foundation

/// Adapts the same checked local source to the synchronous SSH stdin callback.
enum UploadShellStream {
    typealias Pull = (UnsafeMutablePointer<CChar>, Int32) -> Int32

    static func run(
        source: any UploadInput, path: String, startOffset: Int64, control: UploadControl,
        execute: (String, @escaping Pull) throws -> (rc: Int, exitCode: Int)
    ) -> UploadOutcome {
        if let stopped = UploadStream.interruption(control) { return stopped }
        defer { source.close() }
        do {
            let size = try source.open(at: startOffset)
            guard startOffset >= 0, startOffset <= size else { throw UploadSource.changed() }
            if let stopped = UploadStream.interruption(control) { return stopped }
            var sent = startOffset
            var stopped: UploadOutcome?
            var reachedEOF = false
            control.setSent(sent)
            let pull: Pull = { buffer, capacity in
                if let interruption = UploadStream.interruption(control) { stopped = interruption; return -1 }
                do {
                    guard capacity > 0 else { throw UploadSource.changed() }
                    guard let data = try source.read(upToCount: min(Int(capacity), 256 * 1024)), !data.isEmpty
                    else {
                        reachedEOF = true; return 0
                    }
                    guard data.count <= Int(capacity), Int64(data.count) <= size - sent else {
                        throw UploadSource.changed()
                    }
                    if let interruption = UploadStream.interruption(control) {
                        stopped = interruption; return -1
                    }
                    _ = data.withUnsafeBytes { memcpy(buffer, $0.baseAddress, data.count) }
                    sent += Int64(data.count)
                    control.setSent(sent)
                    return Int32(data.count)
                } catch {
                    stopped = failure(error); return -1
                }
            }
            let result: (rc: Int, exitCode: Int)
            do {
                result = try execute(
                    UploadShellCommands.write(path: path, offset: startOffset, size: size), pull)
            } catch {
                return stopped ?? UploadStream.interruption(control) ?? failure(error)
            }
            if let stopped = stopped ?? UploadStream.interruption(control) { return stopped }
            if result.exitCode == 9 { throw UploadStream.changedDestination() }
            guard result.rc == 0, result.exitCode == 0 else {
                return .failed(String(localized: "上传中断（退出码 \(result.exitCode)）"))
            }
            guard reachedEOF, sent == size else { throw UploadSource.changed() }
            try source.validate()
            return .completed
        } catch { return failure(error) }
    }

    private static func failure(_ error: Error) -> UploadOutcome {
        .failed(
            (error as? RemoteFSError)?.message ?? (error as? SSHSession.SSHError)?.message
                ?? error.localizedDescription)
    }
}
