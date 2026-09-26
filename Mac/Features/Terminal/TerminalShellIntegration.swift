import Foundation
import TermoCore

/// Builds the optional PTY+exec command used before the interactive login shell starts.
/// Nothing returned here is written to the interactive shell's stdin, so it cannot enter shell history.
enum TerminalShellIntegration {
    static func startupCommand(for connection: SSHConnection) -> String? {
        let path = connection.defaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = connection.initialCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions: [String] = []
        if !path.isEmpty && path != "~" { actions.append("cd -- \(shellPath(path))") }
        if !command.isEmpty { actions.append(command) }
        guard !actions.isEmpty else { return nil }

        // sshd executes this wrapper outside the interactive shell. After the configured actions finish,
        // replace the wrapper with the user's login shell on the same PTY.
        return actions.joined(separator: " && ") + "; exec \"${SHELL:-/bin/sh}\" -l"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func shellPath(_ value: String) -> String {
        guard value.hasPrefix("~/") else { return shellQuote(value) }
        return "\"$HOME\"/" + shellQuote(String(value.dropFirst(2)))
    }
}
