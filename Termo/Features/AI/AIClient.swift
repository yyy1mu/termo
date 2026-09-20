import Foundation

/// OpenAI 兼容 chat/completions 流式客户端（SSE）。
/// 覆盖 DeepSeek / Moonshot / OpenAI 官方 / ollama 等同一协议端点；
/// 请求体仅 messages+model+temperature+stream，最大化兼容面。
actor AIClient {
    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    struct ClientError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 发起流式请求：逐段产出增量文本（delta.content）。取消即抛 CancellationError。
    static func stream(profile: LLMProfile, apiKey: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = profile.chatCompletionsURL else {
                        throw ClientError(message: "Base URL 无效")
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 120
                    let body: [String: Any] = [
                        "model": profile.model,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "temperature": profile.temperature,
                        "stream": true,
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ClientError(message: "响应不是 HTTP")
                    }
                    guard http.statusCode == 200 else {
                        var snippet = ""
                        for try await line in bytes.lines.prefix(40) { snippet += line + "\n" }
                        throw ClientError(message: "HTTP \(http.statusCode)：\(snippet.prefix(300))")
                    }

                    // SSE 解析：按行读，data: 行 JSON 解码 delta.content；[DONE] 结束。
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty else { continue }
                        continuation.yield(content)
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
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
