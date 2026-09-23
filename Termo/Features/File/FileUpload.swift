import SwiftUI

// MARK: - 状态

enum ItemState: Equatable {
    case waiting          // 待传
    case checking         // 探测远端（同名/续传）
    case asking           // 命中同名，等用户决策
    case uploading        // 传输中（含压缩到临时文件）
    case done             // 完成
    case skipped          // 用户跳过
    case failed(String)   // 失败（保留 message；非压缩可续传）
    case cancelled        // 被取消
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
    let localSize: Int64
    let remotePath: String

    @Published var state: ItemState = .waiting
    @Published var sent: Int64 = 0          // 已确认字节（用于进度与总量）
    var interrupted = false                 // 失败留下半截、可续传

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
final class UploadTask: ObservableObject {
    nonisolated let id = UUID()
    let direction: TransferDirection
    let destDir: String
    let totalBytes: Int64
    // 所属主机（用于后台中控按主机分组；创建后即设，仅展示用）
    var hostId: String? = nil
    var hostName: String = ""
    private let fs: RemoteFS
    private let onAllDone: () -> Void

    @Published var items: [UploadItem]
    @Published var phase: SessionPhase = .queued    // 初始排队；由协调器调用 start() 出队转 .running
    /// 任务进入终态（完成/取消）时回调一次，供上层推进传输队列。
    var onFinished: (() -> Void)? = nil
    /// 暂停/请求恢复后回调，供协调器重新泵队列（补位排队任务、放行等待名额的恢复请求）。
    var onPauseStateChanged: (() -> Void)? = nil
    /// 用户已点「继续」但当前无空闲名额，处于「等待协调器放行」状态（phase 仍为 .paused）。
    @Published private(set) var awaitingSlot = false

    /// 本任务是否有失败的文件（供托盘红灯等失败提示）。
    var hasFailure: Bool {
        items.contains { if case .failed = $0.state { return true } else { return false } }
    }

    /// 逐文件目标互斥锁（由协调器 AppModel 注入）：传输每个文件前后获取/释放，
    /// 仅当两任务真要同时写同一目标文件时才串行，避免 .part 临时文件互相覆盖；其余文件照常并发。
    var acquirePathLock: ((String) async -> Void)? = nil
    var releasePathLock: ((String) -> Void)? = nil

    /// 单个目标文件的锁键：上传以「主机+远端路径」（.part 临时名相同才会撞），下载以本地路径。
    private func lockKey(_ item: UploadItem) -> String {
        switch direction {
        case .upload:   return "up:\(hostId ?? ""):\(item.remotePath)"
        case .download: return "down:\(item.url.path)"
        }
    }
    @Published var index = 0
    @Published var overallSent: Int64 = 0
    @Published var speed: Double = 0
    @Published var pendingAsk: AskContext? = nil

    private let control = UploadControl()
    private var bulkPolicy: BulkPolicy = .ask
    private var askCont: CheckedContinuation<OverwriteDecision, Never>?
    private var resumeCont: CheckedContinuation<Void, Never>?   // 暂停时挂起主循环，恢复时唤醒
    private var lastSampledOverall: Int64 = 0
    private var pendingBaselineReset = true
    private var started = false
    private var heldLockKey: String? = nil   // 当前持有的逐文件写锁（暂停期间保留，结束时释放）

    /// 切换到目标文件 `key` 的写锁：先放掉旧锁（懒释放，上一文件已处理完），再获取新锁。
    /// 同一文件重复进入（暂停后恢复）不会重复获取。
    private func switchLock(to key: String) async {
        if heldLockKey == key { return }
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
        await acquirePathLock?(key)
        heldLockKey = key
    }
    /// 释放当前持有的写锁（任务收尾或被取消时）。
    private func releaseHeldLock() {
        if let h = heldLockKey { releasePathLock?(h); heldLockKey = nil }
    }

