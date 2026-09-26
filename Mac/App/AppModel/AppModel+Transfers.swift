import AppKit
import Foundation
import TermoCore

extension AppModel {
    // ---------- 传输队列 ----------
    // 并发上限来自设置（上传/下载共用一个池，故二者可同时进行），其余排队；有任务终态时自动补位。

    /// 某主机是否有传输进行中，用于工作区收尾与后台任务展示。
    func hostHasRunningTransfer(_ hostId: String) -> Bool {
        transfers.contains { $0.hostId == hostId && $0.phase == .running }
    }

    /// 入队一个新传输：加入列表、自动展开其弹窗，并尝试按并发上限启动。
    func enqueueTransfer(_ task: UploadTask) {
        transferCoordinator.enqueue(task)
        // 下载且设置为「不弹窗」时：不展开弹窗，改放飞入左下角的弧线动画；其余情况照常自动展开。
        if task.direction == .download && !AppSettings.shared.showDownloadDialog {
            triggerDownloadFly(for: task)
        } else {
            focusedTransferId = task.id  // 在工作区底部展开新任务详情
        }
    }

    /// 触发一次「下载飞入左下角后台任务」的弧线动画。
    /// 起点优先取所选文件行的位置（首个文件），未命中则回退鼠标位置、再回退默认偏移；终点为后台按钮中心。
    /// 全部坐标统一在 SwiftUI 全局空间，叠层渲染时再按叠层自身原点换算（见 ContentView），故各窗口尺寸都对得上。
    /// 事件一次性，动画结束由视图清空，不常驻、不占 CPU/内存。
    func triggerDownloadFly(for task: UploadTask) {
        guard backgroundButtonCenter != .zero else { return }
        let from: CGPoint
        if let p = task.items.first?.remotePath, let r = fileRowGlobalFrames[p] {
            from = CGPoint(x: r.midX, y: r.midY)  // 所选文件行中心
        } else if let m = Self.currentMouseGlobal() {
            from = m  // 右键下载时鼠标即在该文件上
        } else {
            from = CGPoint(x: backgroundButtonCenter.x + 220, y: backgroundButtonCenter.y - 220)
        }
        flyTransfer = FlyEvent(id: UUID(), from: from)
    }

    /// 鼠标当前位置，转换到 SwiftUI 全局坐标（左上原点），用于动画起点。
    static func currentMouseGlobal() -> CGPoint? {
        guard let win = NSApp.keyWindow ?? NSApp.mainWindow, let cv = win.contentView else { return nil }
        let p = cv.convert(win.mouseLocationOutsideOfEventStream, from: nil)  // contentView 坐标，左下原点
        return CGPoint(x: p.x, y: cv.bounds.height - p.y)  // 翻转为左上原点
    }

    func pauseTransfer(_ task: UploadTask) { transferCoordinator.pause(task) }
    func resumeTransfer(_ task: UploadTask) { transferCoordinator.resume(task) }
    func retryTransfer(_ task: UploadTask, resume: Bool) { transferCoordinator.retry(task, resume: resume) }

