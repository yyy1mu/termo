import XCTest
@testable import Termo
import TermoCore

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

    func testOrdinaryConnectionDoesNotGenerateRemoteCommand() {
        XCTAssertNil(TerminalShellIntegration.startupCommand(for: SSHConnection()))
    }

    func testConfiguredStartupRunsOutsideInteractiveHistoryThenStartsLoginShell() throws {
        var connection = SSHConnection()
        connection.defaultPath = "/"
        connection.initialCommand = "printf 'startup:%s' \"$PWD\"; exit"
        let command = try XCTUnwrap(TerminalShellIntegration.startupCommand(for: connection))
        for shell in ["/bin/bash", "/bin/zsh"] {
            let output = try run(shell, script: command)
            XCTAssertTrue(output.hasSuffix("startup:/"))
        }
    }

    func testStartupCommandQuotesDirectoryAndContainsNoHistoryHook() throws {
        var connection = SSHConnection()
        connection.defaultPath = "/srv/app's release"
        connection.initialCommand = "tmux attach"
        let command = try XCTUnwrap(TerminalShellIntegration.startupCommand(for: connection))
        XCTAssertEqual(command, "cd -- '/srv/app'\"'\"'s release' && tmux attach; exec \"${SHELL:-/bin/sh}\" -l")
        XCTAssertFalse(command.contains("PROMPT_COMMAND"))
        XCTAssertFalse(command.contains("precmd_functions"))
        XCTAssertFalse(command.contains("__t7"))
    }

    func testStartupCommandExpandsHomeDirectoryWithoutUsingInteractiveInput() throws {
        var connection = SSHConnection()
        connection.defaultPath = "~/Projects/Termo build"
        let command = try XCTUnwrap(TerminalShellIntegration.startupCommand(for: connection))
        XCTAssertEqual(command, "cd -- \"$HOME\"/'Projects/Termo build'; exec \"${SHELL:-/bin/sh}\" -l")
    }

    @MainActor
    func testTmuxExactTargetIsQuotedAsOneShellArgument() {
        let target = AppModel.shellEscape("=ops' release")
        XCTAssertEqual("tmux attach -t \(target)", "tmux attach -t '=ops'\\'' release'")
    }
}
