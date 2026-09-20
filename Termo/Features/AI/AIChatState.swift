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
    /// exec 消息结构化字段：面板按字段渲染（不再用 markdown 围栏裸文本）。
    var execCommand = ""
    var execHost = ""
    var stdout = ""
    var stderr = ""
    /// 执行中（批准后立即占位，完成后原地更新，消除"点了没反应"的空窗）。
    var running = false
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

    /// 命令已输入当前终端（回车执行）后的回显消息：exitCode 保持 nil（输出在终端里）。
    func noteTerminalExec(command: String, host: String) {
        messages.append(AIMessage(role: .exec, content: "",
                                  execCommand: command, execHost: host))
    }

    /// 把当前终端最近输出连同已执行命令回发给 AI（对话续写）。
    func forwardTerminalOutput(model: AppModel, command: String) {
        let tail = model.terminalTailText(lines: 40) ?? ""
        input = "命令「\(command)」已在当前终端执行。终端最近输出：\n\(tail)\n请基于以上输出继续。"
        send(model: model)
    }

    /// 把最近一条 exec 结果连同原命令回发给 AI（对话续写：让 AI 看执行输出再决策）。
    func forwardLastExecResult(model: AppModel) {
        guard let last = messages.last, last.role == .exec else { return }
        var text = "命令「\(last.execCommand)」在 \(last.execHost) 上执行，退出码 \(last.exitCode ?? -1)。执行输出：\n"
        let out = last.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = last.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { text += out + "\n" }
        if !err.isEmpty { text += "stderr: " + err }
        if out.isEmpty && err.isEmpty { text += "（无输出）" }
        input = text + "\n请基于以上结果继续。"
        send(model: model)
    }

    /// 剥掉 assistant 文本里的 ``` 围栏代码块（命令已由命令卡片单独渲染，正文只留说明）。
    /// 流式中的未闭合围栏（最后一个 ``` 到结尾）也一并裁掉，避免裸围栏符闪现。
    static func stripCodeBlocks(from text: String, streaming: Bool = false) -> String {
        var out = text
        let pattern = #"```(?:bash|sh|shell|zsh)?[^`\n]*\n[\s\S]*?```"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }
        if streaming, let r = out.range(of: "```", options: .backwards) {
            out = String(out[..<r.lowerBound])   // 未闭合围栏：裁掉尾部，流结束后会有完整卡片
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clear() { messages.removeAll(); errorText = nil }
}
