import Foundation
import SwiftUI

enum StartupBehavior: String, CaseIterable, Hashable {
    case welcome, terminal

    var label: LocalizedStringKey {
        switch self {
        case .welcome: return "显示欢迎页"
        case .terminal: return "打开新终端"
        }
    }
}

enum DefaultShell: String, CaseIterable, Hashable {
    case auto, zsh, bash
}

/// 代码片段点击运行时的行为：每次询问 / 仅插入命令行 / 直接运行。
enum SnippetAction: String, CaseIterable, Hashable {
    case ask, insert, run
    var label: LocalizedStringKey {
        switch self {
        case .ask: return "每次询问"
        case .insert: return "仅插入命令行"
        case .run: return "直接运行"
        }
    }
}

/// 界面语言：跟随系统 / 简体中文 / English。默认跟随 macOS。
enum AppLanguage: String, CaseIterable, Hashable {
    case system, zh, en
    var label: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    /// App-owned SwiftUI and Foundation strings use the same locale.
    /// System-owned panels continue to follow the macOS language, as expected for AppKit UI.
    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .zh: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }
}

/// 全局应用设置，UserDefaults 持久化。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard
    private static let languageMigrationKey = "appLanguageUsesLocaleEnvironment"

    @Published var startupBehavior: StartupBehavior {
        didSet { d.set(startupBehavior.rawValue, forKey: "startupBehavior") }
    }
    /// App language is applied through SwiftUI's locale environment and explicit Foundation lookup.
    /// This keeps language changes live and avoids mutating the undocumented AppleLanguages default.
    @Published var appLanguage: AppLanguage {
        // Persist before @Published announces the change so legacy Foundation call sites that
        // resolve through `activeLocale` cannot observe the previous language for one render.
        willSet { d.set(newValue.rawValue, forKey: "appLanguage") }
    }

    /// Reactive locale used by SwiftUI views. Read this from the observed settings instance
    /// instead of going back through UserDefaults during an `@Published` update.
    var effectiveLocale: Locale {
        Self.locale(for: appLanguage)
    }
    @Published var defaultShell: DefaultShell {
        didSet { d.set(defaultShell.rawValue, forKey: "defaultShell") }
    }
    @Published var closeConfirm: Bool {
        didSet { d.set(closeConfirm, forKey: "closeConfirm") }
    }

    // ---------- 终端 ----------
    /// 终端字体名（空 = 自动回退到预置等宽字体）。
    @Published var termFont: String {
        didSet { d.set(termFont, forKey: "termFont") }
    }
    @Published var termFontSize: Int {
        didSet { d.set(termFontSize, forKey: "termFontSize") }
    }
    /// 光标形状：block / bar / underline。
    @Published var termCursorStyle: String {
        didSet { d.set(termCursorStyle, forKey: "termCursorStyle") }
    }
    @Published var termCursorBlink: Bool {
        didSet { d.set(termCursorBlink, forKey: "termCursorBlink") }
    }
    /// 滚动缓冲区行数。
    @Published var termScrollback: Int {
        didSet { d.set(termScrollback, forKey: "termScrollback") }
    }

    /// 默认下载目录（空=系统下载文件夹）。
    @Published var downloadDir: String {
        didSet { d.set(downloadDir, forKey: "downloadDir") }
    }
    /// 每次下载都询问保存位置。
    @Published var downloadAskEachTime: Bool {
        didSet { d.set(downloadAskEachTime, forKey: "downloadAskEachTime") }
    }
    /// 同时进行的传输（上传/下载共用）数量上限，超出排队。
    @Published var maxConcurrentTransfers: Int {
        didSet { d.set(maxConcurrentTransfers, forKey: "maxConcurrentTransfers") }
    }
    /// 暂停传输时是否释放并发名额：开启则暂停后空出的名额让排队任务补位（默认）；
    /// 关闭则暂停的任务仍占着名额，排队任务等其恢复或取消后才开跑（保持原有执行顺序）。
    @Published var pausedReleasesSlot: Bool {
        didSet { d.set(pausedReleasesSlot, forKey: "pausedReleasesSlot") }
    }
    /// 下载时是否自动弹出进度弹窗（默认开）；关闭后下载不弹窗，仅以「飞入左下角后台任务」的弧线动画提示。
    @Published var showDownloadDialog: Bool {
        didSet { d.set(showDownloadDialog, forKey: "showDownloadDialog") }
    }

    /// 资源告警：监控到 CPU/内存/磁盘持续高占用时发系统通知。
    @Published var resourceAlerts: Bool {
        didSet { d.set(resourceAlerts, forKey: "resourceAlerts") }
    }

    /// 关闭主窗口时隐藏到菜单栏（后台任务继续运行），而非退出。
    @Published var closeToTray: Bool {
        didSet { d.set(closeToTray, forKey: "closeToTray") }
    }

    /// 删除主机前弹出确认弹窗，避免误删。
    @Published var confirmHostDelete: Bool {
        didSet { d.set(confirmHostDelete, forKey: "confirmHostDelete") }
    }

    /// 永久隐藏监控面板的采集说明（持久化）。
    @Published var monitorNoticeHidden: Bool {
        didSet { d.set(monitorNoticeHidden, forKey: "monitorNoticeHidden") }
    }

    // 代码片段点击运行的行为；默认「每次询问」：首次点击弹「插入/运行」选择，可勾选记住后不再询问。
    @Published var snippetAction: SnippetAction {
        didSet { d.set(snippetAction.rawValue, forKey: "snippetAction") }
    }


    private init() {
        Self.migrateLegacyLanguageOverride(defaults: d)
        startupBehavior = StartupBehavior(rawValue: d.string(forKey: "startupBehavior") ?? "") ?? .welcome
        defaultShell = DefaultShell(rawValue: d.string(forKey: "defaultShell") ?? "") ?? .auto
        closeConfirm = d.object(forKey: "closeConfirm") as? Bool ?? true
        termFont = d.string(forKey: "termFont") ?? ""
        termFontSize = d.object(forKey: "termFontSize") as? Int ?? 13
        termCursorStyle = d.string(forKey: "termCursorStyle") ?? "bar"
        termCursorBlink = d.object(forKey: "termCursorBlink") as? Bool ?? true
        termScrollback = d.object(forKey: "termScrollback") as? Int ?? 1000
        downloadDir = d.string(forKey: "downloadDir") ?? ""
        downloadAskEachTime = d.object(forKey: "downloadAskEachTime") as? Bool ?? false
        maxConcurrentTransfers = d.object(forKey: "maxConcurrentTransfers") as? Int ?? 2
        pausedReleasesSlot = d.object(forKey: "pausedReleasesSlot") as? Bool ?? true
        showDownloadDialog = d.object(forKey: "showDownloadDialog") as? Bool ?? true
        resourceAlerts = d.object(forKey: "resourceAlerts") as? Bool ?? true
        closeToTray = d.object(forKey: "closeToTray") as? Bool ?? false
        confirmHostDelete = d.object(forKey: "confirmHostDelete") as? Bool ?? true
        monitorNoticeHidden = d.object(forKey: "monitorNoticeHidden") as? Bool ?? false
        snippetAction = SnippetAction(rawValue: d.string(forKey: "snippetAction") ?? "") ?? .ask
        appLanguage = Self.storedLanguage(defaults: d)
    }

    static func storedLanguage(defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
    }

    /// Older builds implemented the in-app picker by writing the private per-app AppleLanguages
    /// preference. That value can keep forcing English even after the picker says "System".
    /// Reset that legacy override once; subsequent explicit choices live only in appLanguage.
    @discardableResult
    static func migrateLegacyLanguageOverride(
        defaults: UserDefaults = .standard,
        appDomain: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard !defaults.bool(forKey: languageMigrationKey) else { return false }
        defer { defaults.set(true, forKey: languageMigrationKey) }
        guard let appDomain,
              defaults.persistentDomain(forName: appDomain)?["AppleLanguages"] != nil else { return false }
        defaults.removeObject(forKey: "AppleLanguages")
        defaults.set(AppLanguage.system.rawValue, forKey: "appLanguage")
        return true
    }

    /// Read the macOS language order from the global domain so a stale per-app override cannot
    /// influence the System option during the migration launch.
    static func systemPreferredLanguages(defaults: UserDefaults = .standard) -> [String] {
        if let languages = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"]
            as? [String], !languages.isEmpty {
            return languages
        }
        return Locale.preferredLanguages
    }

    /// Locale for Foundation strings created outside a SwiftUI `Text` hierarchy.
    static var activeLocale: Locale {
        locale(for: storedLanguage())
    }

    static func locale(
        for language: AppLanguage,
        preferredLanguages: [String]? = nil
    ) -> Locale {
        guard language == .system,
              let identifier = (preferredLanguages ?? systemPreferredLanguages()).first else {
            return language.locale
        }
        return Locale(identifier: identifier)
    }

    /// Resource bundle used by Foundation-created strings. `String(localized:locale:)`
    /// only uses `locale` for formatting; selecting an in-app language also requires
    /// resolving that language's `.lproj` bundle explicitly.
    static var localizationBundle: Bundle {
        localizationBundle(for: storedLanguage())
    }

    static func localizationBundle(
        for language: AppLanguage,
        in bundle: Bundle = .main,
        preferredLanguages: [String]? = nil
    ) -> Bundle {
        let identifier: String
        switch language {
        case .system:
            let preferences = preferredLanguages ?? systemPreferredLanguages()
            guard let preferred = Bundle.preferredLocalizations(
                from: bundle.localizations, forPreferences: preferences).first else { return bundle }
            identifier = preferred
        case .zh:
            identifier = "zh-Hans"
        case .en:
            identifier = "en"
        }

        guard let path = bundle.path(forResource: identifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return bundle
        }
        return localizedBundle
    }

    /// 实际下载目录：设置为空则用系统下载文件夹。
    var resolvedDownloadDir: URL {
        if !downloadDir.isEmpty {
            return URL(fileURLWithPath: (downloadDir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// 解析出实际的 shell 可执行路径。
    var resolvedShell: String {
        switch defaultShell {
        case .auto: return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        }
    }
}
