import AI
import Foundation

/// A checkpoint of SDK messages, separate from the complete, visible transcript.
/// Only settled turns enter the next request; paired calls/results are never reconstructed from a suffix.
struct AIConversationContext {
    private(set) var history: [AI.Message] = []
    private(set) var consumedCount = 0
    private(set) var compactionCount = 0

    mutating func accept(_ messages: [AI.Message], consumedCount: Int, compacted: Bool) {
        history = messages.filter { $0.role != .system }
        self.consumedCount = consumedCount
        if compacted { compactionCount += 1 }
    }

    @MainActor
    func request(transcript: [AIMessage], system: [AI.Message], attachment: String?, followUp: String?) -> [AI.Message] {
        var result = system + history
        for (index, message) in transcript.enumerated() where index >= consumedCount {
            switch message.role {
            case .user:
                // Keep the user's actual goal first, and the explicitly selected snapshot with its turn.
                result.append(.user(message.content))
                if index == transcript.count - 1, let attachment { result.append(.user(attachment)) }
            case .assistant:
                guard !message.interrupted, message.responseError == nil else { continue }
                if let request = message.toolRequest {
                    let execution = transcript.first { $0.originResponseID == message.id && $0.role == .exec }
                    if let execution, execution.executionState != .waiting, execution.executionState != .connecting {
                        result += Self.toolExchange(request, text: message.content, report: AIChatState.executionReport(execution))
                    } else if request.decision == .rejected || request.decision == .expired {
                        let status = request.decision == .rejected ? "user_rejected" : "expired"
                        result += Self.toolExchange(request, text: message.content, report: "{\"status\":\"\(status)\",\"executed\":false}")
                    }
                } else if !message.content.isEmpty { result.append(.assistant(message.content)) }
            case .exec, .system: break
            }
        }
        if let followUp { result.append(.user(followUp)) }
        return result
    }

    static func toolExchange(_ request: AIToolRequest, text: String, report: String) -> [AI.Message] {
        let call = ToolCall(id: request.callID, name: "request_shell_command", arguments: [
            "command": .string(request.command), "purpose": .string(request.purpose)
        ])
        let output = (try? JSONDecoder().decode(JSONValue.self, from: Data(report.utf8))) ?? .string(report)
        return [
            AI.Message(role: .assistant, content: [.text(text), .toolCall(call)]),
            AI.Message(role: .tool, content: [.toolResult(ToolResult(toolCallID: call.id, name: call.name, output: output))])
        ]
    }
}
