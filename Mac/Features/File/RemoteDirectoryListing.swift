import Foundation

protocol DirectoryListingSession: AnyObject {
    func opendir(_ path: String) async throws -> Data
    func readdir(_ handle: Data) async throws -> [(name: String, attrs: SFTPAttrs)]?
    func closeHandle(_ handle: Data) async
}

extension SFTPSession: DirectoryListingSession {}

/// Both transports validate directory entries before they become actionable paths in the browser.
enum RemoteDirectoryListing {
    static func read(_ path: String, using session: any DirectoryListingSession) async throws -> [RemoteFile]
    {
        try Task.checkCancellation()
        let handle = try await session.opendir(path)
        do {
            var files: [RemoteFile] = []
            var names = Set<String>()
            while true {
                try Task.checkCancellation()
                guard let batch = try await session.readdir(handle) else { break }
                for (name, attributes) in batch where name != "." && name != ".." {
                    guard names.insert(name).inserted else { throw invalidResponse() }
                    files.append(try entry(name: name, attributes: attributes, directory: path))
                }
            }
            await session.closeHandle(handle)
            return sorted(files)
        } catch {
            await session.closeHandle(handle)
            throw error
        }
    }

    static func entry(name: String, attributes: SFTPAttrs, directory: String) throws -> RemoteFile {
        let kind: RemoteFile.Kind
        switch (attributes.permissions ?? 0) & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symlink
        default: kind = .other
        }
        return try makeEntry(
            name: name, kind: kind, size: attributes.size ?? 0,
            modified: attributes.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            directory: directory)
    }

    /// A versioned NUL-delimited stream: header, repeated type/size/mtime/name fields, end marker.
    /// The end marker detects truncation even at an otherwise complete record boundary.
    static func parse(_ data: Data, directory: String) throws -> [RemoteFile] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 3, fields.last?.isEmpty == true,
            fields.first == Data("TERMO_DIRECTORY_1".utf8),
            fields[fields.count - 2] == Data("END".utf8),
            (fields.count - 3) % 4 == 0
        else { throw invalidResponse() }
        var files: [RemoteFile] = []
        var names = Set<String>()
        for index in stride(from: 1, to: fields.count - 2, by: 4) {
            guard let type = String(data: fields[index], encoding: .utf8),
                let rawSize = String(data: fields[index + 1], encoding: .utf8),
                let rawTime = String(data: fields[index + 2], encoding: .utf8),
                let name = String(data: fields[index + 3], encoding: .utf8),
                decimal(rawSize[...]), let size = UInt64(rawSize),
                decimal(rawTime.hasPrefix("-") ? rawTime.dropFirst() : rawTime[...]),
                let seconds = Int64(rawTime), names.insert(name).inserted
            else { throw invalidResponse() }
            let kind: RemoteFile.Kind
            switch type {
            case "d": kind = .directory
            case "f": kind = .file
            case "l": kind = .symlink
            case "o", "b", "c", "p", "s", "D": kind = .other
            default: throw invalidResponse()
            }
            files.append(
                try makeEntry(
                    name: name, kind: kind, size: size,
                    modified: Date(timeIntervalSince1970: TimeInterval(seconds)),
                    directory: directory))
        }
        return sorted(files)
    }

    private static func decimal(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func makeEntry(
        name: String, kind: RemoteFile.Kind, size: UInt64,
        modified: Date?, directory: String
    ) throws -> RemoteFile {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
            let size = Int64(exactly: size)
        else { throw invalidResponse() }
        let path = directory + (directory.hasSuffix("/") ? "" : "/") + name
        return RemoteFile(name: name, path: path, kind: kind, size: size, modified: modified)
    }

    private static func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    static func invalidResponse() -> RemoteFSError {
        RemoteFSError(message: String(localized: "目录返回的数据不完整或格式无效，请刷新后重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }

    /// GNU find keeps the fast metadata path; the BSD fallback passes names as arguments, never lines.
    /// Failed stat batches print an invalid record too, so find variants cannot hide a child failure.
    static func shellCommand(path: String) -> String {
        """
        \(RemoteShellPath.assign(path))
        [ -d "$P" ] && [ -r "$P" ] && [ -x "$P" ] || exit 1
        cd "$P" || exit 1
        printf 'TERMO_DIRECTORY_1\\0'
        if find . -maxdepth 0 -printf '' >/dev/null 2>&1; then
            find . -maxdepth 1 -mindepth 1 -printf '%y\\0%s\\0%Ts\\0%f\\0' || exit 1
        else
            if stat -c '%s %Y' -- . >/dev/null 2>&1; then
                style=gnu
            elif stat -f '%z %m' . >/dev/null 2>&1; then
                style=bsd
            else
                exit 1
            fi
            find . -maxdepth 1 -mindepth 1 -exec sh -c '
                style=$1; shift
                for file do
                    if [ "$style" = gnu ]; then
                        metadata=$(stat -c "%s %Y" -- "$file")
                    else
                        metadata=$(stat -f "%z %m" "$file")
                    fi
                    if [ "$?" != 0 ] || [ "$metadata" = "${metadata#* }" ]; then
                        printf "ERROR\\0"; exit 1
                    fi
                    if [ -L "$file" ]; then kind=l
                    elif [ -d "$file" ]; then kind=d
                    elif [ -f "$file" ]; then kind=f
                    else kind=o; fi
                    printf "%s\\0%s\\0%s\\0%s\\0" "$kind" "${metadata%% *}" "${metadata#* }" "${file##*/}"
                done
            ' termo-list "$style" {} + || exit 1
        fi
        printf 'END\\0'
        """
    }
}
