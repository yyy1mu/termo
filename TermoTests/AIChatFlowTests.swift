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

    func testUnknownCompletionWithoutOutputDoesNotTriggerAIAnalysis() {
        XCTAssertFalse(AIChatState.shouldAnalyzeReadback(output: "  \n", exitCode: nil))
        XCTAssertTrue(AIChatState.shouldAnalyzeReadback(output: "READY", exitCode: nil))
        XCTAssertTrue(AIChatState.shouldAnalyzeReadback(output: "", exitCode: 0))
    }

    func testModesKeepSeparateHistoryAndDrafts() {
        let chat = AIChatState()
        chat.input = "运维草稿"
        chat.messages.append(AIMessage(role: .user, content: "运维问题"))
        chat.selectMode(.general)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertTrue(chat.input.isEmpty)
        chat.input = "问答草稿"
        chat.selectMode(.agent)
        XCTAssertTrue(chat.messages.isEmpty)
        chat.selectMode(.ops)
        XCTAssertEqual(chat.input, "运维草稿")
        XCTAssertEqual(chat.messages.first?.content, "运维问题")
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

    func testFragmentedNativeToolCallBecomesOneApprovalRequest() {
        var accumulator = AIClient.ToolCallAccumulator()
        accumulator.append(delta: ["tool_calls": [[
            "index": 0, "id": "call_1", "function": ["name": "run_terminal_command",
                                                      "arguments": "{\"command\":\"up"]
        ]]])
        accumulator.append(delta: ["tool_calls": [[
            "index": 0, "function": ["arguments": "time\",\"purpose\":\"查看负载\"}"]
        ]]])
        XCTAssertEqual(accumulator.calls.count, 1)
        let call = accumulator.calls[0]
        let request = AIToolRequest.decode(callID: call.id, name: call.name,
            arguments: call.arguments, targetTabID: 81, targetTitle: "shell 1")
        XCTAssertEqual(request?.command, "uptime")
        XCTAssertEqual(request?.purpose, "查看负载")
        XCTAssertEqual(request?.targetTabID, 81)
        XCTAssertEqual(request?.decision, .pending)
    }

    func testToolRequestRejectsUnknownNameAndMultilineCommand() {
        XCTAssertNil(AIToolRequest.decode(callID: "1", name: "delete_file",
            arguments: "{\"command\":\"rm -rf /\",\"purpose\":\"清理\"}",
            targetTabID: 1, targetTitle: "shell"))
        XCTAssertNil(AIToolRequest.decode(callID: "2", name: "run_terminal_command",
            arguments: "{\"command\":\"pwd\\nreboot\",\"purpose\":\"检查\"}",
            targetTabID: 1, targetTitle: "shell"))
    }

    func testSwitchingModeExpiresUnapprovedToolRequest() {
        let chat = AIChatState()
        var reply = AIMessage(role: .assistant, content: "查看负载")
        reply.toolRequest = AIToolRequest(callID: "call_1", command: "uptime",
            purpose: "查看负载", targetTabID: 81, targetTitle: "shell 1")
        chat.messages.append(reply)
        chat.selectMode(.general)
        chat.selectMode(.ops)
        XCTAssertEqual(chat.messages.first?.toolRequest?.decision, .expired)
    }
}
