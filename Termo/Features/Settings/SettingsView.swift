import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var appLock = AppLockManager.shared
    @State private var showPinSetup = false
    @State private var idleMinutes = 5
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var showLanguageRestart = false
    @State private var aiDraft: AISettingsDraft?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Pal.fill(0.06))
            content
        }
        .frame(width: 800, height: 600)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .modifier(SyncDialogs(model: model))
        // 密钥面板的弹层必须挂在这里（设置弹窗内部）：挂在根视图 AppSheets 上时
        // 会被已展示的设置 sheet 挡住——点「生成」永远弹不出来（sheet-over-sheet
        // 只允许挂在已展示 sheet 的内容层级里）。
        .sheet(isPresented: $model.showGenerateKey) { GenerateKeyView(model: model) }
        .sheet(item: $model.detailKey) { key in KeyDetailView(model: model, key: key) }
        .alert("操作失败", isPresented: Binding(
            get: { model.keyOpError != nil },
            set: { if !$0 { model.keyOpError = nil } }
        )) {
            Button("好", role: .cancel) { model.keyOpError = nil }
        } message: {
            Text(model.keyOpError ?? "")
        }
        .onChange(of: settings.appLanguage) { showLanguageRestart = true }
        .overlay {
            if showLanguageRestart {
                ConfirmDialog(
                    title: "重启以应用语言",
                    message: "语言更改需重启 Termo 后生效。",
                    confirmTitle: "立即重启",
                    cancelTitle: "稍后",
                    onConfirm: { showLanguageRestart = false; Self.relaunch() },
                    onCancel: { showLanguageRestart = false })
            }
        }
    }

    /// 干净重启：先关所有模态 sheet（SwiftUI 的 .sheet 会拦截 NSApp.terminate，不先关就会
    /// 「新实例已起、旧实例退不掉」双开），留一拍让其关闭，再启动新实例并退出旧进程。
    static func relaunch() {
        AppModel.shared.dismissAllSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: - 左侧导航

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("设置").font(.system(size: 19, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text("让 Termo 适合你的工作方式")
                    .font(.system(size: 10)).foregroundStyle(Pal.subtext)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    navigationGroup("偏好", tabs: [.general, .terminal, .keys])
                    navigationGroup("工作空间", tabs: [.ai, .transfer, .monitor])
                    navigationGroup("数据与安全", tabs: [.sshKeys, .security, .sync])
                    navItem(.about)
                }
                .padding(.horizontal, 10).padding(.bottom, 16)
            }
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Pal.solidMantle)
    }

    private func navigationGroup(_ title: LocalizedStringKey, tabs: [SettingsTab]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
                .padding(.leading, 10).padding(.bottom, 3)
            ForEach(tabs, id: \.self) { navItem($0) }
        }
    }

    private func navItem(_ tab: SettingsTab) -> some View {
        let selected = model.settingsTab == tab
        return Button {
            model.settingsTab = tab
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                    .frame(width: 18)
                Text(tab.label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Pal.text : Pal.subtext)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(
                selected ? Pal.mauve.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - 右侧内容

    private var content: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.settingsTab.label)
                        .font(.system(size: 21, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(pageDescription)
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    model.showSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Pal.overlay)
                        .frame(width: 26, height: 26)
                        .background(Pal.fill(0.05), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("关闭设置").accessibilityLabel("关闭设置")
            }
            .padding(24)
            Divider().overlay(Pal.border)

            if model.settingsTab == .sync {
                SyncPanel(model: model)
                    .padding(.horizontal, 8)
            } else if model.settingsTab == .ai {
                if let aiDraft {
                    AISettingsContent(draft: aiDraft)
                } else {
                    ProgressView().onAppear { aiDraft = AISettingsDraft() }
                }
            } else if model.settingsTab == .sshKeys {
                KeysPanel(model: model).padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        switch model.settingsTab {
                        case .general: generalSettings
                        case .ai, .sync, .sshKeys: EmptyView()
                        case .terminal: terminalSettings
                        case .transfer: transferSettings
                        case .monitor: monitorSettings
                        case .security: securitySettings
                        case .keys: keysSettings
                        case .about: aboutSettings
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(model.settingsTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Pal.solidBase)
    }

    private var pageDescription: String {
        switch model.settingsTab {
        case .general: return String(localized: "外观、语言与窗口行为，更改后自动保存。")
        case .terminal: return String(localized: "调整终端显示和交互，更改后自动保存。")
        case .transfer: return String(localized: "管理文件保存位置与后台传输，更改后自动保存。")
        case .monitor: return String(localized: "关注主机资源的变化，更改后自动保存。")
        case .security: return String(localized: "保护应用访问，并管理备份加密使用的主密码。")
        case .ai: return String(localized: "连接模型服务，配置完成后保存。")
        case .sshKeys: return String(localized: "集中管理连接主机使用的 SSH 密钥。")
        case .sync: return String(localized: "通过 WebDAV 在设备间同步加密备份。")
        case .keys: return String(localized: "常用操作的键盘快捷键。")
        case .about: return String(localized: "版本信息、项目与隐私。")
        }
    }

    // MARK: - 通用

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(String(localized: "外观模式"), description: String(localized: "切换深色、浅色或跟随系统")) {
                SegmentedControl(
                    options: AppearanceMode.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $theme.mode
                )
                .frame(width: 240)
            }

            settingRow(String(localized: "语言"), description: String(localized: "界面语言，更改后需重启 Termo 生效")) {
                ThemedDropdown(
                    options: AppLanguage.allCases.map { (value: $0, verbatim: $0.label) },
                    selection: $settings.appLanguage
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "启动行为"), description: String(localized: "选择打开应用时显示的内容")) {
                ThemedDropdown(
                    options: [(StartupBehavior.welcome, String(localized: "显示欢迎页")), (.terminal, String(localized: "打开新终端"))],
                    selection: $settings.startupBehavior
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "关闭窗口时隐藏到菜单栏"), description: String(localized: "关闭主窗口不退出，后台任务（如端口转发）继续运行；从菜单栏图标恢复"), inlineControl: true) {
                ThemedToggle(isOn: $settings.closeToTray)
            }

            settingRow(String(localized: "删除主机前确认"), description: String(localized: "删除主机时弹出确认弹窗，避免误删"), inlineControl: true) {
                ThemedToggle(isOn: $settings.confirmHostDelete)
            }

        }
    }

    // MARK: - 传输

    private var transferSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(String(localized: "下载时询问位置"), description: String(localized: "每次下载都弹出选择保存位置"), inlineControl: true) {
                ThemedToggle(isOn: $settings.downloadAskEachTime)
            }

            if !settings.downloadAskEachTime {
                settingRow(String(localized: "默认下载目录"), description: String(localized: "下载的文件保存到此处")) {
                    HStack(spacing: 8) {
                        Text(settings.resolvedDownloadDir.path)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(settings.resolvedDownloadDir.path)
                        SecondaryButton(title: "选择…", action: chooseDownloadDir)
                    }
                }
            }

            settingRow(String(localized: "下载时显示弹窗"), description: String(localized: "关闭后，在后台任务中查看传输进度"), inlineControl: true) {
                ThemedToggle(isOn: $settings.showDownloadDialog)
            }

            settingRow(String(localized: "并发传输数"), description: String(localized: "同时进行的上传/下载数量（共用一个池），超出自动排队")) {
                ThemedDropdown(
                    options: [(1, String(localized: "1 个")), (2, String(localized: "2 个")), (3, String(localized: "3 个")), (4, String(localized: "4 个")), (5, String(localized: "5 个"))],
                    selection: $settings.maxConcurrentTransfers
                )
                .frame(width: 120)
            }

            settingRow(String(localized: "暂停时让出名额"), description: String(localized: "暂停传输时允许队列中的其他任务开始"), inlineControl: true) {
                ThemedToggle(isOn: $settings.pausedReleasesSlot)
            }
        }
    }

    // MARK: - 监控

    private var monitorSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(String(localized: "资源告警"), description: String(localized: "主机 CPU、内存或磁盘持续高占用时发送系统通知"), inlineControl: true) {
                ThemedToggle(isOn: $settings.resourceAlerts)
            }
        }
    }

    // MARK: - 安全

    private var securitySettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(String(localized: "启动时锁定 App"), description: String(localized: "启动 Termo 时先显示锁定屏，用 Touch ID 或主密码解锁进入"), inlineControl: true) {
                ThemedToggle(isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { on in
                        if on && !appLock.hasPin { showPinSetup = true }
                        else { appLock.setEnabled(on) }
                    }
                ))
            }

            settingRow(String(localized: "主密码"), description: String(localized: "文字、数字和符号均可；应用解锁与 WebDAV 备份加密共用")) {
                Button { showPinSetup = true } label: {
                    Text(appLock.hasPin ? String(localized: "修改") : String(localized: "设置"))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Pal.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }

            settingRow(String(localized: "自动锁定"), description: String(localized: "无操作达到该时长后自动锁定，需 Touch ID 或主密码解锁")) {
                ThemedDropdown(
                    options: [1, 5, 15, 30].map { ($0, String(localized: "\($0) 分钟")) },
                    selection: $idleMinutes
                )
                .frame(width: 150)
                .disabled(!appLock.hasPin)
                .onChange(of: idleMinutes) { _, value in appLock.idleMinutes = value }
            }

            Text(String(localized: "快捷键 ⌘L 可随时手动锁定；Touch ID 在锁定屏自动弹出，失败或取消后可点「使用 Touch ID 解锁」重试。"))
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showPinSetup) { AppLockSetupSheet() }
        .onAppear { idleMinutes = appLock.idleMinutes }
    }

    private func chooseDownloadDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择")
        panel.directoryURL = settings.resolvedDownloadDir
        if panel.runModal() == .OK, let url = panel.url { settings.downloadDir = url.path }
    }

    // MARK: - 终端

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingRow(String(localized: "本地 Shell"), description: String(localized: "新建本地终端时使用的 Shell 程序")) {
                ThemedDropdown(
                    options: [(DefaultShell.auto, String(localized: "自动检测")), (.zsh, "/bin/zsh"), (.bash, "/bin/bash")],
                    selection: $settings.defaultShell
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "关闭确认"), description: String(localized: "关闭有活跃进程的终端时提示确认"), inlineControl: true) {
                ThemedToggle(isOn: $settings.closeConfirm)
            }

            settingRow(String(localized: "代码片段运行方式"), description: String(localized: "选择插入命令、直接运行，或每次使用时询问")) {
                ThemedDropdown(
                    options: SnippetAction.allCases.map { ($0, $0.label) },
                    selection: $settings.snippetAction
                )
                .frame(width: 160)
            }

            settingRow(String(localized: "字体"), description: String(localized: "终端显示使用的字体")) {
                ThemedDropdown(
                    options: [
                        ("", String(localized: "自动 (推荐)")),
                        ("SF Mono", "SF Mono"), ("Menlo", "Menlo"), ("Monaco", "Monaco"),
                        ("JetBrainsMono Nerd Font", "JetBrains Mono"),
                        ("FiraCode Nerd Font", "Fira Code"),
                        ("MesloLGM Nerd Font", "Meslo LGM"),
                    ],
                    selection: $settings.termFont
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "字号"), description: String(localized: "终端字体大小")) {
                ThemedStepper(value: $settings.termFontSize, range: 10...24, suffix: " pt")
            }

            settingRow(String(localized: "光标样式"), description: String(localized: "终端光标的形状")) {
                SegmentedControl(
                    options: [(value: "block", label: "方块"), (value: "bar", label: "竖线"), (value: "underline", label: "下划线")],
                    selection: $settings.termCursorStyle
                )
                .frame(width: 220)
            }

            settingRow(String(localized: "光标闪烁"), description: String(localized: "光标是否闪烁"), inlineControl: true) {
                ThemedToggle(isOn: $settings.termCursorBlink)
            }

            settingRow(String(localized: "滚动缓冲区"), description: String(localized: "终端保留的最大行数")) {
                ThemedDropdown(
                    options: [(500, String(localized: "500 行")), (1000, String(localized: "1,000 行")), (5000, String(localized: "5,000 行")), (10000, String(localized: "10,000 行")), (50000, String(localized: "50,000 行"))],
                    selection: $settings.termScrollback
                )
                .frame(width: 140)
            }
        }
    }

    // MARK: - 快捷键

    private var keysSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            shortcutRow(String(localized: "新建终端"), shortcut: "⌘ T")
            shortcutRow(String(localized: "关闭标签"), shortcut: "⌘ W")
            shortcutRow(String(localized: "复制"), shortcut: "⌘ C")
            shortcutRow(String(localized: "粘贴"), shortcut: "⌘ V")
            shortcutRow(String(localized: "锁定应用"), shortcut: "⌘ L")
            shortcutRow(String(localized: "清屏"), shortcut: "⌘ K")
            shortcutRow(String(localized: "搜索"), shortcut: "⌘ F")
            shortcutRow(String(localized: "切换侧栏"), shortcut: "⌘ B")
            shortcutRow(String(localized: "下一个标签"), shortcut: "⌃ Tab")
            shortcutRow(String(localized: "上一个标签"), shortcut: "⌃ ⇧ Tab")
            shortcutRow(String(localized: "放大字体"), shortcut: "⌘ +")
            shortcutRow(String(localized: "缩小字体"), shortcut: "⌘ -")
        }
    }

    // MARK: - 关于

    private var aboutSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            AboutContent()   // 与独立「关于」窗口复用同一份内容
        }
    }

    // MARK: - 组件

    private func settingRow<C: View>(_ title: String, description: String,
                                      inlineControl: Bool = false,
                                      @ViewBuilder control: () -> C) -> some View {
        let layout = inlineControl
            ? AnyLayout(HStackLayout(alignment: .center, spacing: 18))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                Text(description).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().accessibilityLabel(title)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.border, lineWidth: 1))
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action).font(.system(size: 13)).foregroundStyle(Pal.text)
            Spacer()
            Text(shortcut)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Pal.subtext)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 2)
    }
}
