import SwiftUI

/// 主机级助手：可选终端上下文 + 独立 SSH 审批与执行。
struct AIPanel: View {
    @ObservedObject var model: AppModel
    /// 对话与任务由模型保存，收起面板不停止任务。
    @ObservedObject var chat: AIChatState
    @ObservedObject private var theme = ThemeManager.shared
    /// 输入框内容驱动高度（1~4 行），由 AIInputField 的 Coordinator 回写。
    @State private var inputHeight: CGFloat = 34
    /// 用户拖动调整的手动高度（nil=跟随内容自动）；拖一次后手动优先，双击手柄恢复自动。
    @State private var manualInputHeight: CGFloat? = nil
    @State private var dragBaseHeight: CGFloat? = nil
    @State private var confirmClear = false
    @State private var showsContextPreview = false
    @State private var latestMessageRequest = UUID()

    private var effectiveInputHeight: CGFloat { manualInputHeight ?? inputHeight }

    var body: some View {
        VStack(spacing: 0) {
            bindingHeader
            Divider().overlay(Pal.border)
            if chat.messages.isEmpty { emptyHint } else { messageList }
            if let err = chat.errorText {
                Text(err)
                    .font(.system(size: 11)).foregroundStyle(Pal.red)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Pal.red.opacity(0.08))
            }
            inputBar
        }
        .alert("清空当前会话？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { chat.clear() }
        } message: {
            Text("此会话的消息和待确认请求将被移除。")
        }
    }

    // MARK: 消息流

    private var messageList: some View {
        AIMessageList(messages: chat.messages, latestRequest: latestMessageRequest) { messageRow($0) }
    }

    private var emptyHint: some View {
        PanelEmptyState(
            symbol: "sparkles",
            title: chat.mode == .general ? String(localized: "直接提问", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "描述要完成的任务", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            detail: chat.mode == .general
                ? String(localized: "直接提问，或主动附带终端输出进行分析；不会执行命令。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                : String(localized: "先提出命令，经你确认后独立执行，再分析结果。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            actionTitle: String(localized: "AI 设置", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
            action: {
                model.showSettings = true; model.settingsTab = .ai
            },
            symbolColor: Pal.mauve.opacity(0.8)
        )
    }

    private func messageRow(_ msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch msg.role {
            case .user:
                VStack(alignment: .trailing, spacing: 5) {
                    Text(msg.content)
                        .font(.system(size: 12)).foregroundStyle(Pal.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    if let attachment = msg.contextAttachment {
                        Label(contextLabel(attachment), systemImage: attachment == .none ? "bubble.left" : "paperclip")
                            .font(.system(size: 9)).foregroundStyle(Pal.overlay)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            case .assistant:
                assistantBlock(msg)
            case .exec:
                execBlock(msg)
            case .system:
                Label(msg.content, systemImage: "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(Pal.yellow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// 一屏内展示模式、目标与上下文入口；详情仅按需展开。
    private var bindingHeader: some View {
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(AIMode.allCases) { mode in
                        Button { chat.selectMode(mode); showsContextPreview = false } label: {
                            Text(mode.title)
                                .font(.system(size: 11, weight: chat.mode == mode ? .semibold : .medium))
                                .foregroundStyle(chat.mode == mode ? Pal.textBright : Pal.subtext)
                                .padding(.horizontal, 10).frame(height: 27)
                                .background(chat.mode == mode ? Pal.fill(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain).disabled(chat.isBusy)
                    }
                }
                .padding(2)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                Spacer(minLength: 0)
                Menu {
                    Button("AI 设置") { model.showSettings = true; model.settingsTab = .ai }
                    Divider()
                    Button("清空当前会话", role: .destructive) { confirmClear = true }
                        .disabled(chat.messages.isEmpty || chat.isBusy)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 25, height: 25)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(Pal.subtext)
            }
            if chat.mode == .agent {
                HStack(spacing: 6) {
                    Image(systemName: "server.rack").foregroundStyle(Pal.mauve)
                    Text(chat.hostId.flatMap { model.host($0)?.name } ?? String(localized: "未选择 SSH 主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("逐条确认").foregroundStyle(Pal.overlay)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.subtext)
            } else {
                HStack(spacing: 6) {
                    Text("仅回答，不执行命令").font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    Spacer(minLength: 4)
                    Menu {
                        ForEach(chat.contextTerminals(in: model)) { tab in
                            Menu(tab.title) {
                                ForEach([20, 50, 100], id: \.self) { count in
                                    Button("最近 \(count) 行") {
                                        chat.captureTerminal(model: model, tabId: tab.id, lines: count)
                                        showsContextPreview = chat.capturedContext != nil
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("附带终端", systemImage: "paperclip")
                            .font(.system(size: 10)).foregroundStyle(Pal.mauve)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(chat.isBusy || chat.contextTerminals(in: model).isEmpty)
                    .help("主动选择终端输出，预览后随下一条问题发送。")
                }
                if let source = chat.capturedSource {
                    HStack(spacing: 6) {
                        Text("待发送 · \(source)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button(showsContextPreview ? String(localized: "收起", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "预览", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                            showsContextPreview.toggle()
                        }
                        Button("移除") { chat.removeCapturedContext(); showsContextPreview = false }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                }
                if showsContextPreview, let context = chat.capturedContext {
                    ScrollView {
                        Text(context)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Pal.subtext).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(7)
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func assistantBlock(_ msg: AIMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Pal.mauve)
                Text(msg.streaming
                     ? (msg.content.isEmpty ? String(localized: "等待回复", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "正在生成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                     : (msg.responseError != nil ? String(localized: "回复未完成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        : (msg.interrupted ? String(localized: "已停止回复", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "AI 助手", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                if msg.streaming { ProgressView().controlSize(.mini) }
                Spacer(minLength: 4)
                if !msg.streaming && !msg.content.isEmpty {
                    AICopyButton(text: msg.content, title: "复制全文")
                }
            }
            if msg.streaming, msg.content.isEmpty {
                Text("正在等待模型返回内容…")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext).padding(.vertical, 4)
            }
            AIMessageMarkdown(text: msg.content, approvalCommand: msg.toolRequest?.command)
                .equatable()
            if let request = msg.toolRequest {
                toolApprovalCard(request, responseID: msg.id)
            }
            if let error = msg.responseError {
                Text(error).font(.system(size: 11)).foregroundStyle(Pal.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !msg.streaming, chat.retryableResponseID == msg.id {
                miniAction("arrow.clockwise", msg.interrupted ? String(localized: "重新生成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "重试回复", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                    chat.retryResponse(model: model)
                    if chat.sending { latestMessageRequest = UUID() }
                }
                .disabled(!chat.canRetry)
                .help("使用原问题和当时的上下文重新获取回复，保留输入草稿。")
                .accessibilityIdentifier("ai-retry-response")
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func toolApprovalCard(_ request: AIToolRequest, responseID: UUID) -> some View {
        AIApprovalCard(request: request, busy: chat.isBusy,
            targetMatches: model.host(request.target.hostID).flatMap(AIExecutionTarget.init) == request.target,
            approve: {
                chat.approveToolRequest(model: model, responseID: responseID, requestID: request.id, version: request.version)
                latestMessageRequest = UUID()
            }, reject: { chat.rejectToolRequest(model: model, responseID: responseID) },
            revise: { chat.reviseToolRequest(responseID: responseID, command: $0) })
            .id(request.id)
    }

    private func miniAction(
        _ symbol: String, _ title: String, accent: Color = Pal.mauve, action: @escaping () -> Void
    ) -> some View {
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
        let status = executionStatus(msg)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if msg.executionState == .waiting || msg.executionState == .connecting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(status.color)
                }
                PanelBadgeView(text: status.title, color: status.color)
            }
            if let target = msg.terminalTitle {
                Label(target, systemImage: "terminal")
                    .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !msg.execCommand.isEmpty {
                Text(msg.execCommand)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(status.detail)
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
            if !msg.executionDetail.isEmpty {
                Text(msg.executionDetail).font(.system(size: 10)).foregroundStyle(Pal.yellow)
                    .textSelection(.enabled)
            }
            if !msg.stdout.isEmpty { outputSection("标准输出", text: msg.stdout, color: Pal.subtext) }
            if !msg.stderr.isEmpty { outputSection("错误输出", text: msg.stderr, color: Pal.yellow) }
            if msg.outputTruncated {
                Text("显示内容已达到上限；仍在接收并丢弃超出部分，避免远端阻塞。")
                    .font(.system(size: 10)).foregroundStyle(Pal.yellow)
            }
            if msg.executionState == .completed, msg.stdout.isEmpty, msg.stderr.isEmpty {
                Text("命令没有输出。").font(.system(size: 11)).foregroundStyle(Pal.subtext)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func outputSection(_ title: LocalizedStringKey, text: String, color: Color) -> some View {
        DisclosureGroup(title) {
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.frame(maxHeight: 180)
        }.font(.system(size: 11)).foregroundStyle(color)
    }

    private func executionStatus(_ msg: AIMessage) -> (title: String, detail: String, color: Color) {
        switch msg.executionState {
        case .connecting:
            return (String(localized: "正在连接", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "准备独立 SSH 通道，命令尚未发送。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.mauve)
        case .waiting:
            return (String(localized: "执行中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "收起面板或关闭终端，任务仍会继续。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.mauve)
        case .completed:
            let code = msg.exitCode ?? -1
            return (String(localized: "已结束 · 退出码 \(code)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "已收到远端退出状态，输出将交给 AI 分析。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), code == 0 ? Pal.green : Pal.red)
        case .unknown:
            return (String(localized: "结果未确认", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "连接结束但未确认退出状态；不会自动重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.yellow)
        case .timedOut:
            return (String(localized: "执行超时", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "已关闭本次通道；远端副作用可能已经发生，不会自动重试。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.yellow)
        case .stopped:
            return (String(localized: "已请求停止", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "仅取消本次操作，已发生的远端改动不会撤销。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.overlay)
        case .failed:
            return (String(localized: "未执行", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "连接或执行前校验失败，需要重新申请命令。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), Pal.red)
        case nil:
            return (String(localized: "主机命令", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), "", Pal.overlay)
        }
    }

    // MARK: 输入区

    private var inputBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Pal.border).frame(height: 1)
            resizeHandle
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if chat.input.isEmpty {
                        Text("描述任务或提问…")
                            .font(.system(size: 12)).foregroundStyle(Pal.overlay)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    AIInputField(
                        text: $chat.input,
                        height: Binding(
                            get: { inputHeight },
                            set: { if manualInputHeight == nil { inputHeight = $0 } }
                        )
                    ) { sendMessage() }
                    .frame(height: effectiveInputHeight)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                }
                HStack(spacing: 8) {
                    Text(chat.phase == .waitingForCommand ? String(localized: "命令执行中…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        : (chat.compactingContext ? String(localized: "正在整理历史上下文…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                           : chat.sending ? String(localized: "AI 正在回复…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "↵ 发送 · ⇧↵ 换行", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)))
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    Spacer(minLength: 0)
                    if chat.compactedContextCount > 0 {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                            .help("较早对话已整理为摘要，完整聊天记录仍保留在上方。")
                            .accessibilityLabel("历史上下文已整理")
                    }
                    if chat.isBusy {
                        iconBarButton(
                            "stop.fill", active: true, tint: Pal.red,
                            help: chat.phase == .waitingForCommand
                                ? String(localized: "停止本次命令", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "停止回复", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        ) { chat.cancel() }
                    } else {
                        iconBarButton(
                            "arrow.up", active: chat.canSend, tint: Pal.mauve,
                            help: String(localized: "发送", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
                        ) { sendMessage() }
                        .disabled(!chat.canSend)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(Pal.crust)
        .animation(nil, value: effectiveInputHeight)
    }

    /// 输入区顶部的上下拖动手柄：拉高/压低输入框（34~260pt）；双击恢复内容自适应。
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 9)
            .overlay {
                RoundedRectangle(cornerRadius: 1.5).fill(Pal.overlay.opacity(0.45))
                    .frame(width: 36, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragBaseHeight == nil { dragBaseHeight = effectiveInputHeight }
                        if let base = dragBaseHeight {
                            manualInputHeight = min(max(base - v.translation.height, 34), 260)
                        }
                    }
                    .onEnded { _ in dragBaseHeight = nil }
            )
            .onTapGesture(count: 2) { manualInputHeight = nil }
            .help(String(localized: "拖动调整输入区高度（双击恢复自动）", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
    }

    /// 输入区统一规格的图标按钮（30x30）：active 时高亮主色。
    private func iconBarButton(
        _ symbol: String, active: Bool, tint: Color = Pal.mauve,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(active ? tint : Pal.overlay)
                .frame(width: 30, height: 30)
                .background(
                    active ? tint.opacity(0.14) : Pal.fill(0.05),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor().help(help).accessibilityLabel(help)
    }

    // MARK: 动作

    private func contextLabel(_ attachment: AIMessage.ContextAttachment) -> String {
        switch attachment {
        case .terminalOutput: String(localized: "已附带终端输出", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .hostInfo: String(localized: "已附带主机信息 · 暂无终端输出", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .none: String(localized: "未附带终端上下文", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }

    private func sendMessage() {
        let count = chat.messages.count
        chat.send(model: model)
        if chat.messages.count > count { latestMessageRequest = UUID() }
    }

}

/// 复制反馈属于按钮自身，切换会话或移除消息会取消反馈计时。
struct AICopyButton: View {
    let text: String
    var title: LocalizedStringKey = "复制"
    @State private var copied: Bool?
    @State private var feedbackID: UUID?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
            feedbackID = UUID()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied == true ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                if let copied {
                    Text(copied ? String(localized: "已复制", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "复制失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)).font(.system(size: 11))
                } else {
                    Text(title).font(.system(size: 11))
                }
            }
            .foregroundStyle(copied == false ? Pal.red : Pal.mauve)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityIdentifier("ai-copy-content")
        .task(id: feedbackID) {
            guard feedbackID != nil else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
            copied = nil
            feedbackID = nil
        }
    }
}

/// 跟随意图与内容高度分开记录：内容增长不能被误判成用户向上滚动。
/// macOS 14 使用几何偏好读取可见距离，不依赖 macOS 15 的 scroll geometry API。
private struct AIMessageList<Row: View>: View {
    let messages: [AIMessage]
    let latestRequest: UUID
    @ViewBuilder let row: (AIMessage) -> Row
    @Namespace private var coordinateSpace
    @State private var followingLatest = true
    @State private var lastFrame: CGRect?
    private let bottomID = "ai-message-bottom"
    private let followingDistance: CGFloat = 72

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // 回复高度持续变化，需要真实内容高度，避免惰性估算将底部位置来回推移。
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(messages) { message in row(message).id(message.id) }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(9)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: AIMessageFrameKey.self,
                                value: content.frame(in: .named(coordinateSpace)))
                        }
                    }
                }
                .coordinateSpace(name: coordinateSpace)
                .onPreferenceChange(AIMessageFrameKey.self) { frame in
                    guard let frame else { return }
                    let previous = lastFrame
                    lastFrame = frame
                    let heightChanged = previous.map { abs($0.height - frame.height) > 0.5 } ?? true
                    let positionChanged = previous.map { abs($0.minY - frame.minY) > 0.5 } ?? false
                    let nearBottom = frame.maxY - viewport.size.height <= followingDistance
                    if let previous, positionChanged {
                        if followingLatest {
                            // 向下的程序化定位不能被当成用户离开底部。
                            if !heightChanged, frame.minY > previous.minY, !nearBottom {
                                followingLatest = false
                            }
                        } else if nearBottom {
                            followingLatest = true
                        }
                    }
                    if followingLatest, heightChanged { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: latestRequest) {
                    followingLatest = true
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
                .onChange(of: viewport.size.height) {
                    if followingLatest { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .overlay(alignment: .bottom) {
                    if !followingLatest {
                        Button {
                            followingLatest = true
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .foregroundStyle(Pal.text)
                                .background(Pal.surface0, in: Capsule())
                                .overlay(Capsule().strokeBorder(Pal.border))
                                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                        }
                        .buttonStyle(.plain).padding(.bottom, 10)
                        .accessibilityIdentifier("ai-return-to-latest")
                    }
                }
            }
        }
    }
}

private struct AIMessageFrameKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
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
        if tv.string != text, !tv.hasMarkedText() {
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
            guard !textView.hasMarkedText() else { return false }
            let shift = NSEvent.modifierFlags.contains(.shift)
            guard !shift else { return false }   // 交给系统插入换行
            onSubmit()
            return true
        }
    }
}

/// Independent state boundary: editing a proposal never mutates an approved action.
private struct AIApprovalCard: View {
    let request: AIToolRequest
    let busy: Bool
    let targetMatches: Bool
    let approve: () -> Void
    let reject: () -> Void
    let revise: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let expired = timeline.date >= request.expiresAt || !targetMatches
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("执行申请", systemImage: "checkmark.shield")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Spacer(minLength: 2)
                    Text(request.decision == .pending
                         ? (expired ? String(localized: "已失效", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "等待你确认", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                         : decisionTitle)
                        .font(.system(size: 10)).foregroundStyle(Pal.mauve)
                }
                Text(request.purpose).font(.system(size: 12)).foregroundStyle(Pal.text)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Label(request.target.title, systemImage: "server.rack")
                    Text(request.target.destination).font(.system(size: 10, design: .monospaced))
                    Text("目录：\(request.target.cwd) · 超时 \(request.timeout) 秒")
                    Text("独立 Shell · 不继承终端环境")
                }
                .font(.system(size: 10)).foregroundStyle(Pal.subtext).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                if editing {
                    TextEditor(text: $draft).font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 90, maxHeight: 160).scrollContentBackground(.hidden)
                        .padding(6).background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("取消修改") { editing = false }
                        Spacer(minLength: 0)
                        Button("更新申请") { revise(draft); editing = false }
                            .disabled(!AIToolRequest.valid(draft) || busy)
                    }.font(.system(size: 11))
                    Text("更新后需要再次确认，原申请将失效。")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                } else {
                    Text(request.command).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Pal.textBright).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(Pal.crust, in: RoundedRectangle(cornerRadius: 6))
                    if request.decision == .pending {
                        if AICommandProposal(request.command).risk == .dangerous {
                            Label("可能产生不可逆改动，请核对完整命令。", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(Pal.red)
                        }
                        HStack(spacing: 8) {
                            Button("拒绝", action: reject)
                            Button("修改") { draft = request.command; editing = true }
                            Spacer(minLength: 0)
                            Button("执行一次", action: approve).buttonStyle(.borderedProminent).tint(Pal.mauve)
                                .disabled(expired)
                                .accessibilityIdentifier("ai-approve-tool-call")
                        }.font(.system(size: 11)).disabled(busy)
                        if expired {
                            Text("请求过期或主机配置已变更，请让助手重新提出命令。")
                                .font(.system(size: 10)).foregroundStyle(Pal.yellow)
                        }
                    }
                }
            }
            .padding(10)
            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.mauve.opacity(0.25)))
        }
    }

    private var decisionTitle: String {
        switch request.decision {
        case .pending: String(localized: "等待你确认", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .approved: String(localized: "已批准一次", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .rejected: String(localized: "已拒绝", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .expired: String(localized: "已失效", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}
