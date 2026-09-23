import Foundation

/// OpenAI 兼容 chat/completions 流式客户端（SSE）。
/// 覆盖 DeepSeek / Moonshot / OpenAI 官方 / ollama 等同一协议端点；
/// 运维模式添加单个终端工具定义；旧端点拒绝 tools 时回退到文本建议。
actor AIClient {
    struct ToolCallAccumulator {
        private var parts: [Int: (id: String, name: String, arguments: String)] = [:]

        mutating func append(delta: [String: Any]) {
            guard let calls = delta["tool_calls"] as? [[String: Any]] else { return }
            for call in calls {
                guard let index = call["index"] as? Int else { continue }
                let function = call["function"] as? [String: Any] ?? [:]
                var part = parts[index] ?? ("", "", "")
                part.id += call["id"] as? String ?? ""
                part.name += function["name"] as? String ?? ""
                part.arguments += function["arguments"] as? String ?? ""
                parts[index] = part
            }
        }

        var calls: [(id: String, name: String, arguments: String)] {
            parts.sorted(by: { $0.key < $1.key }).map(\.value)
        }
    }

    enum StreamEvent {
        case text(String)
        case toolCall(id: String, name: String, arguments: String)
    }

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 发起流式请求：文本即时显示；工具调用参数在流结束后组装完整，再交由 UI 请求批准。
    static func stream(profile: LLMProfile, apiKey: String, messages: [ChatMessage],
                       allowTerminalTool: Bool) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = profile.chatCompletionsURL else {
                        throw ClientError(message: "Base URL 无效")
                    }
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        throw ClientError(message: "API Key 未配置：请到 设置 → AI 助手 粘贴并保存")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 120
                    var body: [String: Any] = [
                        "model": profile.model,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "temperature": profile.temperature,
                        "stream": true,
                    ]
                    if allowTerminalTool {
                        body["tools"] = [[
                            "type": "function",
                            "function": [
                                "name": "run_terminal_command",
                                "description": "Request permission to run one shell command in the bound terminal. The app never runs this call without user approval.",
                                "parameters": [
                                    "type": "object",
                                    "properties": [
                                        "command": ["type": "string", "description": "One complete shell command"],
                                        "purpose": ["type": "string", "description": "Brief reason for this command in Chinese"],
                                    ],
                                    "required": ["command", "purpose"],
                                    "additionalProperties": false,
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any]]
                        body["tool_choice"] = "auto"
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    var (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if allowTerminalTool, let initial = response as? HTTPURLResponse,
                       initial.statusCode == 400 || initial.statusCode == 422 {
                        var snippet = ""
                        for try await line in bytes.lines.prefix(40) { snippet += line + "\n" }
                        let reason = snippet.lowercased()
                        if reason.contains("tool") || reason.contains("function") {
                            // 老的兼容端点不支持 tools：回退为单个 bash 块，仍由同一审批卡处理。
                            body.removeValue(forKey: "tools")
                            body.removeValue(forKey: "tool_choice")
                            var fallback = messages.map { ["role": $0.role, "content": $0.content] }
                            fallback.insert(["role": "system", "content":
                                "当前服务不支持工具调用。仅在必须执行时给出一条完整的 bash 代码块，并在正文说明目的；Termo 会先请求用户确认。"], at: 1)
                            body["messages"] = fallback
                            req.httpBody = try JSONSerialization.data(withJSONObject: body)
                            (bytes, response) = try await URLSession.shared.bytes(for: req)
                        } else {
                            throw ClientError(message: "HTTP \(initial.statusCode)：\(snippet.prefix(300))")
                        }
                    }
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError(message: "响应不是 HTTP")
                    }
                    guard http.statusCode == 200 else {
                        if http.statusCode == 401 {
                            throw ClientError(message: "API Key 无效或未保存成功——请到 设置 → AI 助手 重新粘贴 Key 并点保存")
                        }
                        var snippet = ""
                        for try await line in bytes.lines.prefix(40) { snippet += line + "\n" }
                        throw ClientError(message: "HTTP \(http.statusCode)：\(snippet.prefix(300))")
                    }

                    // SSE 的 tool_calls.arguments 可能跨多个 chunk，按 index 累积，结束后才展示审批卡。
                    var toolParts = ToolCallAccumulator()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        if let failure = json["error"] as? [String: Any] {
                            let message = failure["message"] as? String ?? String(localized: "服务返回了错误。")
                            throw ClientError(message: message)
                        }
                        guard let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        toolParts.append(delta: delta)
                    }
                    for part in toolParts.calls {
                        continuation.yield(.toolCall(id: part.id.isEmpty ? UUID().uuidString : part.id,
                                                     name: part.name, arguments: part.arguments))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 非流式一次性请求（设置页「测试连接」用）：拿到完整文本或错误。
    static func ping(profile: LLMProfile, apiKey: String) async throws -> String {
        guard let url = profile.chatCompletionsURL else { throw ClientError(message: "Base URL 无效") }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ClientError(message: "API Key 未配置：请粘贴 Key 并保存") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": profile.model,
            "messages": [["role": "user", "content": "用一句中文回答：服务是否可用？"]],
            "temperature": 0.1,
            "stream": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError(message: "响应不是 HTTP") }
        guard http.statusCode == 200 else {
            throw ClientError(message: "HTTP \(http.statusCode)：\(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ClientError(message: "响应格式异常：无 choices")
        }
        return content
    }
}
