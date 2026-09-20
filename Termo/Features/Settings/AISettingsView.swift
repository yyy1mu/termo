import SwiftUI

/// AI 助手设置：Base URL / API Key（Keychain）/ 模型 / 温度 / 系统提示 + 测试连接。
/// apiKey 只进系统钥匙串（com.termo.llmApiKey），其余走 UserDefaults。
extension SettingsView {
    struct AISettingsContent: View {
        @ObservedObject private var theme = ThemeManager.shared
        @State private var baseURL = ""
        @State private var model = ""
        @State private var apiKey = ""
        @State private var temperature = 0.3
        @State private var systemPrompt = LLMProfile.defaultSystemPrompt
        @State private var testing = false
        @State private var testResult: (ok: Bool, text: String)? = nil

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "AI 助手"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Pal.text)
                    .padding(.bottom, 4)

                VStack(alignment: .leading, spacing: 14) {
                    labeledField(String(localized: "Base URL（OpenAI 兼容）"),
                                 hint: "api.deepseek.com / api.moonshot.cn / api.openai.com / ollama 本地地址",
                                 text: $baseURL, secure: false)
                    labeledField(String(localized: "模型"), hint: "deepseek-chat / kimi-k2 / gpt-4o / llama3.1 …",
                                 text: $model, secure: false)
                    labeledField(String(localized: "API Key（存系统钥匙串）"),
                                 hint: String(localized: "只进 Keychain，不写磁盘"), text: $apiKey, secure: true)

                    HStack(spacing: 10) {
                        Text("温度").font(.system(size: 13)).foregroundStyle(Pal.text)
                        Slider(value: $temperature, in: 0...1, step: 0.1)
                        Text(String(format: "%.1f", temperature)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Pal.subtext).frame(width: 30, alignment: .trailing)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("系统提示").font(.system(size: 13)).foregroundStyle(Pal.text)
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Pal.text)
                            .frame(minHeight: 90, maxHeight: 150)
                            .padding(6)
                            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.border, lineWidth: 1))
                        Text("注入到每次会话开头的角色设定与命令格式约定；默认含「bash 代码块 + 风险声明」要求。")
                            .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    }

                    HStack(spacing: 10) {
                        Button { saveProfile() } label: {
                            Text("保存配置").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor()

                        Button { testConnection() } label: {
                            HStack(spacing: 5) {
                                if testing { ProgressView().controlSize(.mini) }
                                Text(testing ? String(localized: "测试中…") : String(localized: "测试连接"))
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(Pal.text)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerCursor().disabled(testing)

                        if let r = testResult {
                            Text(r.text)
                                .font(.system(size: 11)).foregroundStyle(r.ok ? Pal.green : Pal.red)
                                .lineLimit(1)
                        }
                    }

                    Text("命令执行一律需要用户在弹窗里批准才会真正下发到主机；面板里「插入终端」仅粘贴不回车。")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear { loadProfile() }
        }

        private func labeledField(_ label: String, hint: String, text: Binding<String>, secure: Bool) -> some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(label).font(.system(size: 13)).foregroundStyle(Pal.text)
                Group {
                    if secure {
                        SecureField(hint, text: text)
                    } else {
                        TextField(hint, text: text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.border, lineWidth: 1))
            }
        }

        private func loadProfile() {
            let p = LLMSettingsStore.load()
            baseURL = p.baseURL
            model = p.model
            temperature = p.temperature
            systemPrompt = p.systemPrompt
            apiKey = LLMSettingsStore.apiKey
        }

        private func saveProfile() {
            var p = LLMProfile()
            p.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
            p.model = model.trimmingCharacters(in: .whitespaces)
            p.temperature = temperature
            p.systemPrompt = systemPrompt
            LLMSettingsStore.save(p)
            LLMSettingsStore.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            testResult = (true, String(localized: "已保存"))
        }

        private func testConnection() {
            saveProfile()
            let p = LLMSettingsStore.load()
            let key = LLMSettingsStore.apiKey
            testing = true
            testResult = nil
            Task {
                defer { testing = false }
                do {
                    let text = try await AIClient.ping(profile: p, apiKey: key)
                    testResult = (true, "可用：\(text.prefix(40))")
                } catch {
                    testResult = (false, (error as? AIClient.ClientError)?.message ?? error.localizedDescription)
                }
            }
        }
    }
}
