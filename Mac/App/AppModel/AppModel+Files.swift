import AppKit
import Foundation
import TermoCore

extension AppModel {
    func browserState(for tabId: Int, host: Host) -> BrowserState {
        fileWorkspace.browserState(for: tabId, host: host)
    }

    /// 网络恢复后重置所有文件视图的底层连接，使下次操作自动重建 SFTP（而非一直降级为 shell）。
    /// 共享传输先由网络回调作废；这里重置各视图的 SFTP 操作并重载。
    func reconnectFileViewsAfterNetworkChange() {
        fileWorkspace.reconnectAll(
            tabHostPairs: tabs.map { ($0.id, $0.hostId) },
            sshByHostId: Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0.ssh ?? SSHConnection()) }))
    }

    @discardableResult
    func addTab(_ kind: TabKind, title: String, hostId: String?, terminalCommand: String? = nil) -> Int {
        let id = nextTabId
        nextTabId += 1
        // A terminal view can be requested as soon as the published tab appears. Register its PTY+exec
        // command first so tmux tabs can never fall back to an ordinary login shell during that update.
        if kind == .terminal, let terminalCommand { terminalCommands[id] = terminalCommand }
        tabs.append(TabItem(id: id, kind: kind, title: title, hostId: hostId))
        activeTabId = id
        return id
    }

    /// 上传、解压或删除后，只刷新目标主机当前显示该目录的文件浏览器。
    func refreshBrowsers(host: Host, dir: String) {
        fileWorkspace.refreshBrowsers(host: host, dir: dir)
    }

    func tabHostId(_ tabId: Int) -> String? {
        tabs.first(where: { $0.id == tabId })?.hostId
    }

    /// 一次只编辑一个文件操作；运行中的删除结束前不接受新的文件写操作。
    func prepareFileOperation(for host: Host) -> UUID? {
        guard workspaceContext.hostId == host.id, !fileDeleteBusy, !batchDeleteBusy else { return nil }
        fileOperationGeneration = UUID()
        pendingFileRename = nil
        pendingFileCreate = nil
        pendingFileChmod = nil
        pendingFileDelete = nil
        pendingBatchDelete = nil
        pendingFileInfo = nil
        return fileOperationGeneration
    }

    /// 切换主机时放弃尚未提交的编辑；已提交的删除仍按其原始目标完成。
    func cancelFileOperationsOnWorkspaceChange() {
        fileOperationGeneration = UUID()
        pendingFileRename = nil
        pendingFileCreate = nil
        pendingFileChmod = nil
        if !fileDeleteBusy { pendingFileDelete = nil }
        if !batchDeleteBusy { pendingBatchDelete = nil }
    }

    func fileMenuRequestDelete(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        guard prepareFileOperation(for: host) != nil else { return }
        pendingFileDelete = FileOpContext(file: file, host: host, target: target)
    }

    /// 确认删除：弹窗保留并进入「删除中」（删除键旁转圈），过程可经 cancelFileDelete 中途取消。
    /// 删除可能较慢（大目录 rm -rf），故不立刻关弹窗——成功后才关，失败弹错误，取消后刷新真实状态。
    func confirmFileDelete() {
        guard let ctx = pendingFileDelete, ctx.host.id == workspaceContext.hostId, !fileDeleteBusy else {
            return
        }
        fileDeleteBusy = true
        let handle = CommandHandle()
        deleteHandle = handle
        let host = ctx.host
        let parent = (ctx.file.path as NSString).deletingLastPathComponent
        let dir = parent.isEmpty ? "/" : parent
        Task { @MainActor in
            let r = await ctx.target.performDelete(ctx.file, handle: handle)
            deleteHandle = nil
            fileDeleteBusy = false
            if handle.isCancelled {
                refreshBrowsers(host: host, dir: dir)  // 取消可能已部分删除，刷新反映真实状态
                return
            }
            pendingFileDelete = nil
            if case .failure(let e) = r {
                pendingFileInfo = FileInfoContext(
                    title: String(localized: "删除失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: e.message, hostId: ctx.host.id)
            }
        }
    }

    /// 取消删除：删除进行中则终止远端命令（收尾与刷新交给删除任务的完成回调），随后关闭弹窗。
    func cancelFileDelete() {
        if fileDeleteBusy { deleteHandle?.cancel() }
        pendingFileDelete = nil
    }

    // MARK: - 批量删除

    func requestBatchDelete(_ files: [RemoteFile], host: Host, target: any FileOpsTarget) {
        guard !files.isEmpty, prepareFileOperation(for: host) != nil else { return }
        pendingBatchDelete = BatchDeleteContext(files: files, host: host, target: target)
    }

    /// 确认批量删除：逐个删除（弹窗保留 + 转圈），完成后关弹窗；任一失败弹错误提示。
    func confirmBatchDelete() {
        guard let ctx = pendingBatchDelete, ctx.host.id == workspaceContext.hostId, !batchDeleteBusy else {
            return
        }
        batchDeleteBusy = true
        Task { @MainActor in
            var failed: [String] = []
            for f in ctx.files {
                if case .failure = await ctx.target.performDelete(f, handle: nil) { failed.append(f.name) }
            }
            batchDeleteBusy = false
            pendingBatchDelete = nil
            if !failed.isEmpty {
                let shown = failed.prefix(8).joined(separator: "、")
                pendingFileInfo = FileInfoContext(
                    title: String(localized: "部分删除失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    message: String(
                        localized: "未能删除：\(shown)\(failed.count > 8 ? String(localized: " 等", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : "")"),
                    hostId: ctx.host.id)
            }
        }
    }

    func cancelBatchDelete() { if !batchDeleteBusy { pendingBatchDelete = nil } }

    func fileMenuRequestRename(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        guard prepareFileOperation(for: host) != nil else { return }
        pendingFileRename = FileOpContext(file: file, host: host, target: target)
    }

    func confirmFileRename(newName: String) {
        guard let ctx = pendingFileRename, ctx.host.id == workspaceContext.hostId else { return }
        pendingFileRename = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".",
            trimmed != ".."
        else {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "名称无效", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: String(localized: "名称不能为空、为「.」或「..」，也不能包含「/」。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                hostId: ctx.host.id)
            return
        }
        if trimmed == ctx.file.name { return }
        Task { @MainActor in
            switch await ctx.target.performRename(ctx.file, newName: trimmed) {
            case .success:
                break  // 操作目标负责刷新文件浏览器
            case .failure(let e):
                pendingFileInfo = FileInfoContext(
                    title: String(localized: "重命名失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: e.message, hostId: ctx.host.id)
            }
        }
    }

    func fileMenuRequestChmod(_ file: RemoteFile, host: Host, target: any FileOpsTarget) {
        guard let generation = prepareFileOperation(for: host) else { return }
        Task { @MainActor in
            let perms = await target.currentPerms(file) ?? (file.isDir ? 0o755 : 0o644)
            guard fileOperationGeneration == generation, workspaceContext.hostId == host.id else { return }
            pendingFileChmod = ChmodContext(file: file, host: host, target: target, mode: perms)
        }
    }

    func confirmFileChmod(mode: Int) {
        guard let ctx = pendingFileChmod, ctx.host.id == workspaceContext.hostId else { return }
        pendingFileChmod = nil
        Task { @MainActor in
            if case .failure(let e) = await ctx.target.performChmod(ctx.file, mode: String(mode, radix: 8)) {
                pendingFileInfo = FileInfoContext(
                    title: String(localized: "修改权限失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: e.message, hostId: ctx.host.id)
            }
        }
    }

    // MARK: - 新建文件 / 文件夹

    func fileMenuRequestCreate(isDir: Bool, inDir dir: String, host: Host, target: any FileOpsTarget) {
        guard prepareFileOperation(for: host) != nil else { return }
        pendingFileCreate = CreateContext(dir: dir, isDir: isDir, host: host, target: target)
    }

    func confirmFileCreate(name: String) {
        guard let ctx = pendingFileCreate, ctx.host.id == workspaceContext.hostId else { return }
        pendingFileCreate = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"), trimmed != ".",
            trimmed != ".."
        else {
            pendingFileInfo = FileInfoContext(
                title: String(localized: "名称无效", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), message: String(localized: "名称不能为空、为「.」或「..」，也不能包含「/」。", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                hostId: ctx.host.id)
            return
        }
        Task { @MainActor in
            if case .failure(let e) = await ctx.target.performCreate(
                trimmed, isDir: ctx.isDir, inDir: ctx.dir)
            {
                pendingFileInfo = FileInfoContext(
                    title: ctx.isDir ? String(localized: "新建文件夹失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "新建文件失败", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale),
                    message: e.message, hostId: ctx.host.id)
            }
        }
    }

}