    init(files: [URL], destDir: String, fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .upload
        self.destDir = destDir
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = files.map { UploadItem(url: $0, destDir: destDir) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    /// 下载任务：把远端文件拉到本地。`localURLs` 与 `files` 一一对应，由上层去重产出
    /// （不覆盖本地已有文件、不与其它进行中下载撞名，必要时加 “ (n)” 后缀），`dir` 仅用于展示保存位置。
    init(download files: [RemoteFile], toLocalURLs localURLs: [URL], inDir dir: URL,
         fs: RemoteFS, onAllDone: @escaping () -> Void) {
        self.direction = .download
        self.destDir = dir.path
        self.fs = fs
        self.onAllDone = onAllDone
        let mapped = zip(files, localURLs).map { UploadItem(download: $0, toLocalURL: $1) }
        self.items = mapped
        self.totalBytes = mapped.reduce(0) { $0 + $1.localSize }
    }

    func start() {
        guard !started else { return }
        started = true
        phase = .running            // 出队开跑（初始为 .queued）
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    private func run() async {
        if direction == .download { await runDownload() } else { await runFrom() }
    }

    func cancel() {
        if phase == .queued {           // 尚未开始：直接取消并出队（让协调器推进下一个）
            phase = .cancelled
            onFinished?()
            return
        }
        guard phase == .running || phase == .paused else { return }
        control.set(.cancel)
        // 若卡在同名询问，唤醒它（否则 runFrom 挂在 await 上，cancel 无效）
        if let cont = askCont { askCont = nil; pendingAsk = nil; cont.resume(returning: .cancel) }
        wakeFromPause()   // 暂停态取消：唤醒挂起的主循环，使其看到 .cancel 后收尾
    }

    /// 暂停：停掉当前传输（保留半截 .part / 本地半截），主循环挂起等待恢复。
    func pause() {
        guard phase == .running else { return }
        phase = .paused
        awaitingSlot = false
        control.set(.pause)
        onPauseStateChanged?()   // 可能空出名额，让协调器补位排队任务
    }

    /// 用户请求恢复：由协调器调用，`slotFree` 表示当前是否有空闲名额。
    /// 有空位则立即续传；无空位则标记 awaitingSlot，待协调器在名额释放时放行（admitResume）。
    func requestResume(slotFree: Bool) {
        guard phase == .paused else { return }
        if slotFree {
            actuallyResume()
        } else {
            awaitingSlot = true
            onPauseStateChanged?()   // 刷新 UI 为「等待中」
        }
    }

    /// 协调器放行一个「等待名额」的恢复请求（已确认有空位）。
    func admitResume() {
        guard phase == .paused, awaitingSlot else { return }
        actuallyResume()
    }

    /// 实际恢复：从断点续传当前文件，主循环继续推进。
    private func actuallyResume() {
        awaitingSlot = false
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }   // 采样循环在暂停时已退出，需重启
        wakeFromPause()
    }

    /// 主循环在暂停期间挂起；恢复/取消时由 wakeFromPause 唤醒。
    /// 取消信号也作为退出条件：否则取消时 phase 仍是 .paused，唤醒后会立刻重新挂起，导致取消无效。
    private func waitIfPaused() async {
        while phase == .paused, control.signal != .cancel {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in resumeCont = c }
        }
    }
    private func wakeFromPause() {
        if let c = resumeCont { resumeCont = nil; c.resume() }
    }

    /// 跑完后重试/续传失败项。
    func retryFailed(resume: Bool) {
        guard phase == .done else { return }
        for it in items {
            if case .failed = it.state {
                if !resume { it.interrupted = false }   // 重试=从 0；续传=保留半截
                it.state = .waiting
            }
        }
        index = 0
        phase = .running
        control.set(.run)
        pendingBaselineReset = true
        Task { await sampleLoop() }
        Task { await run() }
    }

    func resolveAsk(_ a: AskAction) {
        pendingAsk = nil
        let cont = askCont; askCont = nil
        switch a {
        case .overwrite:    cont?.resume(returning: .overwrite)
        case .skip:         cont?.resume(returning: .skip)
        case .overwriteAll: bulkPolicy = .overwriteAll; cont?.resume(returning: .overwrite)
        case .skipAll:      bulkPolicy = .skipAll;      cont?.resume(returning: .skip)
        case .cancel:       cont?.resume(returning: .cancel)
        }
    }

    // MARK: 主循环

    private func runFrom() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done || item.state == .skipped || item.state == .cancelled {
                index += 1; continue
            }
            await switchLock(to: lockKey(item))   // 同名文件互斥：取得本文件写锁（暂停恢复同文件不重复获取）
            if control.signal == .cancel { break } // 等锁期间可能被取消
            item.state = .checking
            pendingBaselineReset = true
            let probe = await fs.probeUpload(remotePath: item.remotePath)
            // 续传：本会话失败留半截（interrupted），或上次取消/失败保留的远端 .part
            //（远端有未完整 .part 且无正式文件 → 从上次断点接着传）。
            let resuming = item.interrupted
                || (probe.partSize > 0 && probe.partSize < item.localSize && !probe.finalExists)

            if !resuming, probe.finalExists {
                switch await resolveOverwrite(item: item, finalSize: probe.finalSize) {
                case .skip:      item.state = .skipped; index += 1; continue
                case .cancel:    control.set(.cancel)
                case .overwrite: break   // cat> 截断 .part，finalize 覆盖正式文件
                }
            }
            if control.signal == .cancel { break }

            // 续传偏移（仅非压缩续传）：以远端 .part 实际大小为准（审查 R1）
            var startOffset: Int64 = 0
            if resuming {
                startOffset = min(probe.partSize, item.localSize)
                if startOffset >= item.localSize, item.localSize > 0 {   // .part 已完整 → 直接落地
                    item.sent = item.localSize
                    item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                        ? .done : .failed(String(localized: "落地失败"))
                    index += 1; continue
                }
            }

            item.state = .uploading
            control.set(.run)
            control.setSent(startOffset)

            let outcome = await fs.upload(localURL: item.url, toRemote: item.remotePath,
                                          startOffset: startOffset, control: control)

            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = (try? await fs.finalizeUpload(remotePath: item.remotePath).get()) != nil
                    ? .done : .failed(String(localized: "落地失败"))
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // 保留远端 .part，恢复后从断点续传（不前进 index）
            case .failed(let msg):
                item.interrupted = true             // 保留半截 .part 供续传（偏移续传时再 probe）
                item.state = .failed(msg)
                index += 1                          // 单文件失败不中断队列
            }
            if control.signal == .cancel { break }
            await waitIfPaused()                     // 暂停则挂起，恢复后回到循环重传当前项（保留文件写锁）
        }
        finish()   // finish() 内统一释放写锁并回收 SFTP 会话
    }

    /// 下载主循环：逐个把远端文件流式拉到本地（带进度/取消）。无同名询问/续传（更简单）。
    private func runDownload() async {
        while index < items.count {
            if control.signal == .cancel { break }
            let item = items[index]
            if item.state == .done { index += 1; continue }
            await switchLock(to: lockKey(item))   // 同名本地目标互斥：避免两任务同时写同一文件
            if control.signal == .cancel { break }
            item.state = .uploading        // 复用「传输中」态
            control.set(.run)
            // 暂停恢复：本地已有半截则从其大小续传，远端从该偏移继续读
            let startOffset: Int64 = item.interrupted ? UploadItem.fileSize(item.url) : 0
            control.setSent(startOffset)
            pendingBaselineReset = true
            let outcome = await fs.download(item.remotePath, to: item.url, startOffset: startOffset, control: control)
            switch outcome {
            case .completed:
                item.sent = item.localSize
                item.interrupted = false
                item.state = .done
                index += 1
            case .cancelled:
                control.set(.cancel)
            case .paused:
                item.interrupted = true             // 保留本地半截，恢复后续传（不前进 index）
            case .failed(let msg):
                try? FileManager.default.removeItem(at: item.url)   // 删掉下了一半的本地残文件
                item.interrupted = false
                item.state = .failed(msg)
                index += 1
            }
            if control.signal == .cancel { break }
            await waitIfPaused()
        }
        finish()   // finish() 内统一释放写锁并回收 SFTP 会话
    }

    private func resolveOverwrite(item: UploadItem, finalSize: Int64) async -> OverwriteDecision {
        if control.signal == .cancel { return .cancel }
        switch bulkPolicy {
        case .overwriteAll: return .overwrite
        case .skipAll:      return .skip
        case .ask:          break
        }
        item.state = .asking
        let ctx = AskContext(name: item.name, remoteSize: finalSize, localSize: item.localSize)
        return await withCheckedContinuation { cont in
            askCont = cont
            pendingAsk = ctx
        }
    }

    private func finish() {
        let landedAny = items.contains { $0.state == .done }
        if control.signal == .cancel {
            for it in items {
                switch it.state {
                case .done, .skipped, .failed: break
                default:
                    it.state = .cancelled
                    if direction == .download { try? FileManager.default.removeItem(at: it.url) }   // 删半截本地文件
                }
            }
            phase = .cancelled
        } else {
            phase = .done
            postCompletionNotification()
        }
        if landedAny { onAllDone() }
        releaseHeldLock()       // 释放当前持有的逐文件写锁
        fs.closeSession()       // 终态立即回收 SFTP 子进程/读循环线程/缓冲（记录仍留列表也不再占内存）
        onFinished?()           // 终态：推进传输队列
    }

    private func postCompletionNotification() {
        let verb = String(localized: direction == .upload ? "上传" : "下载")
        let done = items.filter { $0.state == .done }.count
        if hasFailures {
            Notifier.notify(title: String(localized: "\(verb)部分失败"), body: String(localized: "成功 \(done)/\(items.count) 个文件"))
        } else {
            Notifier.notify(title: String(localized: "\(verb)完成"), body: String(localized: "\(done) 个文件 · \(humanSize(totalBytes))"))
        }
    }

    // MARK: 速度采样（0.1s + EMA 平滑；压缩时把「已传压缩字节」映射回原始字节空间）

    private func sampleLoop() async {
        let dt = 0.1
        while phase == .running {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if index < items.count, items[index].state == .uploading {
                let it = items[index]
                it.sent = max(it.sent, min(it.localSize, control.sent))
            }
            let overall = items.reduce(0) { $0 + $1.sent }
            overallSent = overall
            if pendingBaselineReset {
                lastSampledOverall = overall
                pendingBaselineReset = false
            } else {
                let instant = max(0, Double(overall - lastSampledOverall) / dt)
                lastSampledOverall = overall
                speed = speed * 0.7 + instant * 0.3   // EMA 平滑
            }
        }
    }

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
    var hasFailures: Bool { items.contains { if case .failed = $0.state { return true }; return false } }

    /// 是否存在"传了一半被取消/失败"的远端残留 .part（可保留以便下次续传，或删除）。仅上传有此概念。
    var hasPartials: Bool { direction == .upload && items.contains { partialRemotePath($0) != nil } }

    /// 删除所有残留 .part（用户取消时选择"删除残留"）。best-effort，失败靠下次 probe 自愈。
    func cleanupPartials() {
        let paths = items.compactMap(partialRemotePath)
        guard !paths.isEmpty else { return }
        let fs = self.fs
        Task { for p in paths { await fs.cleanupPart(remotePath: p) }; fs.closeSession() }   // 删完即关，勿留会话
    }

    private func partialRemotePath(_ it: UploadItem) -> String? {
        guard it.sent > 0, it.sent < it.localSize else { return nil }
        switch it.state { case .cancelled, .failed: return it.remotePath; default: return nil }
    }
}

