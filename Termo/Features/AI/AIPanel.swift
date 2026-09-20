import SwiftUI

/// AI 助手伴随面板：会话消息流 + 命令卡片 + 输入区。
/// 命令卡片三个动作：复制 / 插入终端 / 请求执行（执行需用户批准，见 AIExecuteConfirmDialog）。
struct AIPanel: View {
    @ObservedObject var model: AppModel
    /// 绑定当前终端标签的会话（由 RightBar 按 activeTabId 从 AIChatStore 取得）
    @ObservedObject var chat: AIChatState
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            bindingHeader
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

    /// 绑定指示头：显示当前会话绑定的终端标签，切终端即切会话。
    private var bindingHeader: some View {
        let boundTab = model.activeTabId.flatMap { id in model.tabs.first(where: { $0.id == id }) }
        return HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Pal.mauve)
            Text("AI 助手").font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: boundTab == nil ? "circle.dashed" : "terminal")
                    .font(.system(size: 9)).foregroundStyle(boundTab == nil ? Pal.overlay : Pal.mauve)
                Text(boundTab?.title ?? String(localized: "通用会话"))
                    .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
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
                miniAction("keyboard", String(localized: "输入终端"), accent: Pal.green) {
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
                Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                PanelBadgeView(text: "已输入终端", color: Pal.mauve)
            }
            if !msg.execCommand.isEmpty {
                Text(msg.execCommand)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("已放到当前终端提示符上——核对无误后按回车执行。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            let out = msg.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = msg.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
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
            miniAction("arrow.turn.up.right", String(localized: "执行后把终端输出发给 AI"), accent: Pal.mauve) {
                chat.forwardTerminalOutput(model: model, command: msg.execCommand)
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

                ZStack(alignment: .topLeading) {
                    if chat.input.isEmpty {
                        Text("描述任务或提问…")
                            .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    AIInputField(text: $chat.input) { chat.send(model: model) }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))

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

    /// 输入终端：命令直接写到当前终端提示符上（**不带回车**）——
    /// 用户核对后自己按回车，回车即批准+执行；无任何弹窗阻断。
    private func requestExecute(_ cmd: String) {
        guard model.snippetTargetTabIdPublic() != nil else {
            chat.errorText = String(localized: "请先打开并切到一个终端，命令将输入到当前终端，由你回车执行。")
            return
        }
        model.deliverSnippetPublic(cmd, run: false)
        chat.noteTerminalExec(command: cmd)
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


/// AI 聊天输入框：封装 NSTextView。
/// 为什么不用 SwiftUI TextField(axis:.vertical)：它在 macOS 不走窗口 field editor，
/// 响应链的 paste: 够不着 → 菜单 ⌘V 对它失效（项目自定义主菜单依赖响应链分发）。
/// NSTextView 原生支持 ⌘V/⌘C/⌘A；回车发送、Shift+回车换行。
struct AIInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    @ObservedObject var theme = ThemeManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textColor = NSColor.labelColor
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [NSView.AutoresizingMask.width]
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.allowsUndo = true
        tv.minSize = NSSize(width: 0, height: 44)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        context.coordinator.view = tv
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        context.coordinator.onSubmit = onSubmit
        // 外部改写文本（发送后清空/回发命令）时同步进来；避免光标处回显递归
        if tv.string != text {
            tv.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        weak var view: NSTextView?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            text = view.string
        }

        /// 回车发送；Shift+回车换行。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSStandardKeyBindingResponding.insertNewline(_:)) else { return false }
            let shift = NSEvent.modifierFlags.contains(.shift)
            guard !shift else { return false }   // 交给系统插入换行
            onSubmit()
            return true
        }
    }
}
