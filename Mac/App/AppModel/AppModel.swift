import AppKit
import Combine
import SwiftTerm
import SwiftUI
import TermoEngine

@MainActor
final class AppModel: ObservableObject {
    @Published var section: Section = .hosts
    @Published var query: String = ""
    // 脱敏显示:开启后隐藏列表/概览里的 IP 与主机名(搜索框旁的眼睛按钮切换)。会话级,不持久化。
    @Published var privacyMode: Bool = false

    // 标签状态独立成 [[TabsModel]]：TabBar/Workspace 只观察它，不被本对象其它 @Published 牵动重算。
    // 下面两个转发计算属性让 AppModel 内部大量 tabs/activeTabId 引用零改动；视图层改为观察 tabsModel。
    let tabsModel = TabsModel()
    let layoutModel = LayoutModel()  // 布局单例归 AppModel 持有（视图层经 model.layoutModel 观察同一实例）
    var tabs: [TabItem] {
        get { tabsModel.tabs }
        set { tabsModel.tabs = newValue }
    }
    var activeTabId: Int? {
        get { tabsModel.activeTabId }
        set { tabsModel.activeTabId = newValue }
    }
    // 侧栏宽度同样移到独立的 [[LayoutModel]]：拖动改宽度时不再触发本对象的
    // objectWillChange，避免 TabBar/Workspace 等重控件每帧重算（见 LayoutModel 注释）。
    @Published var settingsTab: SettingsTab = .general
    @Published var showSettings = false
    @Published var showAddHost = false
    @Published var editingHost: Host? = nil  // 非 nil 时以编辑模式打开主机表单
    // 密钥库（SSH Keys）
    @Published var sshKeys: [SSHKey] = []
    @Published var showGenerateKey = false  // 显示「生成密钥」弹窗
    @Published var detailKey: SSHKey? = nil  // 非 nil 显示密钥详情弹窗
    @Published var keyOpError: String? = nil  // 密钥操作错误提示（生成/导入失败）
    // 代码片段（Snippets）
    @Published var snippets: [Snippet] = []
    @Published var showCreateSnippet = false  // 显示「新建片段」弹窗
    @Published var editingSnippet: Snippet? = nil  // 非 nil 显示片段编辑/详情弹窗
    @Published var pendingSnippetRun: SnippetRunRequest? = nil  // 非 nil 显示变量填值弹窗
    @Published var pendingSnippetAction: Snippet? = nil  // 非 nil 显示「插入/运行」选择弹窗
    @Published var snippetNotice: String? = nil  // 片段操作提示（如无可用终端）
    @Published var hostSaveError: String? = nil
    @Published var hostCredentialNotice: String? = nil
    var sessionOnlyHostPasswords: Set<String> = []
    lazy var connectionFlow = HostConnectionFlow(
        currentHost: { [weak self] in self?.host($0) },
        isUnlocked: { !AppLockManager.shared.isLocked }
    )
    lazy var hostTrust = HostTrustCoordinator(
        currentHost: { [weak self] in self?.host($0) },
        isUnlocked: { !AppLockManager.shared.isLocked }
    )

