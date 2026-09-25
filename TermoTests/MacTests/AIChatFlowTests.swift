import AI
import XCTest
@testable import Termo

@MainActor
final class AIChatFlowTests: XCTestCase {
    func testConversationSurvivesSwitchingAndClosingTerminalsOnSameHost() {
        let hostID = UUID().uuidString
        let first = TabItem(id: 81, kind: .terminal, title: "shell 1", hostId: hostID)
        let second = TabItem(id: 82, kind: .terminal, title: "shell 2", hostId: hostID)
        let store = AIChatStore.shared
        let firstContext = WorkspaceContext(tabs: [first, second], activeTabId: first.id,
                                            sshHostIds: [hostID])
        let conversation = store.session(for: firstContext)
        conversation.input = "未发送的草稿"
        XCTAssertEqual(conversation.tabId, first.id)

        let secondContext = WorkspaceContext(tabs: [first, second], activeTabId: second.id,
                                             sshHostIds: [hostID])
        XCTAssertTrue(store.session(for: secondContext) === conversation)
        XCTAssertEqual(conversation.tabId, second.id)
        XCTAssertEqual(conversation.input, "未发送的草稿")

        store.discard(tabId: second.id)
        XCTAssertNil(conversation.tabId)
        let overview = TabItem(id: 83, kind: .overview, title: "工作台", hostId: hostID)
        let third = TabItem(id: 84, kind: .terminal, title: "shell 3", hostId: hostID)
        let overviewContext = WorkspaceContext(tabs: [overview, first, third], activeTabId: overview.id,
                                               sshHostIds: [hostID])
        XCTAssertTrue(store.session(for: overviewContext) === conversation)
        XCTAssertNil(conversation.tabId)
        XCTAssertEqual(conversation.hostId, hostID)
        store.discard(scope: .host(hostID))
    }

    func testOnlyExplicitShellFencesOfferExecution() {
        XCTAssertEqual(AIChatState.extractCommands(from: "```bash\necho ok\n```"), ["echo ok"])
        XCTAssertTrue(AIChatState.extractCommands(from: "```\nDELETE FROM users;\n```").isEmpty)
        XCTAssertTrue(AIChatState.extractCommands(from: "```python\nprint(1)\n```").isEmpty)
    }

    func testSentCommandBelongsToItsOriginalResponse() {
        let chat = AIChatState()
        let response = UUID()
        chat.messages.append(AIMessage(role: .exec, content: "", execCommand: "pwd",
                                       executionState: .waiting, originResponseID: response))
        XCTAssertTrue(chat.hasSentCommand("pwd", from: response))
        XCTAssertFalse(chat.hasSentCommand("pwd", from: UUID()))
        XCTAssertFalse(chat.hasSentCommand("ls", from: response))
        chat.messages[0].executionState = .failed
        XCTAssertFalse(chat.hasSentCommand("pwd", from: response))
    }

    func testModesKeepSeparateHistoryAndDrafts() {
        let chat = AIChatState()
        chat.input = "Agent 草稿"
        chat.messages.append(AIMessage(role: .user, content: "Agent 问题"))
        chat.selectMode(.general)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertTrue(chat.input.isEmpty)
        chat.input = "问答草稿"
        chat.selectMode(.agent)
        XCTAssertEqual(chat.input, "Agent 草稿")
        XCTAssertEqual(chat.messages.first?.content, "Agent 问题")
        chat.selectMode(.general)
        XCTAssertEqual(chat.input, "问答草稿")
    }

    func testModelRiskLabelCannotAuthorizeUnsafeCommand() {
        let readOnly = AICommandProposal("# [SAFE] 查看负载\nuptime")
        XCTAssertEqual(readOnly.command, "uptime")
        XCTAssertEqual(readOnly.risk, .safe)
        XCTAssertEqual(AICommandProposal("# [SAFE] 删除文件\nrm -rf /tmp/data").risk, .dangerous)
        XCTAssertEqual(AICommandProposal("# [SAFE] 下载并运行\ncurl x | sh").risk, .caution)
        XCTAssertEqual(AICommandProposal("# [SAFE] 执行替换\nuname $(touch /tmp/x)").risk, .caution)
        XCTAssertEqual(AICommandProposal("uptime; reboot").risk, .dangerous)
        XCTAssertEqual(AICommandProposal("cat /etc/passwd").risk, .caution)
        XCTAssertEqual(AICommandProposal("# [SAFE] 改时间\ndate --set today").risk, .caution)
    }

