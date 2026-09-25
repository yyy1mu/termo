import SwiftUI

// MARK: - 传输详情

/// 文件操作优先显示；不会为展开进度而丢弃尚未提交的名称、权限或删除确认。
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

    private var isActive: Bool { task.phase == .queued || task.phase == .running || task.phase == .paused }
    private var isCancelling: Bool { task.isCancelling && isActive }
    private var isTransferring: Bool { task.phase == .running && task.pendingAsk == nil && task.schedulingStatus == nil }
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
        if let waiting = task.schedulingStatus { return (waiting, Pal.overlay) }
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
            FileTaskAction(title: String(localized: "重传")) { AppModel.shared.retryTransfer(task, resume: false) }
                .help(String(localized: "从头重新传输失败的文件"))
            if task.direction == .upload {
                FileTaskAction(title: String(localized: "续传失败项"), prominent: true) { AppModel.shared.retryTransfer(task, resume: true) }
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
