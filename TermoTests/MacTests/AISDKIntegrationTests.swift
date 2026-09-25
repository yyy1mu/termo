import AI
import Foundation
import XCTest
@testable import Termo

@MainActor
final class AISDKIntegrationTests: XCTestCase {
    func testCompatibleProviderAssemblesFragmentedCallWithoutExecuting() async throws {
        let fixture = SDKHTTPFixture(events: [
            ["choices": [["delta": ["content": "查看负载"]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "request_shell_command", "arguments": "{\"command\":\"up"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "time\",\"purpose\":\"查看负载\"}"]]]], "finish_reason": "tool_calls"]]]
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        var profile = LLMProfile()
        profile.baseURL = fixture.baseURL + "/v1/"
        let model = try AIClient.model(profile: profile, apiKey: "fixture-key", session: session)
        let events = try await collect(AIClient.stream(model: model, messages: [.user("诊断")], allowTerminalTool: true))
        let calls = events.compactMap { event -> (String, String, String)? in
            if case .toolCall(let id, let name, let arguments) = event { return (id, name, arguments) }
            return nil
        }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.0, "call_1")
        let target = try XCTUnwrap(AIExecutionTarget(Host(id: "fixture", name: "Test", addr: "fixture.invalid", group: "",
            status: .offline, os: "linux", ssh: SSHConnection(host: "fixture.invalid"))))
        let proposal = try XCTUnwrap(AIToolRequest.decode(callID: call.0, name: call.1, arguments: call.2, target: target))
        XCTAssertEqual(proposal.command, "uptime")
        XCTAssertEqual(proposal.decision, .pending)
        XCTAssertFalse(AIClient.commandTool.hasExecutor)
        XCTAssertEqual(fixture.requests.count, 1)
        let sent = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(sent.url?.path, "/v1/chat/completions")
        let body = try fixture.body(of: sent)
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
    }

    func testSDKSerializesApprovedResultUsingOriginalCallID() async throws {
        let fixture = SDKHTTPFixture(events: [["choices": [["delta": ["content": "完成"], "finish_reason": "stop"]]]])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        var profile = LLMProfile(); profile.baseURL = fixture.baseURL
        let call = ToolCall(id: "approved-1", name: "request_shell_command", arguments: ["command": "true", "purpose": "检查"])
        let messages: [AI.Message] = [
            .user("检查主机"), AI.Message(role: .assistant, content: [.toolCall(call)]),
            AI.Message(role: .tool, content: [.toolResult(ToolResult(toolCallID: call.id, name: call.name,
                output: ["exit_code": 0, "stdout": "", "stderr": "warning"]))])
        ]
        _ = try await collect(AIClient.stream(model: AIClient.model(profile: profile, apiKey: "fixture", session: session),
                                              messages: messages, allowTerminalTool: true))
        let body = try fixture.body(of: XCTUnwrap(fixture.requests.first))
        let wire = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual((wire[1]["tool_calls"] as? [[String: Any]])?.first?["id"] as? String, call.id)
        XCTAssertEqual(wire[2]["tool_call_id"] as? String, call.id)
        XCTAssertTrue((wire[2]["content"] as? String)?.contains("warning") == true)
    }

    func testCompactedCheckpointPreservesGoalPairsAndDoesNotRegrowOldHistory() async throws {
        let model = SDKFixtureModel()
        var messages: [AI.Message] = [.system("固定规则"), .user("原始目标：找出故障，不要重启")]
        for _ in 0..<12 { messages.append(.assistant(String(repeating: "旧输出 ", count: 500))) }
        let call = ToolCall(id: "recent", name: "request_shell_command", arguments: ["command": "uptime", "purpose": "检查"])
        messages += [.assistant("最新分析"), AI.Message(role: .assistant, content: [.toolCall(call)]),
                     AI.Message(role: .tool, content: [.toolResult(ToolResult(toolCallID: call.id, name: call.name, output: "真实结果"))]),
                     .user("继续分析结果")]
        let events = try await collect(AIClient.stream(model: model, messages: messages, allowTerminalTool: true))
        let checkpoint = try XCTUnwrap(events.compactMap { event -> [AI.Message]? in
            if case .prepared(let value, let compacted) = event, compacted { return value }; return nil
        }.first)
        XCTAssertLessThan(checkpoint.count, messages.count)
        XCTAssertTrue(checkpoint.contains(.user("原始目标：找出故障，不要重启")))
        XCTAssertTrue(checkpoint.contains { $0.text.contains("已经检查，禁止重放") })
        XCTAssertEqual(checkpoint.suffix(4), messages.suffix(4))
        var context = AIConversationContext()
        context.accept(checkpoint, consumedCount: 20, compacted: true)
        let old = (0..<20).map { AIMessage(role: .user, content: "旧消息 \($0)") }
        let next = context.request(transcript: old + [AIMessage(role: .user, content: "新的问题")],
                                   system: [.system("更新后的固定规则")], attachment: nil, followUp: nil)
        XCTAssertFalse(next.contains { $0.text.contains("旧消息") })
        XCTAssertEqual(next.last, .user("新的问题"))
        XCTAssertEqual(next.filter { $0.role == .system }, [.system("更新后的固定规则")])
        XCTAssertEqual(context.compactionCount, 1)
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2) // one summary, one reply; no SSH or extra tool loop
        XCTAssertTrue(requests[0].tools.isEmpty)
    }

    func testSummaryFallsBackToJSONModeForCompatibleEndpoints() async throws {
        let base = SDKFixtureModel(rejectSchema: true)
        let model = AICompatibleModel(base: base)
        let messages = [.user("诊断，不要重启")] + (0..<20).map { _ in AI.Message.assistant(String(repeating: "旧输出", count: 1000)) }
        let events = try await collect(AIClient.stream(model: model, messages: messages, allowTerminalTool: true))
        XCTAssertTrue(events.contains { if case .prepared(_, true) = $0 { return true }; return false })
        let requests = await base.requests
        XCTAssertEqual(requests.count, 3)
        guard case .jsonNoSchema = requests[1].responseFormat else { return XCTFail("Expected JSON mode fallback") }
        XCTAssertTrue(requests[1].messages.first?.text.contains("schema") == true)
        XCTAssertTrue(requests[1].tools.isEmpty)
    }

    func testSummaryFailureLeavesHistoryUncommitted() async throws {
        let model = SDKFixtureModel(summary: "invalid JSON")
        let original = [.user("保留我的目标")] + (0..<20).map { _ in AI.Message.assistant(String(repeating: "输出", count: 1000)) }
        var prepared = false
        do {
            for try await event in AIClient.stream(model: model, messages: original, allowTerminalTool: false) {
                if case .prepared = event { prepared = true }
            }
            XCTFail("Invalid summary must not replace the history")
        } catch { XCTAssertTrue(error.localizedDescription.contains("原始对话已保留")) }
        XCTAssertFalse(prepared)
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testQuestionModeHasNoToolsAndAttachmentStaysWithItsTurn() async throws {
        let model = SDKFixtureModel()
        let context = AIConversationContext()
        let messages = context.request(transcript: [AIMessage(role: .user, content: "这是什么")],
                                       system: [.system("仅问答")], attachment: "用户主动选择的快照", followUp: nil)
        XCTAssertEqual(messages.map(\.text), ["仅问答", "这是什么", "用户主动选择的快照"])
        _ = try await collect(AIClient.stream(model: model, messages: messages, allowTerminalTool: false))
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].tools.isEmpty)
    }

    func testHTTPFailureIsNotAutomaticallyRetried() async throws {
        let model = SDKFixtureModel(failure: .http(status: 401, body: "invalid key"))
        do {
            _ = try await collect(AIClient.stream(model: model, messages: [.user("诊断")], allowTerminalTool: true))
            XCTFail("Expected authentication failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("API Key")) }
        let requests = await model.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testLegacyEndpointFallbackRetainsCommandAndResult() async throws {
        let model = SDKFixtureModel(rejectTools: true)
        let call = ToolCall(id: "old", name: "request_shell_command", arguments: ["command": "uptime", "purpose": "检查"])
        let history: [AI.Message] = [.user("诊断"), AI.Message(role: .assistant, content: [.toolCall(call)]),
            AI.Message(role: .tool, content: [.toolResult(ToolResult(toolCallID: call.id, name: call.name, output: "负载 1.0"))])]
        _ = try await collect(AIClient.stream(model: model, messages: history, allowTerminalTool: true))
        let requests = await model.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].tools.isEmpty)
        XCTAssertTrue(requests[1].messages.contains { $0.text.contains("uptime") })
        XCTAssertTrue(requests[1].messages.contains { $0.text.contains("负载 1.0") })
        XCTAssertFalse(requests[1].messages.contains { $0.role == .tool })
    }

    func testCancellationReachesSDKModelStream() async throws {
        let model = SDKFixtureModel(pause: true)
        let received = expectation(description: "partial reply")
        let task = Task {
            do {
                for try await event in AIClient.stream(model: model, messages: [.user("诊断")], allowTerminalTool: true) {
                    if case .text = event { received.fulfill() }
                }
            } catch { }
        }
        await fulfillment(of: [received], timeout: 3)
        task.cancel()
        await task.value
        for _ in 0..<100 {
            if await model.cancelled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelled = await model.cancelled
        XCTAssertTrue(cancelled)
    }

    private func collect(_ stream: AsyncThrowingStream<AIClient.StreamEvent, Error>) async throws -> [AIClient.StreamEvent] {
        var events: [AIClient.StreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

private actor SDKFixtureModel: LanguageModel {
    nonisolated let provider = "fixture"
    nonisolated let modelID = "fixture"
    private(set) var requests: [LanguageModelRequest] = []
    private(set) var cancelled = false
    private let summary: String
    private let failure: AIError?
    private let rejectTools: Bool
    private let pause: Bool
    private let rejectSchema: Bool
    init(summary: String = "{\"goal\":\"已经检查，禁止重放\",\"constraints\":[],\"decisions\":[],\"establishedFacts\":[],\"deadEnds\":[],\"openQuestions\":[],\"artifacts\":[]}",
         failure: AIError? = nil, rejectTools: Bool = false, pause: Bool = false, rejectSchema: Bool = false) {
        self.summary = summary; self.failure = failure; self.rejectTools = rejectTools; self.pause = pause; self.rejectSchema = rejectSchema
    }
    func stream(_ request: LanguageModelRequest) async throws -> AsyncThrowingStream<StreamPart, Error> {
        requests.append(request)
        if let failure { throw failure }
        if rejectSchema, case .json = request.responseFormat { throw AIError.http(status: 400, body: "response_format json_schema unsupported") }
        if rejectTools && !request.tools.isEmpty { throw AIError.http(status: 400, body: "tools not supported") }
        let text: String
        switch request.responseFormat {
        case .json, .jsonNoSchema: text = summary
        case .text: text = "模型回复"
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            if pause {
                continuation.onTermination = { _ in Task { await self.didCancel() } }
            } else {
                continuation.yield(.finish(reason: .stop, usage: Usage()))
                continuation.finish()
            }
        }
    }
    private func didCancel() { cancelled = true }
}

/// Intercepts only a unique fixture host. No credentials or requests reach a real endpoint.
private final class SDKHTTPFixture: @unchecked Sendable {
    let host = UUID().uuidString.lowercased() + ".invalid"
    var baseURL: String { "https://" + host }
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private let data: Data
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    init(events: [[String: Any]]) {
        let lines = events.map { "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n\n" }
        data = Data((lines.joined() + "data: [DONE]\n\n").utf8)
    }
    func session() -> URLSession {
        SDKFixtureProtocol.register(self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SDKFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    func remove() { SDKFixtureProtocol.remove(host) }
    func respond(_ request: URLRequest) -> Data {
        lock.lock(); captured.append(request); lock.unlock()
        return data
    }
    func body(of request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

private final class SDKFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: SDKHTTPFixture] = [:]
    static func register(_ fixture: SDKHTTPFixture) { lock.lock(); fixtures[fixture.host] = fixture; lock.unlock() }
    static func remove(_ host: String) { lock.lock(); fixtures.removeValue(forKey: host); lock.unlock() }
    private static func fixture(_ request: URLRequest) -> SDKHTTPFixture? {
        lock.lock(); defer { lock.unlock() }; return fixtures[request.url?.host ?? ""]
    }
    override class func canInit(with request: URLRequest) -> Bool { fixture(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = Self.fixture(request), let url = request.url else { return }
        let data = fixture.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                           headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