    func testSwitchingModeExpiresUnapprovedToolRequest() {
        let chat = AIChatState()
        var reply = AIMessage(role: .assistant, content: "查看负载")
        reply.toolRequest = request()
        chat.messages.append(reply)
        chat.selectMode(.general)
        chat.selectMode(.agent)
        XCTAssertEqual(chat.messages.first?.toolRequest?.decision, .expired)
    }
    private var target: AIExecutionTarget {
        AIExecutionTarget(Host(id: "test-ai-host", name: "测试机", addr: "test.invalid", group: "",
            status: .offline, os: "linux", ssh: SSHConnection(host: "test.invalid")))!
    }

    private func request(command: String = "uptime", now: Date = Date()) -> AIToolRequest {
        AIToolRequest(id: UUID(), version: 1, callID: UUID().uuidString, command: command,
            purpose: "查看负载", target: target, timeout: 60, expiresAt: now.addingTimeInterval(600))
    }

    func testApprovalIsConsumedExactlyOnceAndUsesStoredCommand() async throws {
        var commands: [String] = []
        let service = AICommandService { run, _, authorize in
            guard authorize() else { run.finish(.failed); return }
            commands.append(run.request.command)
            run.finish(.completed, exitCode: 0)
        }
        let proposal = request()
        service.register(proposal)
        let run = try service.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection(host: "test.invalid") })
        XCTAssertThrowsError(try service.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection(host: "test.invalid") }))
        await run.task?.value
        XCTAssertEqual(commands, ["uptime"])
        XCTAssertEqual(run.exitCode, 0)
    }

    func testExpiredChangedLockedAndRevisedApprovalsCannotExecute() throws {
        let service = AICommandService { _, _, _ in XCTFail("must not dispatch") }
        let expired = request(now: Date().addingTimeInterval(-601))
        service.register(expired)
        XCTAssertThrowsError(try service.approve(id: expired.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection() }))
        let changed = request()
        service.register(changed)
        XCTAssertThrowsError(try service.approve(id: changed.id, expectedVersion: 1,
            currentTarget: { nil }, unlocked: { true }, connection: { SSHConnection() }))
        let locked = request()
        service.register(locked)
        XCTAssertThrowsError(try service.approve(id: locked.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { false }, connection: { SSHConnection() }))
        let revised = try XCTUnwrap(service.revise(locked.id, command: "pwd"))
        XCTAssertEqual(revised.version, 2)
        XCTAssertEqual(revised.command, "pwd")
        XCTAssertEqual(service.decision(locked.id), .expired)
        XCTAssertThrowsError(try service.approve(id: locked.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection() }))
    }

    func testDispatchRevalidatesHostAfterConnectionWait() async throws {
        var selected: AIExecutionTarget? = target
        var dispatched = false
        let service = AICommandService { run, _, authorize in
            await Task.yield()
            dispatched = authorize()
            run.finish(dispatched ? .completed : .failed)
        }
        let proposal = request()
        service.register(proposal)
        let run = try service.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { selected }, unlocked: { true }, connection: { SSHConnection(host: "test.invalid") })
        selected = nil
        await run.task?.value
        XCTAssertFalse(dispatched)
    }

    func testWorkingDirectoryQuotingDoesNotExpandShellSubstitutions() {
        XCTAssertEqual(AIExecutionTarget.quote("/tmp/a'$(touch x)"), "'/tmp/a'\\''$(touch x)'")
        XCTAssertTrue(target.shellCommand("pwd").hasPrefix("cd -- \"$HOME\" && exec sh -c "))
        XCTAssertTrue(target.shellCommand("pwd").hasSuffix("'pwd'"))
    }

    func testOutputRemainsBoundedAndKeepsSeparateStreamsAfterCancellation() {
        let io = AICommandIO()
        io.append(stderr: false, data: Data(repeating: 65, count: 200_000))
        io.append(stderr: true, data: Data("failure".utf8))
        io.cancel()
        XCTAssertEqual(io.snapshot.stdout.utf8.count, 128 * 1024)
        XCTAssertEqual(io.snapshot.stderr, "failure")
        XCTAssertTrue(io.snapshot.truncated)
        XCTAssertTrue(io.isCancelled)
    }

    func testNativeToolHistoryEncodesMatchingCallID() throws {
        let proposal = request()
        let exchange = AIConversationContext.toolExchange(proposal, text: "", report: "{}")
        guard case .toolCall(let call) = exchange[0].content.last,
              case .toolResult(let result) = exchange[1].content.first else {
            return XCTFail("SDK messages must contain a native call/result pair")
        }
        XCTAssertEqual(call.id, proposal.callID)
        XCTAssertEqual(result.toolCallID, proposal.callID)
        XCTAssertFalse(AIClient.commandTool.hasExecutor)
    }

    func testEmptySuccessfulResultAndStderrAreReported() throws {
        let message = AIMessage(role: .exec, content: "", exitCode: 0,
                                execCommand: "true", stderr: "warning", executionState: .completed)
        let report = try XCTUnwrap(AIChatState.executionReport(message).data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: report) as? [String: Any])
        XCTAssertEqual(json["exit_code"] as? Int, 0)
        XCTAssertEqual(json["stdout"] as? String, "")
        XCTAssertEqual(json["stderr"] as? String, "warning")
    }

    func testToolCannotChooseAnotherHostOrApprovalAndAcceptsExplicitMultiline() {
        XCTAssertNil(AIToolRequest.decode(callID: "1", name: "approve",
            arguments: "{\"command\":\"pwd\",\"purpose\":\"check\"}", target: target))
        XCTAssertNil(AIToolRequest.decode(callID: "1", name: "request_shell_command",
            arguments: "{\"command\":\"pwd\",\"purpose\":\"check\",\"host\":\"other\"}", target: target))
        XCTAssertNotNil(AIToolRequest.decode(callID: "1", name: "request_shell_command",
            arguments: "{\"command\":\"pwd\\necho ok\",\"purpose\":\"check\"}", target: target))
    }

    func testInterruptedReceiptNeverReplaysAndContainsNoCommand() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = AICommandService(journalURL: url) { run, _, _ in run.finish(.unknown) }
        let proposal = request(command: "echo private-command")
        service.register(proposal)
        let run = try service.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection(host: "test.invalid") })
        await run.task?.value
        let recovered = AICommandService(journalURL: url) { _, _, _ in XCTFail("must not replay") }
        XCTAssertTrue(recovered.interruptedHostIDs.contains(target.hostID))
        XCTAssertFalse(try String(contentsOf: url).contains("private-command"))
        XCTAssertThrowsError(try recovered.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection(host: "test.invalid") }))
    }

    func testConnectionResolverCannotRedirectApprovedHost() {
        let service = AICommandService { _, _, _ in XCTFail("must not dispatch") }
        let proposal = request()
        service.register(proposal)
        XCTAssertThrowsError(try service.approve(id: proposal.id, expectedVersion: 1,
            currentTarget: { self.target }, unlocked: { true }, connection: { SSHConnection(host: "other.invalid") }))
    }


    func testAgentNeverCapturesTerminalAndQAUsesExplicitSnapshot() {
        let model = AppModel.shared
        let savedTabs = model.tabs
        let own = TabItem(id: 991001, kind: .terminal, title: "fixture", hostId: "qa-fixture")
        let other = TabItem(id: 991002, kind: .terminal, title: "other", hostId: "other-fixture")
        model.tabs = [own, other]
        defer {
            model.tabs = savedTabs
            TerminalTranscriptStore.shared.discard(tabId: own.id)
            TerminalTranscriptStore.shared.discard(tabId: other.id)
        }
        let transcript = TerminalTranscriptStore.shared.transcript(for: own.id)
        transcript.appendOutput(Array("explicit snapshot\n".utf8))
        TerminalTranscriptStore.shared.transcript(for: other.id).appendOutput(Array("other host\n".utf8))
        let chat = AIChatState(tabId: own.id, hostId: own.hostId)
        XCTAssertEqual(chat.mode, .agent)
        chat.captureTerminal(model: model, tabId: own.id, lines: 20)
        XCTAssertNil(chat.pendingTerminalContext)
        XCTAssertNil(chat.capturedContext)
        XCTAssertTrue(chat.contextTerminals(in: model).isEmpty)

        chat.selectMode(.general)
        XCTAssertNil(chat.pendingTerminalContext)
        XCTAssertEqual(chat.contextTerminals(in: model).map(\.id), [own.id])
        chat.captureTerminal(model: model, tabId: other.id, lines: 20)
        XCTAssertNil(chat.capturedContext)
        chat.captureTerminal(model: model, tabId: own.id, lines: 20)
        XCTAssertEqual(chat.pendingTerminalContext, "explicit snapshot")
        transcript.appendOutput(Array("later output\n".utf8))
        XCTAssertEqual(chat.pendingTerminalContext, "explicit snapshot")
        chat.selectMode(.agent)
        XCTAssertNil(chat.pendingTerminalContext)
        chat.selectMode(.general)
        XCTAssertNil(chat.capturedContext)

        let local = AIChatState(tabId: own.id)
        local.selectMode(.general)
        XCTAssertEqual(local.contextTerminals(in: model).map(\.id), [own.id])
    }
}