    /// 上传文件到某文件夹：弹系统选择器（可多选文件），逐个上传，支持续传/压缩/同名询问。
    func beginUpload(into folder: RemoteFile, host: Host) {
        guard folder.isDir else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "上传", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        panel.message = String(localized: "选择要上传到「\(folder.name)」的文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startUpload(files: panel.urls, destDir: folder.path, host: host)
    }

    /// 外部文件拖入终端：上传到该终端的当前目录（OSC7 跟踪的 cwd；未知则取远端家目录）。仅 SSH 终端。
    func uploadDroppedFiles(_ urls: [URL], toTabId tabId: Int) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
            let host = host(tab.hostId), let ssh = host.ssh, !ssh.host.isEmpty
        else { return }
        // 只传文件，跳过目录
        let files = urls.filter {
            !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "无法上传", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: String(localized: "暂不支持拖拽文件夹，请拖入文件。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            return
        }
        Task { @MainActor in
            let cwd: String
            if let known = tabCwd[tabId] { cwd = known } else { cwd = await RemoteFS(ssh).home() }
            startUpload(files: files, destDir: cwd, host: host)
        }
    }

    /// 拖拽上传：把外部拖入的文件上传到指定远端目录（SFTP 浏览器拖放用）。只传文件，跳过文件夹。
    func uploadFiles(_ urls: [URL], toDir dir: String, host: Host) {
        guard let ssh = host.ssh, !ssh.host.isEmpty, !dir.isEmpty else { return }
        let files = urls.filter {
            !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
        }
        guard !files.isEmpty else {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "无法上传", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: String(localized: "暂不支持拖拽文件夹，请拖入文件。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            return
        }
        startUpload(files: files, destDir: dir, host: host)
    }

    /// 启动上传任务（核心）：入队后按并发上限自动开始；落地后刷新目标目录的文件浏览器。
    func startUpload(files: [URL], destDir: String, host: Host) {
        guard !files.isEmpty else { return }
        let task = UploadTask(
            files: files, destDir: destDir,
            fs: RemoteFS(host.ssh ?? SSHConnection()), pathLocks: transferPathLocks
        ) { [weak self] in
            self?.refreshBrowsers(host: host, dir: destDir)
        }
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    // MARK: - 下载

    /// 下载远端文件到本地：按设置取目录或每次询问目录；进度/后台复用上传那套传输对话框，完成后在访达定位。
    /// 与上传共用传输队列（可并发，超出排队）。目录暂不支持，仅文件。
    func downloadFiles(_ files: [RemoteFile], host: Host) {
        let downloadable = files.filter { !$0.isDir }
        guard !downloadable.isEmpty, let ssh = host.ssh, !ssh.host.isEmpty else { return }
        let dir: URL
        if AppSettings.shared.downloadAskEachTime {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "下载到此处", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            panel.message = String(localized: "选择下载保存到的文件夹", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            panel.directoryURL = AppSettings.shared.resolvedDownloadDir
            guard panel.runModal() == .OK, let u = panel.url else { return }
            dir = u
        } else {
            dir = AppSettings.shared.resolvedDownloadDir
        }
        // 完成后不再自动弹访达窗口（打断用户）；完成提醒由系统通知给出。
        // 本地保存名去重：不覆盖已有文件、不与进行中下载撞名 → 不同主机/来源的同名文件可并发各自落地。
        let localURLs = resolveDownloadURLs(downloadable, dir: dir)
        let task = UploadTask(
            download: downloadable, toLocalURLs: localURLs, inDir: dir, fs: RemoteFS(ssh),
            pathLocks: transferPathLocks
        ) {}
        task.hostId = host.id
        task.hostName = host.name
        enqueueTransfer(task)
    }

    /// 为一批下载计算互不冲突、且不覆盖本地已有文件的保存路径：
    /// 目标名若已存在于磁盘、或已被进行中/排队/暂停的下载占用，则在扩展名前追加 “ (n)” 后缀（同 Finder/浏览器习惯）。
    /// 如此不同主机、不同来源的同名文件可各自落地并发下载，重复下载也不会覆盖旧文件。
    func resolveDownloadURLs(_ files: [RemoteFile], dir: URL) -> [URL] {
        var taken = Set<String>()
        for t in transfers where t.direction == .download {
            switch t.phase {
            case .done, .cancelled: break
            default: for it in t.items { taken.insert(it.url.path) }
            }
        }
        let fm = FileManager.default
        var result: [URL] = []
        for f in files {
            var candidate = dir.appendingPathComponent(f.name)
            if fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path) {
                let base = (f.name as NSString).deletingPathExtension
                let ext = (f.name as NSString).pathExtension
                var n = 1
                repeat {
                    let newName = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                    candidate = dir.appendingPathComponent(newName)
                    n += 1
                } while fm.fileExists(atPath: candidate.path) || taken.contains(candidate.path)
            }
            taken.insert(candidate.path)  // 同批内也去重
            result.append(candidate)
        }
        return result
    }

    // MARK: - 解压

    /// 请求解压压缩包：弹出解压弹窗（选目标后开始），完成后局部刷新归档所在目录、发系统通知。
    /// 与上传/下载相互独立，但同一时刻只允许一个解压任务（避免迷你状态与目标目录冲突）。
    func requestExtract(_ file: RemoteFile, host: Host) {
        guard !file.isDir, let kind = ArchiveKind.detect(file.name),
            let ssh = host.ssh, !ssh.host.isEmpty
        else { return }
        if let t = extractTask, t.phase == .running {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "已有解压进行中", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                message: String(localized: "请等当前解压结束后再开始新的解压。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
            return
        }
        let parent = (file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        let task = ExtractTask(
            archive: file, kind: kind, parentDir: dir,
            fs: RemoteFS(ssh)
        ) { [weak self] in
            self?.refreshBrowsers(host: host, dir: dir)
        }
        task.hostId = host.id
        task.hostName = host.name
        extractTask = task
        showExtractDialog = true
    }

}
