import Foundation
import Security

/// LLM 配置：OpenAI 兼容协议（覆盖 DeepSeek / Moonshot / OpenAI / ollama 等）。
/// apiKey 只进 Keychain（service=com.termo.llmApiKey），绝不写磁盘 JSON；
/// 其余配置走 UserDefaults（非机密）。Anthropic Messages API 属后续扩展位。
struct LLMProfile: Equatable {
    var provider: LLMProvider = .openaiCompat
    var baseURL = "https://api.deepseek.com"
    var model = "deepseek-chat"
    var temperature: Double = 0.3
    /// 注入到会话开头的系统提示；默认含终端助手人设与命令格式约定。
    var systemPrompt = LLMProfile.defaultSystemPrompt

    static let defaultSystemPrompt = """
    你是嵌入在 macOS SSH 终端工具 Termo 里的 AI 运维助手。原则：
    1. 优先给出可直接在远端 Linux 主机执行的单行或短段 shell 命令；
    2. 命令一律用 ```bash 代码块包裹，一条或多条；
    3. 破坏性命令（rm/kill/重启服务/写文件覆盖）必须先说明风险与后果；
    4. 不确定时先给只读探测命令（ls/cat/ps/df）再决策；
    5. 回答用中文，命令保持英文原样。
    """

    /// 服务端点与模型名按 provider 归类（OpenAI 兼容一律 POST {base}/v1/chat/completions）。
    var chatCompletionsURL: URL? { URL(string: baseURL.trimmingCharacters(in: .whitespaces).hasSuffix("/")
        ? baseURL + "v1/chat/completions" : baseURL + "/v1/chat/completions") }
}

enum LLMProvider: String, CaseIterable, Hashable {
    case openaiCompat = "OpenAI 兼容"
    // anthropic: 后续扩展位（/v1/messages 协议不同）
}

/// LLM 配置持久化：apiKey 经 Keychain 读写，其余经 UserDefaults。
enum LLMSettingsStore {
    private static let keyService = "com.termo.llmApiKey"
    private static let keyAccount = "default"
    private static let d = UserDefaults.standard

    static func load() -> LLMProfile {
        var p = LLMProfile()
        if let b = d.string(forKey: "llm.baseURL"), !b.isEmpty { p.baseURL = b }
        if let m = d.string(forKey: "llm.model"), !m.isEmpty { p.model = m }
        if let t = d.object(forKey: "llm.temperature") as? Double { p.temperature = t }
        if let s = d.string(forKey: "llm.systemPrompt"), !s.isEmpty { p.systemPrompt = s }
        return p
    }

    static func save(_ p: LLMProfile) {
        d.set(p.baseURL, forKey: "llm.baseURL")
        d.set(p.model, forKey: "llm.model")
        d.set(p.temperature, forKey: "llm.temperature")
        d.set(p.systemPrompt, forKey: "llm.systemPrompt")
    }

    static var apiKey: String {
        get {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: keyAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data,
                  let s = String(data: data, encoding: .utf8) else { return "" }
            return s
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keyService,
                kSecAttrAccount as String: keyAccount,
            ]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty, let data = newValue.data(using: .utf8) else { return }
            var q = base
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// 配置是否完整可发起请求（baseURL + apiKey + model 非空）。
    static func isConfigured(_ p: LLMProfile) -> Bool {
        !p.baseURL.trimmingCharacters(in: .whitespaces).isEmpty && !p.model.isEmpty && !apiKey.isEmpty
    }
}