    // 文件操作的工作区内嵌编辑状态（始终绑定发起操作的主机与目标）。
    @Published var pendingFileDelete: FileOpContext? = nil
    @Published var pendingFileRename: FileOpContext? = nil
    @Published var pendingFileChmod: ChmodContext? = nil
    @Published var pendingFileCreate: CreateContext? = nil  // 新建文件/文件夹的名称输入弹窗
    @Published var pendingFileInfo: FileInfoContext? = nil
    var fileOperationGeneration = UUID()
    // 上传/下载任务队列：可并发（上限 maxConcurrentTransfers），超出排队。含进行中/排队/已完成（完成后保留待用户清除）。
    let transferPathLocks = TransferPathLocks()
    var transfers: [UploadTask] { transferCoordinator.tasks }
    private(set) lazy var transferCoordinator: TransferCoordinator<UploadTask> = {
        let coordinator = TransferCoordinator<UploadTask>(
            limit: AppSettings.shared.maxConcurrentTransfers,
            pausedReleasesSlot: AppSettings.shared.pausedReleasesSlot)
        coordinator.onChange = { [weak self] in self?.objectWillChange.send() }
        return coordinator
    }()
    // 底部任务详情互斥展示；收起不影响后台任务，文件操作优先占用同一区域。
    @Published var focusedTransferId: UUID? = nil {
        didSet { if focusedTransferId != nil { showExtractDialog = false } }
    }
    // 「下载不弹窗」时的飞入动画事件（一次性，动画结束即清空，不常驻、不占用 CPU/内存）。
    @Published var flyTransfer: FlyEvent? = nil
    // 左下角后台任务按钮的全局中心点（由按钮自身上报）；飞入动画的终点。
    var backgroundButtonCenter: CGPoint = .zero
    // 选中文件行的全局矩形（仅选中行上报，按远端路径索引）；飞入动画起点取此处，未命中则回退鼠标位置。
    var fileRowGlobalFrames: [String: CGRect] = [:]
    @Published var extractTask: ExtractTask? = nil  // 当前解压任务（nil=无）
    @Published var showExtractDialog = false {
        didSet { if showExtractDialog { focusedTransferId = nil } }
    }
    @Published var fileDeleteBusy = false  // 删除进行中：弹窗保留 + 删除键旁转圈，可中途取消
    var deleteHandle: CommandHandle?  // 取消正在进行的删除（终止远端 rm）
    @Published var pendingBatchDelete: BatchDeleteContext? = nil  // 批量删除确认弹窗
    @Published var batchDeleteBusy = false  // 批量删除进行中：弹窗保留 + 转圈
    @Published var pendingHostDelete: Host? = nil  // 删除主机确认弹窗

    @Published var hosts: [Host] = []
    /// 主机会话历史（终端/上传/端口转发），用于「最近会话」。
    @Published var sessions: [SessionEvent] = []
    /// 全部端口转发规则（持久化）；运行态由 [[ForwardManager]] 单独维护。
    @Published var forwards: [ForwardRule] = []
    /// 非 nil 时展示该主机的端口转发管理面板。
    /// 为真时展示「仍有后台任务」的自定义退出确认弹窗。
    @Published var pendingQuitConfirm = false
    // 退出确认弹窗是否为「彻底退出」模式（托盘「退出 Termo」触发）：确认即停任务退出，不受「隐藏到菜单栏」影响。
    @Published var pendingQuitForce = false
    /// 正在 SSH 探测系统信息的主机 id。
    @Published var probingHosts: Set<String> = []