// MARK: - 传输详情

/// 常用文件编辑优先显示；不会为展开进度而丢弃尚未提交的名称、权限或删除确认。
struct FileTaskShelf: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel

    private var fileOperationVisible: Bool {
        let hostId = model.workspaceContext.hostId
        return model.pendingFileRename.map { $0.host.id == hostId } == true
            || model.pendingFileCreate.map { $0.host.id == hostId } == true
            || model.pendingFileChmod.map { $0.host.id == hostId } == true
            || model.pendingFileDelete.map { $0.host.id == hostId } == true
            || model.pendingBatchDelete.map { $0.host.id == hostId } == true
            || model.pendingFileInfo.map { $0.hostId == nil || $0.hostId == hostId } == true
    }

    var body: some View {
        Group {
            if !fileOperationVisible {
                if let id = model.focusedTransferId,
                   let task = model.transfers.first(where: { $0.id == id }) {
                    UploadDialog(task: task, onHide: { model.focusedTransferId = nil },
                                 onClose: { model.removeTransfer(id) }).id(task.id)
                } else if let task = model.extractTask, model.showExtractDialog {
                    ExtractDialog(task: task, onHide: { model.showExtractDialog = false },
                                  onClose: { model.clearExtract() }).id(task.id)
                }
            }
        }
    }
}

