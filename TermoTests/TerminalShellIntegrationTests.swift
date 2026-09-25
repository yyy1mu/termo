import XCTest
@testable import Termo

final class TerminalShellIntegrationTests: XCTestCase {
    private func run(_ shell: String, script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = shell == "/bin/bash" ? ["--noprofile", "--norc", "-c", script] : ["-f", "-c", script]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/private/tmp", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/tmp")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    func testBashRetainsExistingPromptCommandAndReportsDirectory() throws {
        let script = "PROMPT_COMMAND=\"printf 'existing-prompt'\"\n" +
            TerminalShellIntegration.initialLine(for: SSHConnection()) +
            "eval \"$PROMPT_COMMAND\"\n"
        let output = try run("/bin/bash", script: script)
        XCTAssertEqual(output.components(separatedBy: "\u{1B}]7;file://").count - 1, 2)
        XCTAssertTrue(output.contains("/private/tmp\u{1B}\\"))
        XCTAssertTrue(output.hasSuffix("existing-prompt"))
        XCTAssertFalse(output.contains("\u{1B}]133;"))
    }

    func testZshRetainsExistingPromptFunctionAndReportsDirectory() throws {
        let script = "existing_prompt(){ printf 'existing-prompt'; }; precmd_functions=(existing_prompt)\n" +
            TerminalShellIntegration.initialLine(for: SSHConnection()) +
            "for callback in $precmd_functions; do $callback; done\n"
        let output = try run("/bin/zsh", script: script)
        XCTAssertEqual(output.components(separatedBy: "\u{1B}]7;file://").count - 1, 2)
        XCTAssertTrue(output.contains("existing-prompt"))
        XCTAssertTrue(output.hasSuffix("/private/tmp\u{1B}\\"))
        XCTAssertFalse(output.contains("\u{1B}]133;"))
    }

    func testStartupDirectoryAndCommandStillRunAfterSetup() throws {
        var connection = SSHConnection()
        connection.defaultPath = "/"
        connection.initialCommand = "printf 'startup:%s' \"$PWD\""
        for shell in ["/bin/bash", "/bin/zsh"] {
            let output = try run(shell, script: TerminalShellIntegration.initialLine(for: connection))
            XCTAssertTrue(output.contains("\u{1B}[2J\u{1B}[H"))
            XCTAssertTrue(output.hasSuffix("startup:/"))
        }
    }
}
