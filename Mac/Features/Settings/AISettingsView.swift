import SwiftUI

/// Owns the editable snapshot and the test lifecycle, independently of persisted AI configuration.
@MainActor
final class AISettingsDraft: ObservableObject {
    struct Notice: Equatable {
        enum Kind { case success, failure, information }
        let kind: Kind
        let title: String
        let text: String
    }

    @Published var profile: LLMProfile { didSet { configurationChanged() } }
    @Published var apiKey: String { didSet { configurationChanged() } }
    @Published private(set) var testing = false
    @Published private(set) var testResult: Notice?
    @Published private(set) var saveResult: Notice?

    private var savedProfile: LLMProfile
    private var savedAPIKey: String
    private let persist: (LLMProfile, String?) throws -> Void
    private let ping: (LLMProfile, String) async throws -> String
    private var testTask: Task<Void, Never>?
    private var testID: UUID?

    init(
        profile: LLMProfile = LLMSettingsStore.load(),
        apiKey: String = LLMSettingsStore.apiKey,
        persist: @escaping (LLMProfile, String?) throws -> Void = { try LLMSettingsStore.save($0, apiKey: $1) },
        ping: @escaping (LLMProfile, String) async throws -> String = { try await AIClient.ping(profile: $0, apiKey: $1) }
    ) {
        self.profile = profile
        self.apiKey = apiKey
        savedProfile = profile
        savedAPIKey = apiKey
        self.persist = persist
        self.ping = ping
    }

    var isDirty: Bool { profile != savedProfile || apiKey != savedAPIKey }

    var validationMessage: String? {
        guard let url = normalizedProfile.chatCompletionsURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            return String(localized: "请输入以 http:// 或 https:// 开头的服务地址。")
        }
        guard (8_192...2_000_000).contains(profile.contextWindow) else { return String(localized: "上下文容量应在 8192 到 2000000 之间。") }
        guard !normalizedProfile.model.isEmpty else { return String(localized: "请输入模型名称。") }
        return nil
    }

    var canTest: Bool { validationMessage == nil && !normalizedAPIKey.isEmpty }

    func save() {
        guard validationMessage == nil else {
            saveResult = Notice(kind: .failure, title: String(localized: "尚未保存"), text: validationMessage ?? "")
            return
        }
        let next = normalizedProfile
        let key = normalizedAPIKey
        do {
            try persist(next, key == savedAPIKey ? nil : key)
            profile = next
            apiKey = key
            savedProfile = next
            savedAPIKey = key
            saveResult = Notice(kind: .success, title: String(localized: "配置已保存"), text: String(localized: "下一次发送消息时生效。"))
        } catch {
            saveResult = Notice(kind: .failure, title: String(localized: "保存失败"), text: error.localizedDescription)
        }
    }

    func testConnection() {
        guard canTest else { return }
        cancelTest()
        saveResult = nil
        testResult = nil
        testing = true
        let id = UUID()
        testID = id
        let candidate = normalizedProfile
        let key = normalizedAPIKey
        testTask = Task { [weak self, ping] in
            do {
                try Task.checkCancellation()
                let response = try await ping(candidate, key)
                guard let self, self.testID == id, !Task.isCancelled else { return }
                self.testResult = Notice(kind: .success, title: String(localized: "连接成功"), text: response)
                self.finishTest()
            } catch {
                guard let self, self.testID == id, !Task.isCancelled else { return }
                self.testResult = Notice(kind: .failure, title: String(localized: "连接失败"), text: error.localizedDescription)
                self.finishTest()
            }
        }
    }

    func cancelTest() {
        let wasTesting = testing
        testID = nil
        testTask?.cancel()
        testTask = nil
        testing = false
        if wasTesting {
            testResult = Notice(kind: .information, title: String(localized: "测试已取消"), text: String(localized: "配置未保存，可继续编辑或重新测试。"))
        }
    }

    private var normalizedProfile: LLMProfile {
        var value = profile
        value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = value.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private var normalizedAPIKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func configurationChanged() {
        cancelTest()
        testResult = nil
        saveResult = nil
    }

    private func finishTest() {
        testID = nil
        testTask = nil
        testing = false
    }
}

extension SettingsView {
    struct AISettingsContent: View {
        @ObservedObject private var theme = ThemeManager.shared
        @StateObject private var draft: AISettingsDraft