/// 工作区底部详情：不阻挡导航和终端，任务可随时收起至后台中心。
struct UploadDialog: View {
    @ObservedObject var task: UploadTask
    let onHide: () -> Void
    let onClose: () -> Void
    @State private var cancellationRequested = false

    private var isActive: Bool { task.phase == .queued || task.phase == .running || task.phase == .paused }
    private var isCancelling: Bool { cancellationRequested && isActive }
    private var isTransferring: Bool { task.phase == .running && task.pendingAsk == nil && !isCancelling }
    private var doneCount: Int { task.items.filter { $0.state == .done }.count }
    private var failedCount: Int { task.items.filter { if case .failed = $0.state { return true }; return false }.count }
    private var skippedCount: Int { task.items.filter { $0.state == .skipped }.count }
    private var displayedSent: Int64 {
        task.items.reduce(0) { total, item in
            item.state == .skipped || item.state == .cancelled ? total : total + min(max(0, item.sent), item.localSize)
        }
    }
    private var progress: Double {
        guard task.effectiveTotal > 0 else { return task.phase == .done && !task.hasFailures ? 1 : 0 }
        return min(1, max(0, Double(displayedSent) / Double(task.effectiveTotal)))
    }
    private var status: (text: String, color: Color) {
        if isCancelling { return (String(localized: "正在取消"), Pal.overlay) }
        if task.pendingAsk != nil { return (String(localized: "等待确认"), Pal.yellow) }
        switch task.phase {
        case .queued: return (String(localized: "排队中"), Pal.overlay)
        case .running: return (task.direction == .upload ? String(localized: "上传中") : String(localized: "下载中"), Pal.mauve)
        case .paused: return (task.awaitingSlot ? String(localized: "等待名额") : String(localized: "已暂停"), Pal.yellow)
        case .done:
            if failedCount == task.items.count && failedCount > 0 { return (String(localized: "传输失败"), Pal.red) }
            if failedCount > 0 { return (String(localized: "部分失败"), Pal.yellow) }
            return (String(localized: "已完成"), Pal.green)
        case .cancelled: return (String(localized: "已取消"), Pal.overlay)
        }
    }

