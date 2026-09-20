import SwiftUI

/// AI 助手伴随面板：会话消息流 + 命令卡片 + 输入区。
/// 命令卡片两个动作：复制 / 输入终端（命令放到当前终端提示符，用户回车即批准+执行，无弹窗）。
struct AIPanel: View {
    @ObservedObject var model: AppModel
    /// 绑定当前终端标签的会话（由 RightBar 按 activeTabId 从 AIChatStore 取得）
    @ObservedObject var chat: AIChatState
    @ObservedObject private var theme = ThemeManager.shared
    /// 输入框内容驱动高度（1~4 行），由 AIInputField 的 Coordinator 回写。
    @State private var inputHeight: CGFloat = 34

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
            Text(chat.mode == .chat
                 ? "对话模式：描述你要做什么，AI 给出命令；命令卡片可「复制」或「输入终端」（放到当前终端，回车执行）。"
                 : "Agent 模式：描述你要解决的问题；AI 给出命令，点「批准执行」后在当前终端运行，AI 自动读取输出继续下一步，直到解决。")
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

    /// 绑定指示条：只显示当前会话绑定的终端标签（面板框架头部已有「AI 助手 · 主机」
    /// 标题，不再重复）；切终端即切会话。
    private var bindingHeader: some View {
        let boundTab = model.activeTabId.flatMap { id in model.tabs.first(where: { $0.id == id }) }
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: boundTab == nil ? "circle.dashed" : "terminal")
                    .font(.system(size: 9)).foregroundStyle(boundTab == nil ? Pal.overlay : Pal.mauve)
                Text(boundTab?.title ?? String(localized: "通用会话"))
                    .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
            modeSwitch
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    /// 对话 / Agent 模式切换（每会话独立状态）。
    private var modeSwitch: some View {
        HStack(spacing: 0) {
            ForEach(AIChatState.ChatMode.allCases, id: \.self) { m in
                Button { chat.mode = m } label: {
                    Text(m.rawValue).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(chat.mode == m ? .white : Pal.subtext)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(chat.mode == m ? Pal.mauve : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
        }
        .padding(2)
        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
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
                if chat.mode == .chat {
                    miniAction("keyboard", String(localized: "输入终端"), accent: Pal.mauve) {
                        insertIntoTerminal(cmd)
                    }
                } else {
                    miniAction("play.circle", String(localized: "批准执行"), accent: Pal.green) {
                        approveAgentRun(cmd)
                    }
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
            Text("已在当前终端回车执行；AI 将自动读取输出并继续。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: 输入区

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Pal.border).frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if chat.input.isEmpty {
                        Text(chat.mode == .chat ? "描述任务或提问…" : "描述你要解决的问题…")
                            .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                    AIInputField(text: $chat.input, height: $inputHeight) { chat.send(model: model) }
                        .frame(height: inputHeight)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                }
                .frame(minHeight: 34)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))

                if chat.sending {
                    iconBarButton("stop.fill", active: true, tint: Pal.red,
                                  help: String(localized: "停止")) { chat.cancel() }
                } else {
                    iconBarButton("arrow.up", active: chat.canSend, tint: Pal.mauve,
                                  help: String(localized: "发送")) { chat.send(model: model) }
                    .disabled(!chat.canSend)
                }
            }
            .padding(10)
            .background(Pal.crust)
        }
    }

    /// 输入区统一规格的图标按钮（30x30）：active 时高亮主色。
    private func iconBarButton(_ symbol: String, active: Bool, tint: Color = Pal.mauve,
                               help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? tint : Pal.overlay)
                .frame(width: 30, height: 30)
                .background(active ? tint.opacity(0.14) : Pal.fill(0.05),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help)
    }

    // MARK: 动作

    /// 对话模式：命令写到当前终端提示符（**不带回车**）——用户核对后自己回车执行。
    private func insertIntoTerminal(_ cmd: String) {
        guard model.snippetTargetTabIdPublic() != nil else {
            chat.errorText = String(localized: "请先打开并切到一个终端，命令将输入到当前终端，由你回车执行。")
            return
        }
        model.deliverSnippetPublic(cmd, run: false)
    }

    /// Agent 模式：批准执行 → 命令在当前终端回车运行，AI 自动读输出续写（见 AIChatState.approveAgentRun）。
    private func approveAgentRun(_ cmd: String) {
        guard model.snippetTargetTabIdPublic() != nil else {
            chat.errorText = String(localized: "请先打开并切到一个终端，Agent 命令将在其上执行。")
            return
        }
        chat.approveAgentRun(model: model, command: cmd)
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
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    @ObservedObject var theme = ThemeManager.shared

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, onSubmit: onSubmit)
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
        // overlay 样式 + 自动隐藏：默认 legacy 滚动条在输入框里显示成常驻浅色胶囊（UI 很怪）
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
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
        context.coordinator.updateHeight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var height: CGFloat
        var onSubmit: () -> Void
        weak var view: NSTextView?

        init(text: Binding<String>, height: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            _text = text
            _height = height
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            text = view.string
            updateHeight()
        }

        /// 内容驱动高度：约 1~4 行（34~88pt），超出滚动。
        func updateHeight() {
            guard let view, let tc = view.textContainer, let lm = view.layoutManager else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + 12   // textContainerInset 上下 6
            let clamped = min(max(h, 34), 88)
            if abs(clamped - height) > 1 { height = clamped }
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
