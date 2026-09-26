import Foundation

/// nil means confirmed absence; an existing empty file is represented by zero, never by nil.
struct UploadProbe: Equatable {
    let partSize: Int64?
    let finalSize: Int64?
}

enum UploadRestartPolicy { case automatic, restart, resume }

enum UploadWritePlan: Equatable {
    case write(offset: Int64)
    case finalize

    static func make(probe: UploadProbe, localSize: Int64, policy: UploadRestartPolicy) throws -> Self {
        guard localSize >= 0 else { throw UploadPreflight.invalidMetadata() }
        if policy == .restart { return .write(offset: 0) }
        guard let partial = probe.partSize else { return .write(offset: 0) }
        guard partial >= 0 else { throw UploadPreflight.invalidMetadata() }
        guard partial <= localSize else {
            throw RemoteFSError(message: String(localized: "远端残留文件大于本地文件，请选择从头重传。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        if policy == .resume {
            return partial == localSize && localSize > 0 ? .finalize : .write(offset: partial)
        }
        // Only explicit resume (or a paused attempt) may finalize a complete partial file.
        return probe.finalSize == nil && partial < localSize ? .write(offset: partial) : .write(offset: 0)
    }
}

enum UploadPreflight {
    static func read(
        path: String, stat: (String) async throws -> SFTPAttrs
    ) async throws -> UploadProbe {
        let partial = try await size(path + ".part", stat: stat)
        let final = try await size(path, stat: stat)
        return UploadProbe(partSize: partial, finalSize: final)
    }

    private static func size(_ path: String, stat: (String) async throws -> SFTPAttrs) async throws -> Int64?
    {
        let attributes: SFTPAttrs
        do { attributes = try await stat(path) } catch let error as SFTPError where error.isNoSuchFile {
            return nil
        }
        guard let permissions = attributes.permissions, permissions & 0o170000 == 0o100000 else {
            throw RemoteFSError(message: String(localized: "上传目标或残留文件不是可确认的普通文件。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        guard let rawSize = attributes.size, let size = Int64(exactly: rawSize) else {
            throw invalidMetadata()
        }
        return size
    }

    /// Portable, read-only fallback. An inaccessible parent or failed stat is never treated as absence.
    static func shellCommand(path: String) -> String {
        return """
            \(RemoteShellPath.assign(path))
            termo_probe_size() {
                parent=${1%/*}
                [ "$parent" != "$1" ] || parent=.
                [ -n "$parent" ] || parent=/
                [ -d "$parent" ] && [ -r "$parent" ] && [ -x "$parent" ] || return 1
                [ ! -L "$1" ] || return 1
                if [ -e "$1" ]; then
                    [ -f "$1" ] || return 1
                    size=$(stat -c %s -- "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null) || return 1
                    case "$size" in ''|*[!0-9]*) return 1 ;; esac
                    printf '%s' "$size"
                else
                    printf missing
                fi
            }
            ps=$(termo_probe_size "$P.part") || exit 1
            fs=$(termo_probe_size "$P") || exit 1
            printf 'TERMO_UPLOAD_PROBE_1 %s %s\\n' "$ps" "$fs"
            """
    }

    static func parse(_ data: Data) throws -> UploadProbe {
        guard let output = String(data: data, encoding: .utf8) else { throw invalidMetadata() }
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, fields[0] == "TERMO_UPLOAD_PROBE_1" else { throw invalidMetadata() }
        func size(_ field: Substring) throws -> Int64? {
            if field == "missing" { return nil }
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int64(field)
            else {
                throw invalidMetadata()
            }
            return value
        }
        return try UploadProbe(partSize: size(fields[1]), finalSize: size(fields[2]))
    }

    static func invalidMetadata() -> RemoteFSError {
        RemoteFSError(message: String(localized: "无法确认远端文件大小，上传已停止。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }
}