    // MARK: - Domain state
    // ---------- 实时监控 ----------
    lazy var monitoring = HostMonitoringService(
        makeMonitor: HostMonitor.init,
        alertsEnabled: AppSettings.shared.resourceAlerts,
        onAlert: { [weak self] hostID, alert in
            guard let host = self?.host(hostID) else { return }
            Notifier.notify(
                title: String(localized: "\(host.name) 资源告警", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                body: String(
                    localized:
                        "\(alert.metric.label) \(Int(alert.percent))%，已持续约 \(alert.approximateDuration) 秒"))
        }
    )
    // ---------- 端口转发 ----------
    // 每台主机一份运行态管理器，隧道在后台常驻直到用户停止或退出 App。
    var forwardManagers: [String: ForwardManager] = [:]
    // 把各管理器的状态变化（启停/失败，低频）桥接到本对象，驱动转发 dot 与后台中控刷新。
    // 转发状态变化稀疏，不会像传输逐帧进度那样引发重绘风暴，故可安全转发 objectWillChange。
    var forwardCancellables: [String: AnyCancellable] = [:]
    /// 删除转发规则是否跳过确认：仅本次运行有效（内存态，不持久化）；勾选「不再询问」后本次运行内不再弹窗，
    /// 下次重开 App 仍会提示。故意不放进设置——它是一次性的临时偏好。
    var skipForwardDeleteConfirm = false
    // ---------- 在线状态检测 ----------
    // 探测并发队列/上限定义在文件级（reachQueue / reachLimit），见文件顶部：
    // 二者本身线程安全，置于文件作用域即非 actor 隔离，可在后台 Sendable 闭包里安全使用，且不触发并发告警。
    var statusTimer: Timer?
    var terminals: [Int: LocalProcessTerminalView] = [:]
    var termDrivers: [Int: SSHTerminalDriver] = [:]  // SSH 终端的引擎驱动（按标签）
    var nextTabId = 1
    var themeCancellable: AnyCancellable?

    var lockCancellable: AnyCancellable?
    var settingsCancellable: AnyCancellable?
    var watchdogTimer: Timer?

    /// 全局单例：托盘与退出流程（AppDelegate）需在窗口之外访问后台任务状态，故让其生命周期独立于窗口。
    static let shared = AppModel()

    private init() {
        // 从磁盘加载主机与会话历史
        hosts = HostStore.loadHosts()
        sessions = HostStore.loadSessions()
        forwards = HostStore.loadForwards()
        sshKeys = KeyStore.load()
        snippets = SnippetStore.load()
        HostKeyVerifier.resetSession()  // 清空「仅本次信任」的会话临时 known_hosts
        // 启动即对所有主机做一次轻量在线检测
        defer { refreshAllStatuses() }

        // 用主题配色的视图都已直接 @ObservedObject ThemeManager.shared / AppSettings.shared，
        // 无需再把它们的 objectWillChange 转发到 AppModel（那样会让整棵视图树重复重建）。
        // 这里只订阅副作用：主题/设置变化时刷新各终端的配色与透明度。
        themeCancellable = ThemeManager.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyThemeToTerminals() }
        }
        settingsCancellable = AppSettings.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                self?.applyThemeToTerminals()
                self?.applyTerminalSettings()
                self?.monitoring.setAlertsEnabled(AppSettings.shared.resourceAlerts)
                self?.transferCoordinator.configure(
                    limit: AppSettings.shared.maxConcurrentTransfers,
                    pausedReleasesSlot: AppSettings.shared.pausedReleasesSlot)
            }
        }

        lockCancellable = AppLockManager.shared.$isLocked.sink { [weak self] locked in
            guard locked else { return }
            self?.connectionFlow.cancelAll()
            self?.hostTrust.cancelAll()
        }

        // 网络切换（WiFi 互换、有线无线切换、断网恢复）时立刻重连，不干等 SSH keepalive 超时：
        // 监控即时重连；恢复在线后再重连断开的终端、并重置文件连接使下次操作自动恢复 SFTP。
        NetworkMonitor.shared.onChange = { [weak self] online in
            guard let self else { return }
            SSHSessionPool.shared.closeAll()
            self.monitoring.handleNetworkChange()
            for (_, fm) in self.forwardManagers { fm.handleNetworkChange() }
            if online {
                self.reconnectDroppedTerminals()
                self.reconnectFileViewsAfterNetworkChange()
            } else {
                for (tabId, conn) in self.terminalConns where conn.phase == .dropped {
                    self.terminalReconnectWork[tabId]?.cancel()
                    self.terminalReconnectWork[tabId] = nil
                    conn.reconnectStatus = .waitingForNetwork
                }
            }
        }

        // 定时扫描在线状态/延迟：App 活动时每 30s 一次，失焦暂停（省 CPU/电）
        startStatusTimer()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in
                self?.startStatusTimer(); self?.refreshAllStatuses()
            }
        }
        nc.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.stopStatusTimer() }
        }
        // 退出前停止后台隧道任务并关闭远端监听。
        // 经线程安全的进程登记表清理，nonisolated 可在退出通知的同步回调里直接调用（不依赖 macOS 14 的 assumeIsolated）。
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ForwardProcessRegistry.shared.terminateAll()
            SSHSessionPool.shared.closeAll()
        }

        // 看门狗：每 20s 巡检一次期望保持运行的转发隧道，掉线的补排重启（兜底意外漏掉的退出信号）。
        // 低频且仅在有期望运行隧道时实际动作，开销可忽略；网络抖动的细致处理在 ForwardManager 内。
        let wd = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.forwardWatchdogTick() }
        }
        wd.tolerance = 5
        watchdogTimer = wd
    }

    func forwardWatchdogTick() {
        for (_, fm) in forwardManagers where fm.hasIntended { fm.watchdogTick() }
    }

    // ---------- 退出/后台任务清理 ----------

    /// 当前进行中的后台任务可读清单（用于退出确认弹窗）：运行中的转发、进行中/排队的传输、进行中的解压。
    var runningBackgroundSummaries: [String] {
        var out: [String] = []
        for rule in forwards where forwardManagers[rule.hostId]?.isEnabled(rule.id) == true {
            let host = hosts.first(where: { $0.id == rule.hostId })?.name ?? String(localized: "主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            out.append(String(localized: "端口转发 · \(host) · \(rule.summary)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        for t in transfers where t.phase == .running || t.phase == .queued || t.phase == .paused {
            let verb = t.direction == .upload ? String(localized: "上传", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "下载", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            out.append(String(localized: "\(verb) · \(t.hostName) · \(t.items.count) 项", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        if let e = extractTask, e.phase == .running {
            out.append(String(localized: "解压 · \(e.hostName) · \(e.archive.name)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
        return out
    }

    /// 是否有进行中的后台任务。
    var hasRunningBackground: Bool { !runningBackgroundSummaries.isEmpty }

    /// 退出前停掉所有后台任务：转发隧道、传输、解压。
    func stopAllBackground() {
        for (_, fm) in forwardManagers { fm.stopAll() }
        transferCoordinator.cancelAll()
        focusedTransferId = nil
        extractTask = nil
    }

    var activeHostId: String? {
        guard let id = activeTabId else { return nil }
        return tabs.first(where: { $0.id == id })?.hostId
    }

    /// 主机与命令目标只从同一活动标签解析，禁止从全局唯一终端推测另一台主机。
    var workspaceContext: WorkspaceContext {
        WorkspaceContext(
            tabs: tabs, activeTabId: activeTabId,
            sshHostIds: Set(hosts.filter { $0.ssh != nil }.map(\.id)))
    }

    /// 右侧伴随面板与中间工作区共用当前主机。
    func companionHost() -> Host? {
        host(workspaceContext.hostId)
    }

    func host(_ id: String?) -> Host? {
        guard let id else { return nil }
        return hosts.first(where: { $0.id == id })
    }

    // MARK: - Terminal state
    /// 缓存各终端上报的当前目录，用于文件传输和终端上下文。
    var tabCwd: [Int: String] = [:]
    var termDelegates: [Int: TerminalSessionDelegate] = [:]
    // ---------- 终端断线重连 ----------
    // 仅 SSH 终端：ssh 退出码 255（连接断开）保留标签并自动重连；用户主动 exit 或本地终端按原逻辑关闭。
    var terminalConns: [Int: TerminalConn] = [:]
    var terminalReconnectWork: [Int: DispatchWorkItem] = [:]  // 每标签至多一个挂起的重连，防风暴
    // ---------- 启动行为 ----------
    var didApplyStartup = false
    /// 每终端标签的 exec 命令（tmux 接入等）；nil=常规登录 shell。掉线重连时沿用。
    var terminalCommands: [Int: String] = [:]

    // MARK: - Workspace state
    // ---------- 文件域状态（缓存/重连联动已拆至 FileWorkspaceModel）----------
    let fileWorkspace = FileWorkspaceModel()
    @Published var pendingCloseTabId: Int? = nil
    @Published var pendingTabRename: TabRenameContext? = nil  // 重命名标签输入弹窗
    @Published var pendingMultiClose: MultiCloseContext? = nil  // 批量关闭聚合确认弹窗
}