        /// The page owns one draft for its lifetime; injected drafts are used by isolated previews.
        init(draft: AISettingsDraft? = nil) {
            _draft = StateObject(wrappedValue: draft ?? AISettingsDraft())
        }

        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        connectionSection
                        responseSection
                        executionNote
                    }
                    .padding(24)
                }
                .scrollIndicators(.automatic)
                footer
            }
            .background(Pal.base)
            .onDisappear { draft.cancelTest() }
        }

        private var connectionSection: some View {
            section(title: "模型连接", subtitle: "使用 OpenAI 兼容的聊天接口。") {
                field(label: "服务地址", hint: "填写服务的基础地址，可带 /v1。") {
                    ThemedTextField(placeholder: "https://api.example.com/v1", text: $draft.profile.baseURL)
                        .accessibilityLabel("AI 服务地址")
                }
                field(label: "模型名称", hint: "填写服务商提供的模型 ID。") {
                    ThemedTextField(placeholder: "例如 deepseek-chat", text: $draft.profile.model)
                        .accessibilityLabel("AI 模型名称")
                }
                field(label: "API Key", hint: "保存在系统钥匙串；清空后保存可移除。") {
                    ThemedSecureField(placeholder: "粘贴 API Key", text: $draft.apiKey)
                        .accessibilityLabel("AI API Key")
                }
                if let message = draft.validationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(Pal.yellow)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var responseSection: some View {
            section(title: "回复偏好", subtitle: "控制回答的风格与默认要求。") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("回答随机性").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        Spacer()
                        Text(String(format: "%.1f", draft.profile.temperature))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Pal.mauve)
                    }
                    Slider(value: $draft.profile.temperature, in: 0...1, step: 0.1)
                        .tint(Pal.mauve).accessibilityLabel("回答随机性")
                    HStack {
                        Text("更稳定")
                        Spacer()
                        Text("更多变化")
                    }
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                field(label: "上下文容量", hint: "按模型实际支持的容量填写。长对话自动整理为摘要，保留完整聊天记录；整理会调用当前模型。") {
                    TextField("32,000", value: $draft.profile.contextWindow, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("模型上下文容量")
                }
                Divider().overlay(Pal.border)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("系统提示").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        Spacer()
                        Button("恢复默认") { draft.profile.systemPrompt = LLMProfile.defaultSystemPrompt }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            .disabled(draft.profile.systemPrompt == LLMProfile.defaultSystemPrompt)
                            .pointerCursor()
                    }
                    ThemedTextEditor(placeholder: "设置助手的角色、回答语言和命令要求", text: $draft.profile.systemPrompt, height: 170)
                        .accessibilityLabel("AI 系统提示")
                    Text("终端操作通过工具请求卡片审批；自定义提示只补充角色和回答风格。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private var footer: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let result = draft.saveResult ?? draft.testResult {
                    ScrollView { notice(result) }
                        .frame(maxHeight: 110)
                }
                HStack(spacing: 8) {
                    Circle().fill(draft.isDirty ? Pal.yellow : Pal.green).frame(width: 6, height: 6)
                    Text(draft.isDirty ? "有未保存的修改" : "无未保存的修改")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    Spacer(minLength: 0)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text("测试使用当前输入，不会保存配置。")
                            .font(.system(size: 10)).foregroundStyle(Pal.overlay).fixedSize()
                        Spacer(minLength: 6)
                        actionButtons
                    }
                    HStack { Spacer(); actionButtons }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Pal.mantle)
            .overlay(alignment: .top) { Rectangle().fill(Pal.border).frame(height: 1) }
        }

        private var actionButtons: some View {
            HStack(spacing: 8) {
                Button {
                    if draft.testing { draft.cancelTest() } else { draft.testConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if draft.testing { ProgressView().controlSize(.mini) }
                        Text(draft.testing ? "取消测试" : "测试连接")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(!draft.testing && !draft.canTest)
                .help("使用当前输入发送一条测试消息，不会保存配置")

                Button { draft.save() } label: {
                    Text("保存配置").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).pointerCursor()
                .disabled(draft.testing || !draft.isDirty || draft.validationMessage != nil)
            }
        }

        private var executionNote: some View {
            Label {
                Text("AI 建议的命令可先插入终端自行确认；点「运行并分析」才会执行，并把结果发给 AI 继续判断。")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised")
            }
            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
        }

        private func section<Content: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                content()
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.border, lineWidth: 1))
        }

        private func field<Content: View>(label: LocalizedStringKey, hint: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                content()
                Text(hint).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func notice(_ result: AISettingsDraft.Notice) -> some View {
            let color = result.kind == .success ? Pal.green : result.kind == .failure ? Pal.red : Pal.subtext
            let icon = result.kind == .success ? "checkmark.circle.fill" : result.kind == .failure ? "exclamationmark.circle.fill" : "info.circle"
            return VStack(alignment: .leading, spacing: 7) {
                Label(result.title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(result.text).font(.system(size: 11)).foregroundStyle(Pal.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.22), lineWidth: 1))
        }
    }
}
