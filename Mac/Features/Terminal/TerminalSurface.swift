import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

/// 终端拖放区：外部文件拖入 → 上传到该终端的当前目录（OSC7 跟踪的 cwd）。
/// 拖拽悬停时叠加蓝色边框、透明填充的反馈层（仅 SSH 终端可上传；本地终端不接管拖放）。
struct TerminalDropArea: View {
    let terminal: LocalProcessTerminalView
    let isActive: Bool
    let model: AppModel
    let tabId: Int
    let canUpload: Bool
    @State private var targeted = false

    private static let dropBlue = Color(hex: 0x1E90FF)

    var body: some View {
        TerminalSurface(terminal: terminal, isActive: isActive)
            .overlay { if targeted { dropOverlay } }
            .animation(.easeOut(duration: 0.12), value: targeted)
            .onDrop(of: [.fileURL], isTargeted: canUpload ? $targeted : nil) { providers in
                guard canUpload else { return false }
                loadURLs(providers) { urls in
                    if !urls.isEmpty { model.uploadDroppedFiles(urls, toTabId: tabId) }
                }
                return true
            }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Self.dropBlue.opacity(0.07))   // 内容透明、终端可见
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.dropBlue, lineWidth: 2))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .medium))
                    Text("松开以上传到当前目录").font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Self.dropBlue)
                .padding(.horizontal, 18).padding(.vertical, 14)
                .background(Pal.solidMantle.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func loadURLs(_ providers: [NSItemProvider], _ completion: @escaping ([URL]) -> Void) {
        var urls = Array<URL?>(repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url, url.isFileURL { urls[index] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(urls.compactMap { $0 }) }
    }
}

struct TerminalSurface: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    var isActive: Bool = true     // tab 是否为当前活动 tab（keep-alive 下所有终端常驻，靠这个区分）
    @Environment(\.locale) private var locale

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        terminal.menu = Self.buildContextMenu(localeIdentifier: locale.identifier)
        terminal.isHidden = !isActive
        // 只让活动终端首次创建时抢焦点；非活动的不抢（keep-alive 下会同时创建多个，避免互相抢）。
        if isActive {
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 非活动终端 isHidden=true：AppKit 跳过其 draw（比 opacity=0 省），避免 N 个高吞吐后台终端
        // 叠加离屏重绘的 CPU；进程/PTY 照常运行、输出继续进 SwiftTerm 缓冲。隐藏视图也会自动放弃 first
        // responder（焦点安全）。切到终端的聚焦由 AppModel.focusActiveTab 显式处理 —— 不在此 makeFirstResponder：
        // updateNSView 会随主题/设置/hover 任意重绘频繁触发，在此抢焦点会把键盘从侧栏搜索框抢回终端。
        if nsView.isHidden == isActive { nsView.isHidden = !isActive }
        let menuIdentifier = NSUserInterfaceItemIdentifier("TermoTerminalMenu.\(locale.identifier)")
        if nsView.menu?.identifier != menuIdentifier {
            nsView.menu = Self.buildContextMenu(localeIdentifier: locale.identifier)
        }
    }

    private static func buildContextMenu(localeIdentifier: String) -> NSMenu {
        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("TermoTerminalMenu.\(localeIdentifier)")

        let copy = NSMenuItem(title: String(localized: "复制", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copy.keyEquivalentModifierMask = .command
        menu.addItem(copy)

        let paste = NSMenuItem(title: String(localized: "粘贴", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.keyEquivalentModifierMask = .command
        menu.addItem(paste)

        let selectAll = NSMenuItem(title: String(localized: "全选", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.keyEquivalentModifierMask = .command
        menu.addItem(selectAll)

        menu.addItem(.separator())

        let clear = NSMenuItem(title: String(localized: "清屏", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: #selector(TerminalActions.clearTerminal(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = .command
        menu.addItem(clear)

        menu.addItem(.separator())

        // 会话操作：复制会话（同主机新终端，走共享连接不重新登录；本地终端点了无效）/ 重命名标签。
        // 不设快捷键——⌘D 等在终端里有自身语义（EOF），不能占用。
        menu.addItem(NSMenuItem(title: String(localized: "复制会话", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                                action: #selector(TerminalActions.duplicateSession(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "重命名标签", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                                action: #selector(TerminalActions.renameSessionTab(_:)), keyEquivalent: ""))

        menu.addItem(.separator())

        let search = NSMenuItem(title: String(localized: "搜索", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        search.keyEquivalentModifierMask = .command
        search.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        menu.addItem(search)

        return menu
    }
}

/// 单个 SSH 终端标签的连接态：用于断线时保留标签并展示重连覆盖层。本地终端不创建。
@MainActor
final class TerminalConn: ObservableObject {
    enum Phase { case live, dropped }
    enum ReconnectStatus { case waitingForNetwork, scheduled, connecting }
    @Published var phase: Phase = .live
    @Published var reconnectStatus: ReconnectStatus = .scheduled
    var attempt = 0    // 连续重连失败的退避代数，连上后清零
}

/// 终端断线覆盖层：连接断开时盖在终端之上，显示重连状态与「立即重连」入口；连接正常时不渲染。
struct TerminalReconnectOverlay: View {
    @ObservedObject var conn: TerminalConn
    let onReconnect: () -> Void

    var body: some View {
        if conn.phase == .dropped {
            ZStack {
                Pal.base.opacity(0.55)
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(Pal.yellow)
                    Text("连接已断开").font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    HStack(spacing: 7) {
                        if conn.reconnectStatus == .connecting { ProgressView().controlSize(.small) }
                        Text(reconnectDescription).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                    Button(action: onReconnect) {
                        Text("立即重连").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .disabled(conn.reconnectStatus != .scheduled)
                    .opacity(conn.reconnectStatus == .scheduled ? 1 : 0.45)
                }
                .padding(24)
                .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            }
            .transition(.opacity)
        }
    }

    private var reconnectDescription: String {
        switch conn.reconnectStatus {
        case .waitingForNetwork: return String(localized: "等待网络恢复后重连", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .scheduled: return String(localized: "即将自动重连", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        case .connecting: return String(localized: "正在重连…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        }
    }
}

/// 监听终端的 OSC 7「当前目录变更」，把远端 cwd 回传给 AppModel（用于文件传输和终端上下文）。
final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onCwd: ((String) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onTerminated?(exitCode) }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let p = Self.parsePath(directory) else { return }
        onCwd?(p)
    }

    /// 把 OSC 7 的 `file://host/path` 解析为绝对路径。
    static func parsePath(_ dir: String?) -> String? {
        guard let dir else { return nil }
        if dir.hasPrefix("file://") {
            let after = dir.dropFirst("file://".count)   // "host/path" 或 "/path"
            if let slash = after.firstIndex(of: "/") { return String(after[slash...]) }
            return nil
        }
        return dir.hasPrefix("/") ? dir : nil
    }
}

@objc protocol TerminalActions {
    func clearTerminal(_ sender: Any?)
    func duplicateSession(_ sender: Any?)
    func renameSessionTab(_ sender: Any?)
}

extension LocalProcessTerminalView: TerminalActions {
    func clearTerminal(_ sender: Any?) {
        let terminal = getTerminal()
        terminal.feed(text: "\u{0C}")
        terminal.resetToInitialState()
    }

    /// 右键「复制会话」：按视图找回标签，同主机再开一个终端（经共享连接，不重新登录）。
    func duplicateSession(_ sender: Any?) {
        DispatchQueue.main.async { AppModel.shared.duplicateSession(terminalView: self) }
    }

    /// 右键「重命名标签」：等同标签右键菜单的重命名（弹输入框）。
    func renameSessionTab(_ sender: Any?) {
        DispatchQueue.main.async { AppModel.shared.requestRenameTab(terminalView: self) }
    }
}

/// User pastes are paced and serialized; queued bytes stay bound to the connection that received the paste.
final class PacedTerminalView: LocalProcessTerminalView {
    private let pasteQueue = TerminalPasteQueue()
    private var scrollerHideWorkItem: DispatchWorkItem?
    private var scrollEventMonitor: Any?
    private var scrollerGeneration = 0

    private var terminalScroller: NSScroller? {
        subviews.compactMap { $0 as? NSScroller }.first
    }

    /// SwiftTerm currently creates a legacy scroller. Keep its functional thumb, but present it like
    /// the rest of the app: overlay while the user scrolls, then fade it out after a short idle period.
    func configureTransientScroller() {
        configureTransientScroller(retriesRemaining: 2)
    }

    private func configureTransientScroller(retriesRemaining: Int) {
        guard let scroller = terminalScroller else {
            guard retriesRemaining > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.configureTransientScroller(retriesRemaining: retriesRemaining - 1)
            }
            return
        }
        scroller.scrollerStyle = .overlay
        scroller.controlSize = .small
        scroller.alphaValue = 0
        scroller.isHidden = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeScrollEventMonitor()
        guard window != nil else { return }
        scrollEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  !self.isHidden,
                  event.window === self.window,
                  event.deltaY != 0 || event.scrollingDeltaY != 0 else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            // The monitor runs before SwiftTerm updates its scroll view. Reveal on the next main-loop
            // turn so the thumb uses the new position while leaving the event untouched.
            DispatchQueue.main.async { [weak self] in self?.showTransientScroller() }
            return event
        }
    }

    private func showTransientScroller() {
        guard let scroller = terminalScroller, scroller.isEnabled else { return }
        scrollerHideWorkItem?.cancel()
        scrollerGeneration += 1
        let generation = scrollerGeneration
        scroller.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            scroller.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self, weak scroller] in
            guard let self, let scroller, self.scrollerGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                scroller.animator().alphaValue = 0
            }, completionHandler: {
                if self.scrollerGeneration == generation { scroller.isHidden = true }
            })
        }
        scrollerHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func removeScrollEventMonitor() {
        guard let scrollEventMonitor else { return }
        NSEvent.removeMonitor(scrollEventMonitor)
        self.scrollEventMonitor = nil
    }

    override func paste(_ sender: Any) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let target = terminalDelegate else { return }
        pasteQueue.enqueue(text, bracketed: getTerminal().bracketedPasteMode) { [weak self, weak target] bytes in
            guard let self, let target, self.terminalDelegate === target else { return false }
            if let driver = target as? SSHTerminalDriver { return driver.sendInput(bytes) }
            target.send(source: self, data: bytes[...])
            return true
        }
    }

    func cancelPendingPaste() { pasteQueue.cancel() }

    deinit {
        scrollerHideWorkItem?.cancel()
        removeScrollEventMonitor()
    }
}
