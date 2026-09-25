import Foundation

/// Every shell upload phase must address exactly the same path, including trailing newlines.
enum UploadShellCommands {
    static func write(path: String, offset: Int64, size: Int64) -> String {
        return """
            \(RemoteShellPath.assign(path))
            T="$P.part"
            termo_upload_size() {
                [ ! -L "$T" ] && [ -f "$T" ] || return 1
                value=$(stat -c %s -- "$T" 2>/dev/null || stat -f %z "$T" 2>/dev/null) || return 1
                case "$value" in ''|*[!0-9]*) return 1 ;; esac
                printf '%s' "$value"
            }
            [ ! -L "$T" ] || exit 9
            if [ -e "$T" ]; then [ -f "$T" ] || exit 9; fi
            if [ \(offset) -gt 0 ]; then
                before=$(termo_upload_size) || exit 9
                [ "$before" = '\(offset)' ] || exit 9
            fi
            cat \(offset > 0 ? ">>" : ">") "$T" || exit 8
            after=$(termo_upload_size) || exit 9
            [ "$after" = '\(size)' ] || exit 9
            """
    }

    /// Recheck after a long transfer or an unsupported SFTP overwrite extension.
    /// Preflight and mv are separate operations; this does not provide a cross-process transaction.
    static func finalize(_ request: UploadCommit) -> String {
        """
        \(RemoteShellPath.assign(request.path))
        T="$P.part"
        termo_commit_size() {
            [ ! -L "$1" ] && [ -f "$1" ] || return 1
            value=$(stat -c %s -- "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null) || return 1
            case "$value" in ''|*[!0-9]*) return 1 ;; esac
            printf '%s' "$value"
        }
        size=$(termo_commit_size "$T") || exit 9
        [ "$size" = '\(request.size)' ] || exit 9
        [ ! -L "$P" ] || exit 10
        if [ -e "$P" ]; then
            [ -f "$P" ] || exit 10
            \(request.replaceExisting ? ":" : "exit 11")
            chmod --reference="$P" "$T" 2>/dev/null || \
                chmod "$(stat -f %Lp "$P" 2>/dev/null)" "$T" 2>/dev/null || :
        fi
        mv \(request.replaceExisting ? "-f" : "-n") "$T" "$P" || exit 12
        # mv -n may return success without moving anything when a destination appears.
        [ ! -e "$T" ] && [ ! -L "$T" ] || exit 11
        size=$(termo_commit_size "$P") || exit 12
        [ "$size" = '\(request.size)' ] || exit 12
        """
    }
}
