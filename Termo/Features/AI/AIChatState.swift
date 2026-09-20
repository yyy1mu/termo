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
    var stdout = ""
    var stderr = ""
}

/// AI 面板会话状态：消息列表 + 输入 + 发送/取消 + 命令卡片抽取 + 执行结果回显。
/// 每个终端标签一个实例（见 AIChatStore），随标签绑定；tabId=nil 为未绑定终端的通用会话。
@MainActor
final class AIChatState: ObservableObject {
    /// 对话模式：命令只做「复制/输入终端」，由用户掌控；
    /// Agent 模式：用户点「批准执行」命令即在当前终端运行，AI 自动读输出续写下一步直到解决。
    enum ChatMode: String, CaseIterable {
        case chat = "对话"
        case agent = "Agent"
    }

    /// 绑定的终端标签 id（nil=通用会话：未开终端时也能单独问 AI）。
    let tabId: Int?

    init(tabId: Int? = nil) {
        self.tabId = tabId
    }

    @Published var messages: [AIMessage] = []
    @Published var input = ""
    @Published var sending = false
    @Published var mode: ChatMode = .chat
    @Published var errorText: String? = nil

    private var streamTask: Task<Void, Never>?
    /// Agent 模式的延时回读任务（命令执行后自动抓终端输出发给 LLM）。
    private var agentTask: Task<Void, Never>?

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
        var prompt = profile.systemPrompt
        if mode == .agent {
            prompt += """
            \n【Agent 模式规则】每次只给一条 ```bash 命令（不要一次给多条）；\
            我会把命令在你终端里的执行输出发回给你，你再给下一条命令；\
            问题解决后只输出中文文字总结，不要再给任何命令。
            """
        }
        var wire: [AIClient.ChatMessage] = [
            .init(role: "system", content: prompt),
        ]
        // 终端上下文常开：本会话绑定终端的命令/输出记录尾部（$ 标记命令行；
        // 比屏幕抓取多得多——含滚出屏幕的输出，且不串其它终端）
        if let tabId, let tail = model.transcriptTail(tabId: tabId, maxChars: 4000), !tail.isEmpty {
            wire.append(.init(role: "user", content: "【当前终端最近的命令与输出】\n```\n\(tail)\n```"))
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

    func cancel() {
        streamTask?.cancel()
        agentTask?.cancel()
        agentTask = nil
    }

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
            out = String(out[..<r.lowerBound])
        }
        while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 命令已写到当前终端（未回车）的回显消息：真正的批准与执行由用户按回车完成。
    func noteTerminalExec(command: String) {
        messages.append(AIMessage(role: .exec, content: "", execCommand: command))
    }

    /// Agent：用户批准命令 → 输入当前终端并回车（可见执行）→ 按完成钩子就位分派：
    /// 登录 shell 精确等待 OSC 133;D 完成标记（退出码+输出切片，30s 超时兜底）；
    /// tmux/本地终端无钩子 → 短等后直接用记录尾部（不干等）。
    /// 循环终止：LLM 不再给命令（纯文字总结）。「停止」可打断。
    func approveAgentRun(model: AppModel, command: String) {
        agentTask?.cancel()
        noteTerminalExec(command: command)
        let cmd = command
        guard let tabId else {   // 通用会话（无绑定终端）：只输入，不进入自动循环
            model.deliverSnippetPublic(command, run: true)
            return
        }
        model.deliverSnippetPublic(command, run: true)
        let hooked = model.completionReadyTabs.contains(tabId)
        agentTask = Task { [weak self] in
            guard let self else { return }
            var exitCode: Int32
            var output: String
            if hooked {
                let result = await model.awaitCommandCompletion(tabId: tabId, timeout: 30_000_000_000)
                guard !Task.isCancelled else { return }
                exitCode = result.exitCode
                output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                exitCode = -1
                output = (model.transcriptTail(tabId: tabId, maxChars: 3000) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let codeText = exitCode >= 0 ? "退出码 \(exitCode)" : "退出码未知"
            input = "命令「\(cmd)」已执行（\(codeText)）。输出：\n\(output.isEmpty ? "（无输出）" : output)\n请继续下一步；若问题已解决，只输出文字总结。"
            send(model: model)
        }
    }

    /// 清空会话：消息/错误清空，同时停掉 agent 回读循环与流式输出。
    func clear() {
        cancel()
        sending = false
        messages.removeAll()
        errorText = nil
    }
}

/// 会话注册表（Multiton）：按终端标签 id 持有独立会话，切标签即切会话。
/// 标签关闭时 discard 回收，避免随标签数无限增长。
@MainActor
final class AIChatStore {
    static let shared = AIChatStore()
    private init() {}

    private var sessions: [Int: AIChatState] = [:]
    private var scratch: AIChatState? = nil   // 未绑定终端的通用会话（懒创建）

    func session(for tabId: Int?) -> AIChatState {
        guard let tabId else {
            if let scratch { return scratch }
            let s = AIChatState(tabId: nil)
            scratch = s
            return s
        }
        if let s = sessions[tabId] { return s }
        let s = AIChatState(tabId: tabId)
        sessions[tabId] = s
        return s
    }

    func discard(tabId: Int) {
        sessions.removeValue(forKey: tabId)
        if scratch?.tabId == nil { /* scratch 与标签无关，不回收 */ }
    }
}
