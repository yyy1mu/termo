import SwiftUI

/// AI 面板会话消息：流式 assistant 文本在流结束后固定；exec 消息是执行结果回显。
struct AIMessage: Identifiable {
    enum Role { case user, assistant, system, exec }
    let id = UUID()
    let role: Role
    var content: String
    var streaming = false
    var commands: [String] = []
    /// exec 消息的退出码（nil=仅命令卡片未执行）。
    var exitCode: Int32? = nil
}

/// AI 面板会话状态：消息列表 + 输入 + 发送/取消 + 命令卡片抽取 + 执行结果回显。
/// 会话为单例（右侧伴随面板随窗口只开一处；主机上下文随活动标签变化）。
@MainActor
final class AIChatState: ObservableObject {
    static let shared = AIChatState()
    private init() {}

    @Published var messages: [AIMessage] = []
    @Published var input = ""
    @Published var sending = false
    @Published var errorText: String? = nil
    /// 附带当前终端最近输出作为上下文（可开关，默认开）。
    @Published var includeTerminalContext = true

    private var streamTask: Task<Void, Never>?

    var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    func send(model: AppModel) {
        guard canSend else { return }
        let profile = LLMSettingsStore.load()
        let key = LLMSettingsStore.apiKey
        guard LLMSettingsStore.isConfigured(profile), !key.isEmpty else {
            errorText = String(localized: "请先在「设置 → AI 助手」里完成 LLM 配置（Base URL / API Key / 模型）。")
            return
        }
        errorText = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        messages.append(AIMessage(role: .user, content: text))
        messages.append(AIMessage(role: .assistant, content: "", streaming: true))
        sending = true

        // 组装上下文：系统提示 + （可选）终端最近输出 + 最近会话（最多 12 条，压缩总量）
        var wire: [AIClient.ChatMessage] = [
            .init(role: "system", content: profile.systemPrompt),
        ]
        if includeTerminalContext, let tail = model.terminalTailText(lines: 30), !tail.isEmpty {
            wire.append(.init(role: "user", content: "【当前终端最近输出】\n```\n\(tail)\n```"))
        }
        for m in messages.suffix(13) {
            guard m.role != .system else { continue }
            wire.append(.init(role: m.role == .user ? "user" : "assistant", content: m.content))
        }
        let host = model.companionHost()
        if let h = host {
            wire.insert(.init(role: "system", content: "【当前主机】\(h.name)（\(h.ipOrHost)，用户 \(h.ssh?.user ?? "?")）"), at: 1)
        }

        streamTask = Task {
            defer { sending = false }
            do {
                let stream = AIClient.stream(profile: profile, apiKey: key, messages: wire)
                for try await delta in stream {
                    guard var last = messages.last, last.role == .assistant else { break }
                    last.content += delta
                    messages[messages.count - 1] = last
                }
                finishAssistantMessage()
            } catch is CancellationError {
                finishAssistantMessage(cancelled: true)
            } catch {
                finishAssistantMessage()
                errorText = (error as? AIClient.ClientError)?.message ?? error.localizedDescription
            }
        }
    }

    func cancel() { streamTask?.cancel() }

    private func finishAssistantMessage(cancelled: Bool = false) {
        guard var last = messages.last, last.role == .assistant else { return }
        last.streaming = false
        if cancelled && last.content.isEmpty { last.content = "（已取消）" }
        last.commands = Self.extractCommands(from: last.content)
        messages[messages.count - 1] = last
    }

    /// 从 assistant 文本抽取 ```bash / ```sh / ```shell / 未命名代码块中的命令（逐块为一组）。
    static func extractCommands(from text: String) -> [String] {
        var out: [String] = []
        let pattern = #"```(?:bash|sh|shell|zsh)?\s*\n([\s\S]*?)```"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return out }
        let range = NSRange(text.startIndex..., in: text)
        for m in re.matches(in: text, range: range) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let block = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
            if !block.isEmpty { out.append(String(block)) }
        }
        return out
    }

    /// 执行结果回显：追加 exec 消息（含命令与输出摘要），用户可一键把结果回发给 AI。
    func appendExecResult(command: String, exitCode: Int32, stdout: String, stderr: String) {
        var body = "执行结果（退出码 \(exitCode)）\n"
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { body += "```\n\(out.prefix(4000))\n```\n" }
        if !err.isEmpty { body += "stderr:\n```\n\(err.prefix(2000))\n```" }
        if out.isEmpty && err.isEmpty { body += "（无输出）" }
        messages.append(AIMessage(role: .exec, content: body, exitCode: exitCode))
    }

    /// 把最近一条 exec 结果连同原请求回发给 AI（对话续写：让 AI 看执行输出再决策）。
    func forwardLastExecResult(model: AppModel) {
        guard let last = messages.last, last.role == .exec else { return }
        input = "上一步命令执行结果如下，请基于它继续：\n" + last.content
        send(model: model)
    }

    func clear() { messages.removeAll(); errorText = nil }
}
