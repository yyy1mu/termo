import SwiftUI

/// AI 助手伴随面板：会话消息流 + 命令卡片 + 输入区。
/// 命令卡片三个动作：复制 / 插入终端 / 请求执行（执行需用户批准，见 AIExecuteConfirmDialog）。
struct AIPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var chat = AIChatState.shared
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let err = chat.errorText {
                Text(err)
                    .font(.system(size: 11)).foregroundStyle(Pal.red)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Pal.red.opacity(0.08))
            }
            inputBar
        }
    }

    // MARK: 消息流

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(chat.messages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) { _ in
                proxy.scrollTo(chat.messages.last?.id, anchor: .bottom)
            }
            .onChange(of: chat.messages.last?.content.count ?? 0) { _ in
                // 流式增量时也随最后一条滚动
                proxy.scrollTo(chat.messages.last?.id, anchor: .bottom)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Pal.mauve.opacity(0.8))
            Text("向 AI 描述你要做什么，它会给命令；命令卡片可「插入终端」或「请求执行」（执行前会再问你一次）。")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !LLMSettingsStore.isConfigured(LLMSettingsStore.load()) {
                Button { model.showSettings = true; model.settingsTab = .ai } label: {
                    Text("先去配置 LLM（设置 → AI 助手）").font(.system(size: 12))
                        .foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private func messageRow(_ msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch msg.role {
            case .user:
                Text(msg.content)
                    .font(.system(size: 12)).foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                assistantBlock(msg)
            case .exec:
                execBlock(msg)
            case .system:
                EmptyView()
            }
        }
    }

    private func assistantBlock(_ msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Pal.mauve)
                if msg.streaming {
                    ProgressView().controlSize(.mini)
                }
            }
            // 正文剥掉 ``` 围栏代码块（命令统一由下方命令卡片渲染，避免同一条命令出现两遍）
            let prose = AIChatState.stripCodeBlocks(from: msg.content, streaming: msg.streaming)
            if !prose.isEmpty {
                Text(prose)
                    .font(.system(size: 12)).foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(msg.commands.enumerated()), id: \.offset) { _, cmd in
                commandCard(cmd)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func commandCard(_ cmd: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(cmd)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                miniAction("doc.on.doc", String(localized: "复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
                miniAction("arrow.right.to.line", String(localized: "插入终端")) {
                    insertIntoTerminal(cmd)
                }
                miniAction("play.circle", String(localized: "请求执行"), accent: Pal.green) {
                    requestExecute(cmd)
                }
            }
        }
    }

    private func miniAction(_ symbol: String, _ title: String, accent: Color = Pal.mauve, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func execBlock(_ msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                if msg.running {
                    ProgressView().controlSize(.mini)
                    PanelBadgeView(text: "执行中", color: Pal.mauve)
                } else if let code = msg.exitCode {
                    PanelBadgeView(text: "退出码 \(code)", color: code == 0 ? Pal.green : Pal.red)
                }
                if !msg.execHost.isEmpty {
                    PanelBadgeView(text: msg.execHost, color: Pal.mauve)
                }
            }
            if !msg.execCommand.isEmpty {
                Text(msg.execCommand)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
            }
            let out = msg.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = msg.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.running {
                Text("正在主机上执行，完成后自动显示结果…")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            } else if !out.isEmpty {
                Text(out)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !err.isEmpty {
                Text(err)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.red.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if out.isEmpty && err.isEmpty {
                Text("（无输出）").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            miniAction("arrow.turn.up.right", String(localized: "把结果回发给 AI"), accent: Pal.mauve) {
                chat.forwardLastExecResult(model: model)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: 输入区

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Pal.border).frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                Toggle(isOn: $chat.includeTerminalContext) {
                    Image(systemName: "terminal").font(.system(size: 11))
                        .foregroundStyle(chat.includeTerminalContext ? Pal.mauve : Pal.overlay)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help(String(localized: "附带终端上下文"))
                .pointerCursor()

                TextField(String(localized: "描述任务或提问…"), text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Pal.text)
                    .lineLimit(1...4)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { chat.send(model: model) }

                if chat.sending {
                    Button { chat.cancel() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 18)).foregroundStyle(Pal.red)
                    }
                    .buttonStyle(.plain).pointerCursor().help(String(localized: "停止"))
                } else {
                    Button { chat.send(model: model) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                            .foregroundStyle(chat.canSend ? Pal.mauve : Pal.overlay.opacity(0.4))
                    }
                    .buttonStyle(.plain).pointerCursor().disabled(!chat.canSend)
                }
            }
            .padding(10)
            .background(Pal.crust)
        }
    }

    // MARK: 动作

    private func insertIntoTerminal(_ cmd: String) {
        // 走既有片段注入（不加回车——与「插入」语义一致：用户确认后自己回车）。
        guard model.snippetTargetTabIdPublic() != nil else {
            chat.errorText = String(localized: "请先打开并切到一个终端，再插入命令。")
            return
        }
        model.deliverSnippetPublic(cmd, run: false)
    }

    private func requestExecute(_ cmd: String) {
        guard let host = model.companionHost() else {
            chat.errorText = String(localized: "请先选中一台 SSH 主机（终端/概览页），AI 命令将在其上执行。")
            return
        }
        model.pendingAIExecution = AIExecutionRequest(command: cmd, host: host)
    }
}

/// 轻量徽章（供 exec 消息退出码显示）。
private struct PanelBadgeView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