    var body: some View {
        FileTaskDetailSurface {
            FileTaskDetailHeader(
                title: task.direction == .upload ? String(localized: "上传文件") : String(localized: "下载文件"),
                hostName: task.hostName, icon: task.direction == .upload ? "arrow.up.doc" : "arrow.down.doc",
                status: status.text, color: status.color, onHide: onHide)
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    transferSummary.frame(width: 250)
                    transferFiles.frame(minWidth: 260, idealWidth: 300, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    if task.pendingAsk != nil || task.hasFailures { transferFiles; transferSummary }
                    else { transferSummary; transferFiles }
                }
            }
        } footer: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Spacer(minLength: 0); buttons }
                VStack(alignment: .trailing, spacing: 8) { buttons }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onChange(of: task.id) { cancellationRequested = false }
        .onChange(of: task.phase) { if !isActive { cancellationRequested = false } }
    }

    private var transferSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileTaskPathRow(title: task.direction == .upload ? String(localized: "远端目标") : String(localized: "保存到本机"), path: task.destDir)
            summary
        }
    }

    private var transferFiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let ask = task.pendingAsk { askPanel(ask) }
            if task.phase == .cancelled, task.hasPartials {
                Label("远端保留了未传完的文件，可供下次续传。", systemImage: "arrow.clockwise")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(spacing: 1) {
                ForEach(task.items) { item in
                    UploadRow(item: item, direction: task.direction, phase: task.phase)
                }
            }
            .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("已完成 \(doneCount) / \(task.items.count) 个文件")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                Spacer(minLength: 4)
                if isActive && task.effectiveTotal > 0 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(status.color)
                }
            }
            FileTaskProgressBar(value: progress, color: status.color)
                .accessibilityLabel(String(localized: "总体传输进度"))
            if isActive {
                Text("\(humanSize(min(displayedSent, task.effectiveTotal))) / \(humanSize(task.effectiveTotal))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                if isTransferring {
                    HStack(spacing: 12) {
                        Text(task.speed > 0 ? humanSize(Int64(task.speed)) + "/s" : String(localized: "正在计算速度…"))
                        Spacer(minLength: 0)
                        if task.eta.isFinite, task.eta > 0, task.speed > 1 {
                            Text("预计剩余 \(formattedETA)")
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                } else {
                    Text(waitingDescription).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if failedCount > 0 || skippedCount > 0 {
                Text("失败 \(failedCount) · 跳过 \(skippedCount)")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            }
        }
    }

    private var waitingDescription: String {
        if isCancelling { return String(localized: "正在结束当前文件传输，可收起后继续工作。") }
        if task.pendingAsk != nil { return String(localized: "选择同名文件的处理方式后继续。") }
        if task.phase == .queued || task.awaitingSlot { return String(localized: "其他传输结束后会自动开始。") }
        return String(localized: "进度已保留，点击继续可恢复传输。")
    }

    private var formattedETA: String {
        let seconds = Int(min(task.eta.rounded(), Double(Int.max - 1)))
        if seconds >= 3600 { return String(localized: "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟") }
        if seconds >= 60 { return String(localized: "\(seconds / 60) 分 \(seconds % 60) 秒") }
        return String(localized: "\(seconds) 秒")
    }

    private func askPanel(_ ask: AskContext) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("目标位置已有同名文件", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.yellow)
            Text(ask.name).font(.system(size: 12)).foregroundStyle(Pal.text)
                .lineLimit(2).truncationMode(.middle).help(ask.name).textSelection(.enabled)
            Text("远端 \(humanSize(ask.remoteSize)) · 本地 \(humanSize(ask.localSize))")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { conflictButtons }
                VStack(alignment: .leading, spacing: 8) { conflictButtons }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.yellow.opacity(0.2), lineWidth: 1))
        .disabled(isCancelling)
    }

    @ViewBuilder private var conflictButtons: some View {
        FileTaskAction(title: String(localized: "跳过")) { task.resolveAsk(.skip) }
        FileTaskAction(title: String(localized: "覆盖"), prominent: true) { task.resolveAsk(.overwrite) }
        Menu {
            Button("全部跳过") { task.resolveAsk(.skipAll) }
            Button("全部覆盖") { task.resolveAsk(.overwriteAll) }
        } label: {
            Text("应用到全部").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(String(localized: "对本任务后续的同名文件使用相同处理方式"))
    }

    @ViewBuilder private var buttons: some View {
        switch task.phase {
        case .queued, .running, .paused:
            FileTaskAction(title: isCancelling ? String(localized: "正在取消…") : String(localized: "取消传输")) {
                cancellationRequested = true
                task.cancel()
            }.disabled(isCancelling)
            if task.phase == .running, task.pendingAsk == nil {
                FileTaskAction(title: String(localized: "暂停")) { AppModel.shared.pauseTransfer(task) }
                    .disabled(isCancelling)
            } else if task.phase == .paused {
                FileTaskAction(title: task.awaitingSlot ? String(localized: "等待名额…") : String(localized: "继续传输"), prominent: true) {
                    AppModel.shared.resumeTransfer(task)
                }.disabled(task.awaitingSlot || isCancelling)
            }
            FileTaskAction(title: String(localized: "收起"), prominent: task.phase != .paused, action: onHide)
        case .done where task.hasFailures:
            FileTaskAction(title: String(localized: "关闭详情"), action: onHide)
            FileTaskAction(title: String(localized: "重传")) { task.retryFailed(resume: false) }
                .help(String(localized: "从头重新传输失败的文件"))
            if task.direction == .upload {
                FileTaskAction(title: String(localized: "续传失败项"), prominent: true) { task.retryFailed(resume: true) }
            }
        case .cancelled where task.hasPartials:
            FileTaskAction(title: String(localized: "删除残留")) { task.cleanupPartials(); onClose() }
            FileTaskAction(title: String(localized: "保留以便续传"), prominent: true, action: onClose)
        case .done, .cancelled:
            FileTaskAction(title: String(localized: "清除记录"), action: onClose)
            FileTaskAction(title: String(localized: "关闭详情"), prominent: true, action: onHide)
        }
    }
}

