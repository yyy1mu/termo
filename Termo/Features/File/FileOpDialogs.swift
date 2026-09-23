import SwiftUI

/// 重命名弹窗（自定义样式，与 ConfirmDialog 一致）。
struct RenameDialog: View {
    let originalName: String
    let title: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @ObservedObject private var theme = ThemeManager.shared

    init(originalName: String, title: String = String(localized: "重命名"),
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.title = title
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    private var canConfirm: Bool {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && !t.contains("/")
    }
    private func submit() { if canConfirm { onConfirm(name) } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                ThemedTextField(placeholder: "名称", text: $name, autofocus: true, onSubmit: submit)
                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "确定", enabled: canConfirm, action: submit)
                }
            }
            .padding(20).frame(width: 360)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
        }
    }
}

/// 文件操作放在当前工作区底部，不遮挡主机导航和其他工具。
struct FileOperationShelf: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel

    private var hostId: String? { model.workspaceContext.hostId }

    var body: some View {
        Group {
            if let ctx = model.pendingFileRename, ctx.host.id == hostId {
                FileNameEditor(title: String(localized: "重命名"), host: ctx.host.name,
                    path: ctx.file.path, originalName: ctx.file.name,
                    onConfirm: { model.confirmFileRename(newName: $0) },
                    onCancel: { model.pendingFileRename = nil }).id(ctx.id)
            } else if let ctx = model.pendingFileCreate, ctx.host.id == hostId {
                FileNameEditor(title: ctx.isDir ? String(localized: "新建文件夹") : String(localized: "新建文件"),
                    host: ctx.host.name, path: ctx.dir, originalName: "",
                    onConfirm: { model.confirmFileCreate(name: $0) },
                    onCancel: { model.pendingFileCreate = nil }).id(ctx.id)
            } else if let ctx = model.pendingFileChmod, ctx.host.id == hostId {
                FilePermissionEditor(host: ctx.host.name, path: ctx.file.path, initialMode: ctx.mode,
                    onConfirm: { model.confirmFileChmod(mode: $0) },
                    onCancel: { model.pendingFileChmod = nil }).id(ctx.id)
            } else if let ctx = model.pendingFileDelete, ctx.host.id == hostId {
                FileDeleteEditor(host: ctx.host.name, names: [ctx.file.name],
                    busy: model.fileDeleteBusy, canCancel: true,
                    onConfirm: model.confirmFileDelete, onCancel: model.cancelFileDelete)
            } else if let ctx = model.pendingBatchDelete, ctx.host.id == hostId {
                FileDeleteEditor(host: ctx.host.name, names: ctx.files.map(\.name),
                    busy: model.batchDeleteBusy, canCancel: !model.batchDeleteBusy,
                    onConfirm: model.confirmBatchDelete, onCancel: model.cancelBatchDelete)
            } else if let info = model.pendingFileInfo, info.hostId == nil || info.hostId == hostId {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(info.title, systemImage: "exclamationmark.circle").foregroundStyle(Pal.yellow)
                        Spacer(minLength: 8)
                        Button("关闭") { model.pendingFileInfo = nil }.buttonStyle(.plain)
                    }
                    Text(info.message).font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .textSelection(.enabled).lineLimit(4).help(info.message)
                }
                .font(.system(size: 12, weight: .medium))
                .fileOperationSurface()
            }
        }
        .onChange(of: hostId) { _, _ in model.cancelFileEditingOnWorkspaceChange() }
    }
}

private struct FileNameEditor: View {
    let title: String
    let host: String
    let path: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(title: String, host: String, path: String, originalName: String,
         onConfirm: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title; self.host = host; self.path = path
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !trimmed.isEmpty && !trimmed.contains("/") && !trimmed.contains("\0") && trimmed != "." && trimmed != ".."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileOperationHeading(title: title, host: host, detail: path)
            ThemedTextField(placeholder: "名称", text: $name, autofocus: true,
                onSubmit: { if valid { onConfirm(trimmed) } })
            HStack {
                if !trimmed.isEmpty && !valid {
                    Text("名称无效").font(.system(size: 11)).foregroundStyle(Pal.red)
                }
                Spacer(minLength: 8)
                SecondaryButton(title: "取消", action: onCancel)
                PrimaryButton(title: "保存", enabled: valid) { onConfirm(trimmed) }
            }
        }
        .fileOperationSurface()
    }
}

private struct FilePermissionEditor: View {
    let host: String
    let path: String
    let onConfirm: (Int) -> Void
    let onCancel: () -> Void
    @State private var octal: String

    init(host: String, path: String, initialMode: Int,
         onConfirm: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.host = host; self.path = path
        self.onConfirm = onConfirm; self.onCancel = onCancel
        _octal = State(initialValue: String(format: "%03o", initialMode & 0o777))
    }

    private var mode: Int? {
        guard octal.count == 3, octal.allSatisfy({ "01234567".contains($0) }) else { return nil }
        return Int(octal, radix: 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileOperationHeading(title: String(localized: "修改权限"), host: host, detail: path)
            HStack(spacing: 12) {
                Text("权限码").font(.system(size: 12)).foregroundStyle(Pal.subtext)
                ThemedTextField(placeholder: "755", text: $octal).frame(width: 80)
                Text(mode.map(Self.symbolic) ?? String(localized: "请输入 3 位八进制数"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(mode == nil ? Pal.red : Pal.subtext)
                Spacer(minLength: 0)
            }
            Text("读 = 4，写 = 2，执行 = 1；依次为所有者、用户组、其他人。")
                .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 8)
                SecondaryButton(title: "取消", action: onCancel)
                PrimaryButton(title: "应用", enabled: mode != nil) { if let mode { onConfirm(mode) } }
            }
        }
        .fileOperationSurface()
    }

    private static func symbolic(_ mode: Int) -> String {
        [6, 3, 0].map { shift in
            let bits = mode >> shift
            return (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
        }.joined()
    }
}

private struct FileDeleteEditor: View {
    let host: String
    let names: [String]
    let busy: Bool
    let canCancel: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileOperationHeading(title: String(localized: "删除 \(names.count) 个项目"), host: host,
                detail: names.joined(separator: "、"))
            Text("项目及目录内的内容将被永久删除。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            HStack(spacing: 10) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("正在删除…").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer(minLength: 8)
                SecondaryButton(title: "取消", action: onCancel).disabled(!canCancel)
                Button(role: .destructive, action: onConfirm) {
                    Text("确认删除").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.red, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain).disabled(busy)
            }
        }
        .fileOperationSurface()
    }
}

private struct FileOperationHeading: View {
    let title: String
    let host: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text(host).font(.system(size: 10)).foregroundStyle(Pal.mauve)
                    .lineLimit(1).truncationMode(.middle).help(host)
            }
            Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                .lineLimit(2).truncationMode(.middle).help(detail).textSelection(.enabled)
        }
    }
}

private extension View {
    func fileOperationSurface() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.solidMantle)
            .overlay(alignment: .top) { Rectangle().fill(Pal.border).frame(height: 1) }
    }
}
