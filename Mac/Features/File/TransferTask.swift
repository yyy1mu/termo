import Combine
import Foundation

// MARK: - 状态

enum ItemState: Equatable {
    case waiting  // 待传
    case checking  // 探测远端（同名/续传）
    case asking  // 命中同名，等用户决策
    case uploading  // 传输中（含压缩到临时文件）
    case done  // 完成
    case skipped  // 用户跳过
    case failed(String)  // 失败（保留 message；非压缩可续传）
    case cancelled  // 被取消
}

enum SessionPhase: Equatable { case queued, running, paused, done, cancelled }
enum TransferDirection { case upload, download }

enum OverwriteDecision { case overwrite, skip, cancel }
enum AskAction { case overwrite, skip, overwriteAll, skipAll, cancel }
enum BulkPolicy { case ask, overwriteAll, skipAll }

/// 单个待上传文件（引用类型 → 列表行单独订阅，避免整列表刷新）。
@MainActor
final class UploadItem: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let url: URL
    let name: String
    @Published var localSize: Int64
    let remotePath: String

    @Published var state: ItemState = .waiting
    @Published var sent: Int64 = 0  // 已确认字节（用于进度与总量）
    var downloadDestination: DownloadDestination?
    var uploadSource: UploadSource?
    var uploadPolicy: UploadRestartPolicy = .automatic
    var partialMayExist = false
    var overwriteApproved = false
    var interrupted = false  // 失败留下半截、可续传

    /// 上传项：url=本地源文件，remotePath=远端目标。
    init(url: URL, destDir: String) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = UploadItem.fileSize(url)
        self.remotePath = destDir.hasSuffix("/") ? destDir + name : destDir + "/" + name
    }

    /// 下载项：remotePath=远端源，url=本地目标（已由上层去重，避免覆盖本地已有文件/与其它下载撞名），
    /// name 取实际落地文件名（可能带 “ (n)” 后缀），localSize=远端大小（用作进度分母）。
    init(download file: RemoteFile, toLocalURL url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.localSize = file.size
        self.remotePath = file.path
    }

    var fraction: Double {
        localSize > 0 ? min(1, Double(sent) / Double(localSize)) : (state == .done ? 1 : 0)
    }
    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

struct AskContext: Identifiable {
    let id = UUID()
    let name: String
    let remoteSize: Int64
    let localSize: Int64
}

// MARK: - 上传任务

