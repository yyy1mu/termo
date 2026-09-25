import Foundation

/// Interactive shell setup only. Agent commands use their own exec channel and require no prompt hooks.
enum TerminalShellIntegration {
    private static let directoryHook =
        "__t7(){ printf '\\033]7;file://%s%s\\033\\\\' \"${HOSTNAME:-h}\" \"$PWD\"; }; " +
        "if [ -n \"$ZSH_VERSION\" ]; then precmd_functions+=(__t7); " +
        "else PROMPT_COMMAND=\"__t7;${PROMPT_COMMAND}\"; fi; __t7"

    /// Preserve cwd reporting, clear the setup echo, then apply the user's startup configuration.
    static func initialLine(for connection: SSHConnection) -> String {
        let path = connection.defaultPath.trimmingCharacters(in: .whitespaces)
        let command = connection.initialCommand.trimmingCharacters(in: .whitespaces)
        var tail = ""
        if !path.isEmpty && path != "~" { tail += "cd \(path)" }
        if !command.isEmpty { tail += (tail.isEmpty ? "" : " && ") + command }
        var line = directoryHook + "; printf '\\033[2J\\033[H'"
        if !tail.isEmpty { line += "; " + tail }
        return line + "\n"
    }
}