/// 文件名、传输量、失败原因各占一行，长错误不再挤掉文件名。
struct UploadRow: View {
    @ObservedObject var item: UploadItem
    var direction: TransferDirection = .upload
    var phase: SessionPhase = .running

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(2).truncationMode(.middle).help(item.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(label).foregroundStyle(color)
                    Spacer(minLength: 0)
                    Text(humanSize(item.localSize)).foregroundStyle(Pal.overlay)
                }.font(.system(size: 10.5)).monospacedDigit()
                if item.state == .uploading {
                    FileTaskProgressBar(value: item.fraction, color: color)
                        .accessibilityLabel(String(localized: "文件传输进度"))
                }
                if case .failed(let message) = item.state, !message.isEmpty {
                    Text(message).font(.system(size: 11)).foregroundStyle(Pal.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .padding(11)
        .contextMenu {
            Button("复制文件路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(direction == .upload ? item.remotePath : item.url.path, forType: .string)
            }
        }
    }

    private var icon: String {
        switch item.state {
        case .waiting: return "clock"
        case .checking: return "magnifyingglass"
        case .asking: return "questionmark.circle"
        case .uploading: return phase == .paused ? "pause.circle" : (direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
        case .done: return "checkmark.circle.fill"
        case .skipped: return "forward.circle"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }
    private var color: Color {
        switch item.state {
        case .uploading: return phase == .paused ? Pal.yellow : Pal.mauve
        case .asking: return Pal.yellow
        case .done: return Pal.green
        case .failed: return Pal.red
        default: return Pal.overlay
        }
    }
    private var label: String {
        switch item.state {
        case .waiting: return phase == .cancelled ? String(localized: "已取消") : String(localized: "待传输")
        case .checking: return String(localized: "检查目标文件")
        case .asking: return String(localized: "等待确认")
        case .uploading: return phase == .paused ? String(localized: "已暂停") : "\(Int(min(1, max(0, item.fraction)) * 100))%"
        case .done: return String(localized: "完成")
        case .skipped: return String(localized: "已跳过")
        case .failed: return String(localized: "传输失败")
        case .cancelled: return String(localized: "已取消")
        }
    }
}

// MARK: - 文件后台任务通用外观

/// 固定头尾、主体滚动；作为工作区子视图参与布局，不创建全窗点击层。
struct FileTaskDetailSurface<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header().padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Pal.fill(0.06))
            ScrollView { content().padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading) }
            Divider().overlay(Pal.fill(0.06))
            footer().padding(.horizontal, 16).padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity).frame(height: 280)
        .background(Pal.solidMantle)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .overlay(alignment: .top) { Rectangle().fill(Pal.fill(0.12)).frame(height: 1) }
    }
}

struct FileTaskProgressBar: View {
    let value: Double
    let color: Color
    private var fraction: Double { value.isFinite ? min(1, max(0, value)) : 0 }
    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Pal.fill(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: geometry.size.width * fraction)
                }
        }
        .frame(height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(fraction * 100))%")
    }
}

struct FileTaskDetailHeader: View {
    let title: String
    let hostName: String
    let icon: String
    let status: String
    let color: Color
    let onHide: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Pal.mauve)
                .frame(width: 32, height: 32)
                .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                }
                Text(hostName.isEmpty ? String(localized: "远程主机") : hostName)
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.middle).help(hostName)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onHide) {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Pal.subtext).frame(width: 28, height: 28)
                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).pointerCursor()
                .help(String(localized: "收起详情，可在后台中心再次查看"))
                .accessibilityLabel(String(localized: "收起任务详情"))
        }
    }
}

struct FileTaskPathRow: View {
    let title: String
    let path: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(Pal.overlay)
            Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(2).truncationMode(.middle).help(path).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu {
            Button("复制完整路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }
}

struct FileTaskAction: View {
    let title: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Pal.mauve : Pal.subtext)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(prominent ? Pal.mauve.opacity(0.14) : Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor()
    }
}