@MainActor
final class UploadTask: ObservableObject, ScheduledTransfer {
    nonisolated let id = UUID()
    let direction: TransferDirection
    let destDir: String
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.localSize } }
    // 所属主机（用于后台中控按主机分组；创建后即设，仅展示用）
    var hostId: String? = nil
    var hostName: String = ""
    private let fs: any TransferFileSystem
    private let pathLocks: TransferPathLocks
    private let notify: (String, String) -> Void
    private let onAllDone: () -> Void

    @Published var items: [UploadItem]
    @Published var phase: SessionPhase = .queued  // 初始排队；由协调器调用 start() 出队转 .running
    /// 只通知调度相关的状态变化；逐字节进度由任务视图直接观察。
    var onSchedulingChange: (() -> Void)?
    /// 用户已点「继续」但当前无空闲名额，处于「等待协调器放行」状态（phase 仍为 .paused）。
    @Published private(set) var awaitingSlot = false
    @Published private(set) var isWaitingForPath = false
    @Published private(set) var isCancelling = false
    @Published private(set) var isPerformingIO = false
    private var slotCont: CheckedContinuation<Bool, Never>?

    /// 本任务是否有失败的文件（供托盘红灯等失败提示）。
    var hasFailure: Bool {
        items.contains { if case .failed = $0.state { return true } else { return false } }
    }

    var schedulingStatus: String? {
        guard !phase.isFinished else { return nil }
        if isCancelling { return String(localized: "正在取消", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        if phase == .paused, isPerformingIO { return String(localized: "正在暂停", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        if phase == .paused, !awaitingSlot { return nil }
        if isWaitingForPath { return String(localized: "等待同名文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        if awaitingSlot { return String(localized: "等待名额", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) }
        return nil
    }

    /// 单个目标文件的锁键：上传以「主机+远端路径」（.part 临时名相同才会撞），下载以本地路径。
    private func lockKey(_ item: UploadItem) -> String {
        switch direction {
        case .upload: return "up:\(hostId ?? ""):\(item.remotePath)"
        case .download: return "down:\(item.url.standardizedFileURL.path)"
        }
    }
    @Published var index = 0
    @Published var overallSent: Int64 = 0
    @Published var speed: Double = 0
    @Published var pendingAsk: AskContext? = nil

    private let control = UploadControl()
    private var bulkPolicy: BulkPolicy = .ask
    private var askCont: CheckedContinuation<OverwriteDecision, Never>?
    private var resumeCont: CheckedContinuation<Void, Never>?  // 暂停时挂起主循环，恢复时唤醒
    private var lastSampledOverall: Int64 = 0
    private var pendingBaselineReset = true
    private var started = false
    private var samplingTask: Task<Void, Never>?
    private var heldLockKey: String? = nil  // 当前持有的逐文件写锁（暂停期间保留，结束时释放）

    /// Waiting for a path releases the scheduler slot; acquiring the path must then reacquire a slot.
    private func switchLock(to key: String) async -> Bool {
        if heldLockKey == key { return !isCancelling }
        releaseHeldLock()
        isPerformingIO = false
        isWaitingForPath = true
        speed = 0
        onSchedulingChange?()
        guard !isCancelling else { isWaitingForPath = false; return false }
        let acquired = await pathLocks.acquire(key, owner: id)
        isWaitingForPath = false
        if acquired { heldLockKey = key }
        guard acquired, !isCancelling else { return false }
        guard await waitIfPaused() else { return false }
        // Standalone tasks have no scheduler; production tasks always request admission here.
        guard onSchedulingChange != nil else { return true }
        return await withCheckedContinuation { continuation in
            slotCont = continuation
            awaitingSlot = true
            onSchedulingChange?()
        }
    }

    private func releaseHeldLock() {
        guard let key = heldLockKey else { return }
        heldLockKey = nil
        pathLocks.release(key, owner: id)
    }

    init(
        files: [URL], destDir: String, fs: any TransferFileSystem,
        pathLocks: TransferPathLocks? = nil,
        notify: @escaping (String, String) -> Void = { Notifier.notify(title: $0, body: $1) },
        onAllDone: @escaping () -> Void
    ) {
        self.direction = .upload
        self.destDir = destDir
        self.fs = fs
        self.pathLocks = pathLocks ?? TransferPathLocks()
        self.notify = notify
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
    }

    /// 下载任务：把远端文件拉到本地。`localURLs` 与 `files` 一一对应，由上层去重产出
    /// （不覆盖本地已有文件、不与其它进行中下载撞名，必要时加 “ (n)” 后缀），`dir` 仅用于展示保存位置。
    init(
        download files: [RemoteFile], toLocalURLs localURLs: [URL], inDir dir: URL,
        fs: any TransferFileSystem, pathLocks: TransferPathLocks? = nil,
        notify: @escaping (String, String) -> Void = { Notifier.notify(title: $0, body: $1) },
        onAllDone: @escaping () -> Void
    ) {
        self.direction = .download
        self.destDir = dir.path
        self.fs = fs
        self.pathLocks = pathLocks ?? TransferPathLocks()
        self.notify = notify
        self.onAllDone = onAllDone
        let mapped = zip(files, localURLs).map { UploadItem(download: $0, toLocalURL: $1) }
        self.items = mapped
    }

    func start() {
        guard phase == .queued, !started else { return }
        started = true
        phase = .running  // 出队开跑（初始为 .queued）
        pendingBaselineReset = true
        startSampling()
        Task { await run() }
    }

    private func run() async {
        if direction == .download { await runDownload() } else { await runFrom() }
    }

    func cancel() {
        guard !phase.isFinished, !isCancelling else { return }
        isCancelling = true
        control.set(.cancel)
        awaitingSlot = false
        pathLocks.cancelWaiting(owner: id)
        if let continuation = slotCont { slotCont = nil; continuation.resume(returning: false) }
        if phase == .queued {  // 尚未开始：直接取消并出队（让协调器推进下一个）
            phase = .cancelled
            onSchedulingChange?()
            return
        }
        guard phase == .running || phase == .paused else { return }
        // 若卡在同名询问，唤醒它（否则 runFrom 挂在 await 上，cancel 无效）
        if let cont = askCont { askCont = nil; pendingAsk = nil; cont.resume(returning: .cancel) }
        wakeFromPause()  // 暂停态取消：唤醒挂起的主循环，使其看到 .cancel 后收尾
        onSchedulingChange?()
    }

    /// 暂停：停掉当前传输（保留半截 .part / 本地半截），主循环挂起等待恢复。
    func pause() {
        guard phase == .running, !isCancelling else { return }
        phase = .paused
        awaitingSlot = false
        control.set(.pause)
        samplingTask?.cancel(); samplingTask = nil
        speed = 0
        onSchedulingChange?()  // 可能空出名额，让协调器补位排队任务
    }

    /// 用户请求恢复：由协调器调用，`slotFree` 表示当前是否有空闲名额。
    /// 有空位则立即续传；无空位则标记 awaitingSlot，待协调器在名额释放时放行（admitResume）。
    func requestResume(slotFree: Bool) {
        guard phase == .paused, !isCancelling else { return }
        if slotFree {
            actuallyResume()
        } else {
            awaitingSlot = true
            onSchedulingChange?()  // 刷新 UI 为「等待中」
        }
    }

    /// 协调器放行一个「等待名额」的恢复请求（已确认有空位）。
    func admitResume() {
        guard awaitingSlot, !isCancelling else { return }
        if phase == .running {
            awaitingSlot = false
            if let continuation = slotCont { slotCont = nil; continuation.resume(returning: true) }
        } else if phase == .paused {
            actuallyResume()
        }
    }

    /// 实际恢复：从断点续传当前文件，主循环继续推进。
    private func actuallyResume() {
        awaitingSlot = false
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        startSampling()  // 采样循环在暂停时已退出，需重启
        wakeFromPause()
        if let continuation = slotCont { slotCont = nil; continuation.resume(returning: true) }
    }

    /// 主循环在暂停期间挂起；恢复/取消时由 wakeFromPause 唤醒。
    /// 取消信号也作为退出条件：否则取消时 phase 仍是 .paused，唤醒后会立刻重新挂起，导致取消无效。
    @discardableResult
    private func waitIfPaused() async -> Bool {
        if phase == .paused, isPerformingIO {
            isPerformingIO = false  // The last operation has acknowledged pause; only now may its slot be reused.
            onSchedulingChange?()
        }
        while phase == .paused, !isCancelling {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resumeCont = c }
        }
        return !isCancelling
    }
    private func wakeFromPause() {
        if let c = resumeCont { resumeCont = nil; c.resume() }
    }

    /// Reset only failed items. The coordinator will start this attempt when a slot is available.
    func prepareRetry(resume: Bool) -> Bool {
        guard phase == .done, hasFailures else { return false }
        for item in items {
            if case .failed = item.state {
                item.uploadPolicy = resume ? .resume : .restart
                item.overwriteApproved = false
                if !resume { item.uploadSource = nil }
                if !resume || direction == .download { item.interrupted = false; item.sent = 0 }
                item.state = .waiting
            }
        }
        index = 0
        started = false
        isCancelling = false
        awaitingSlot = false
        control.set(.run)
        phase = .queued
        return true
    }

    func resolveAsk(_ a: AskAction) {
        pendingAsk = nil
        let cont = askCont; askCont = nil
        switch a {
        case .overwrite: cont?.resume(returning: .overwrite)
        case .skip: cont?.resume(returning: .skip)
        case .overwriteAll: bulkPolicy = .overwriteAll; cont?.resume(returning: .overwrite)
        case .skipAll: bulkPolicy = .skipAll; cont?.resume(returning: .skip)
        case .cancel: cont?.resume(returning: .cancel)
        }
    }

    // MARK: 主循环

    private func runFrom() async {
        while index < items.count {
            guard await waitIfPaused() else { break }
            let item = items[index]
            if item.state == .done || item.state == .skipped || item.state == .cancelled {
                index += 1; continue
            }
            guard await switchLock(to: lockKey(item)), await waitIfPaused() else { break }
            isPerformingIO = true
            item.state = .checking
            pendingBaselineReset = true
            let source = item.uploadSource ?? UploadSource(url: item.url)
            item.uploadSource = source
            let probe: UploadProbe
            do {
                item.localSize = try await source.prepare()
                guard await waitIfPaused() else { break }
                isPerformingIO = true
                probe = try await fs.probeUpload(remotePath: item.remotePath)
            }
            catch {
                guard await waitIfPaused() else { break }
                item.state = .failed((error as? RemoteFSError)?.message ?? error.localizedDescription)
                index += 1
                continue
            }
            guard await waitIfPaused() else { break }
            isPerformingIO = true

            if let finalSize = probe.finalSize, !item.overwriteApproved {
                switch await resolveOverwrite(item: item, finalSize: finalSize) {
                case .skip: item.state = .skipped; index += 1; continue
                case .cancel: cancel()
                case .overwrite: item.overwriteApproved = true
                }
            }
            guard await waitIfPaused() else { break }
            isPerformingIO = true

            let plan: UploadWritePlan
            do { plan = try .make(probe: probe, localSize: item.localSize, policy: item.uploadPolicy) }
            catch {
                item.state = .failed((error as? RemoteFSError)?.message ?? error.localizedDescription)
                index += 1
                continue
            }
            if probe.partSize != nil { item.partialMayExist = true }
            let startOffset: Int64
            switch plan {
            case .finalize:
                item.sent = item.localSize
                await finalize(item)
                index += 1
                continue
            case .write(let offset): startOffset = offset
            }

            item.state = .uploading
            item.sent = startOffset
            control.setSent(startOffset)
            item.partialMayExist = true

            let outcome = await fs.upload(
                source: source, toRemote: item.remotePath,
                startOffset: startOffset, control: control)

            switch outcome {
            case .completed:
                item.sent = item.localSize
                guard await waitIfPaused() else { break }
                isPerformingIO = true
                await finalize(item)
                index += 1
            case .cancelled:
                cancel()
            case .paused:
                item.uploadPolicy = .resume
                item.interrupted = true  // 保留远端 .part，恢复后从断点续传（不前进 index）
            case .failed(let msg):
                item.interrupted = true  // 保留半截 .part 供续传（偏移续传时再 probe）
                item.state = .failed(msg)
                index += 1  // 单文件失败不中断队列
            }
            if control.signal == .cancel { break }
            await waitIfPaused()  // 暂停则挂起，恢复后回到循环重传当前项（保留文件写锁）
        }
        finish()  // finish() 内统一释放写锁并回收 SFTP 会话
    }

    private func finalize(_ item: UploadItem) async {
        do {
            guard let source = item.uploadSource else { throw UploadSource.changed() }
            // If a pause arrived during inspection, inspect again after resume before renaming the partial.
            while true {
                guard await waitIfPaused() else { return }
                isPerformingIO = true
                _ = try await source.prepare()
                guard !isCancelling else { return }
                if phase != .paused { break }
            }
        } catch {
            item.state = .failed((error as? RemoteFSError)?.message ?? error.localizedDescription)
            item.interrupted = true
            return
        }
        let commit = UploadCommit(path: item.remotePath, size: item.localSize,
                                  replaceExisting: item.overwriteApproved)
        switch await fs.finalizeUpload(commit) {
        case .success:
            item.state = .done
            item.interrupted = false
            item.partialMayExist = false
        case .failure(let error):
            item.state = .failed(error.message)
            item.interrupted = true
            item.partialMayExist = true
        }
    }

    /// Downloads retain their private destination across pause; only a complete file becomes visible at the final path.
    private func runDownload() async {
        while index < items.count {
            guard await waitIfPaused() else { break }
            let item = items[index]
            if item.state == .done { index += 1; continue }
            guard await switchLock(to: lockKey(item)), await waitIfPaused() else { break }
            isPerformingIO = true
            item.state = .uploading  // 复用「传输中」态
            let destination = item.downloadDestination ?? DownloadDestination(url: item.url)
            item.downloadDestination = destination
            control.setSent(item.sent)
            pendingBaselineReset = true
            let outcome = await fs.download(item.remotePath, to: destination, control: control)
            if let size = destination.expectedSize { item.localSize = size }
            item.sent = min(item.localSize, control.sent)
            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.downloadDestination = nil
                item.state = .done
                index += 1
            case .cancelled:
                cancel()
            case .paused:
                item.interrupted = true
            case .failed(let message):
                let removed = destination.discard()
                item.downloadDestination = nil
                item.interrupted = false
                item.state = .failed(removed ? message : message + "\n" + String(localized: "下载临时文件未能清理，请检查保存目录。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                index += 1
            }
            if control.signal == .cancel { break }
            await waitIfPaused()
        }
        finish()  // finish() 内统一释放写锁并回收 SFTP 会话
    }

    private func resolveOverwrite(item: UploadItem, finalSize: Int64) async -> OverwriteDecision {
        if control.signal == .cancel { return .cancel }
        switch bulkPolicy {
        case .overwriteAll: return .overwrite
        case .skipAll: return .skip
        case .ask: break
        }
        item.state = .asking
        let ctx = AskContext(name: item.name, remoteSize: finalSize, localSize: item.localSize)
        return await withCheckedContinuation { cont in
            askCont = cont
            pendingAsk = ctx
        }
    }

    private func finish() {
        samplingTask?.cancel(); samplingTask = nil
        overallSent = items.reduce(0) { $0 + $1.sent }
        speed = 0
        awaitingSlot = false
        isPerformingIO = false
        let landedAny = items.contains { $0.state == .done }
        if control.signal == .cancel {
            for it in items {
                switch it.state {
                case .done, .skipped, .failed: break
                default:
                    it.state = .cancelled
                    it.downloadDestination?.discard()
                    it.downloadDestination = nil
                }
            }
            phase = .cancelled
        } else {
            phase = .done
            postCompletionNotification()
        }
        if landedAny { onAllDone() }
        releaseHeldLock()  // 释放当前持有的逐文件写锁
        fs.closeSession()  // 终态归还 SFTP 操作，完成记录不继续占用连接
        onSchedulingChange?()  // 终态：推进传输队列
    }

    private func postCompletionNotification() {
        let verb = direction == .upload ? String(localized: "上传", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "下载", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
        let done = items.filter { $0.state == .done }.count
        if hasFailures {
            notify(String(localized: "\(verb)部分失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "成功 \(done)/\(items.count) 个文件", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        } else {
            notify(
                String(localized: "\(verb)完成", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), String(localized: "\(done) 个文件 · \(humanSize(totalBytes))", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
        }
    }

    // MARK: 速度采样（0.1s + EMA 平滑；压缩时把「已传压缩字节」映射回原始字节空间）

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.phase == .running, !Task.isCancelled else { return }
                if !self.isWaitingForPath && !self.awaitingSlot { self.sampleProgress() }
            }
        }
    }

    private func sampleProgress() {
        if index < items.count, items[index].state == .uploading {
            let item = items[index]
            if let size = item.downloadDestination?.expectedSize, size != item.localSize { item.localSize = size }
            item.sent = max(item.sent, min(item.localSize, control.sent))
        }
        let overall = items.reduce(0) { $0 + $1.sent }
        overallSent = overall
        if pendingBaselineReset {
            lastSampledOverall = overall
            pendingBaselineReset = false
        } else {
            let instant = max(0, Double(overall - lastSampledOverall) / 0.1)
            lastSampledOverall = overall
            speed = speed * 0.7 + instant * 0.3
        }
    }

    deinit { samplingTask?.cancel() }

    // MARK: 派生

    /// 分母剔除跳过/取消项（审查 R14）。
    var effectiveTotal: Int64 {
        items.reduce(0) { (it: Int64, x) in
            (x.state == .skipped || x.state == .cancelled) ? it : it + x.localSize
        }
    }
    var eta: Double {
        guard speed > 1, phase == .running else { return 0 }
        return Double(effectiveTotal - overallSent) / speed
    }
    var hasFailures: Bool {
        items.contains {
            if case .failed = $0.state { return true }; return false
        }
    }

    /// 是否存在"传了一半被取消/失败"的远端残留 .part（可保留以便下次续传，或删除）。仅上传有此概念。
    var hasPartials: Bool { direction == .upload && items.contains { partialRemotePath($0) != nil } }

    /// 删除所有残留 .part（用户取消时选择"删除残留"）。best-effort，失败靠下次 probe 自愈。
    func cleanupPartials() {
        let partials = items.filter { partialRemotePath($0) != nil }
        guard !partials.isEmpty else { return }
        let fs = self.fs, locks = pathLocks
        let targets = partials.map { (key: lockKey($0), path: $0.remotePath) }
        Task {
            let owner = UUID()
            for target in targets {
                guard locks.tryAcquire(target.key, owner: owner) else { continue }
                await fs.cleanupPart(remotePath: target.path)
                locks.release(target.key, owner: owner)
            }
            fs.closeSession()
        }
    }

    private func partialRemotePath(_ it: UploadItem) -> String? {
        guard it.partialMayExist else { return nil }
        switch it.state {
        case .cancelled, .failed: return it.remotePath;
        default: return nil
        }
    }
}
