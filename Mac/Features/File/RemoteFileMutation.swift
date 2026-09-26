import Foundation

struct FilePermissionMode {
    let value: UInt32

    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...55).contains($0) }),
            let value = UInt32(text, radix: 8), value <= 0o7777
        else { return nil }
        self.value = value
    }
}

protocol FileMutationSession: AnyObject {
    func lstat(_ path: String) async throws -> SFTPAttrs
    func mkdir(_ path: String) async throws
    func remove(_ path: String) async throws
    func rename(from: String, to: String) async throws
    func setPermissions(_ path: String, _ mode: UInt32) async throws
}

extension SFTPSession: FileMutationSession {}

/// An operation chooses its transport before it starts. An uncertain mutation is never replayed.
enum RemoteFileMutation {
    case createDirectory(String)
    case createFile(String)
    case remove(String, recursive: Bool)
    case rename(from: String, to: String)
    case permissions(String, FilePermissionMode)

    var usesSFTP: Bool {
        switch self {
        case .createFile, .remove(_, recursive: true): return false
        default: return true
        }
    }

    func perform(
        using session: (any FileMutationSession)?,
        shell: (String) async -> RemoteFS.OpResult,
        didLoseSFTP: () -> Void
    ) async -> Result<Void, RemoteFSError> {
        if usesSFTP, let session {
            do {
                try await performSFTP(session)
                return .success(())
            } catch let error as RemoteFSError {
                return .failure(error)
            } catch let error as SFTPError {
                if error.isTransport {
                    didLoseSFTP()
                    return .failure(
                        RemoteFSError(
                            message:
                                String(localized: "文件操作时连接中断，结果尚未确认，请刷新目录后再决定是否重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)))
                }
                let message =
                    error.isPermission
                    ? permissionError
                    : (error.isNoSuchFile ? String(localized: "文件或目录不存在", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : error.message)
                return .failure(RemoteFSError(message: message))
            } catch {
                return .failure(RemoteFSError(message: error.localizedDescription))
            }
        }
        let result = await shell(shellCommand)
        guard result.code != 0 else { return .success(()) }
        if result.code == 9 {
            switch self {
            case .createFile, .rename: return .failure(Self.targetExists())
            default: break
            }
        }
        let detail =
            String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message =
            detail.localizedCaseInsensitiveContains("permission")
            ? permissionError
            : (detail.isEmpty ? failureMessage : detail)
        return .failure(RemoteFSError(message: message))
    }

    private func performSFTP(_ session: any FileMutationSession) async throws {
        switch self {
        case .createDirectory(let path): try await session.mkdir(path)
        case .remove(let path, _): try await session.remove(path)
        case .rename(let from, let to):
            do {
                _ = try await session.lstat(to)
                throw Self.targetExists()
            } catch let error as SFTPError where error.isNoSuchFile {
                // lstat also detects dangling symlinks; only confirmed absence permits rename.
            }
            try await session.rename(from: from, to: to)
        case .permissions(let path, let mode): try await session.setPermissions(path, mode.value)
        case .createFile: preconditionFailure("File creation uses an exclusive shell redirection")
        }
    }

    var shellCommand: String {
        switch self {
        case .createDirectory(let path):
            return "\(RemoteShellPath.assign(path)); mkdir -- \"$P\""
        case .createFile(let path):
            return "\(RemoteShellPath.assign(path)); "
                + "if [ -e \"$P\" ] || [ -L \"$P\" ]; then exit 9; fi; set -C; : > \"$P\""
        case .remove(let path, let recursive):
            return "\(RemoteShellPath.assign(path)); rm \(recursive ? "-rf" : "-f") -- \"$P\""
        case .permissions(let path, let mode):
            return "\(RemoteShellPath.assign(path)); chmod -- \(String(mode.value, radix: 8)) \"$P\""
        case .rename(let from, let to):
            return """
                \(RemoteShellPath.assign(from, to: .source))
                \(RemoteShellPath.assign(to, to: .target))
                if [ -e "$T" ] || [ -L "$T" ]; then exit 9; fi
                mv -n -- "$F" "$T" || exit 12
                # Some mv implementations report success when -n skipped an existing target.
                if [ -e "$F" ] || [ -L "$F" ]; then exit 12; fi
                [ -e "$T" ] || [ -L "$T" ] || exit 12
                """
        }
    }

    private var permissionError: String {
        switch self {
        case .createDirectory, .createFile: return String(localized: "没有创建权限", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .remove: return String(localized: "没有删除权限", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .rename: return String(localized: "没有重命名权限", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .permissions: return String(localized: "没有修改权限的权限", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private var failureMessage: String {
        switch self {
        case .createDirectory: return String(localized: "新建文件夹失败，请刷新目录确认结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .createFile: return String(localized: "新建文件失败，请刷新目录确认结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .remove: return String(localized: "删除未确认，请刷新目录检查结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .rename: return String(localized: "重命名未确认，请刷新目录检查结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .permissions: return String(localized: "修改权限未确认，请刷新目录检查结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private static func targetExists() -> RemoteFSError {
        RemoteFSError(message: String(localized: "目标名称已存在", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }
}
