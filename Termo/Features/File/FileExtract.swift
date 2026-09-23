import SwiftUI

// MARK: - 归档类型

/// 受支持的压缩包/压缩文件类型。多文件归档默认解压到「同名新文件夹」，单文件压缩默认解压到「当前目录」。
enum ArchiveKind: Equatable {
    case tarGz, tarBz2, tarXz, tarZst, tar, zip, sevenZip, rar   // 多文件归档
    case gz, bz2, xz, zst                                        // 单文件压缩

    /// 按文件名后缀识别（复合后缀如 .tar.gz 优先于 .gz）；非归档返回 nil，用于决定是否显示「解压」菜单。
    static func detect(_ name: String) -> ArchiveKind? {
        let n = name.lowercased()
        func ends(_ s: String) -> Bool { n.hasSuffix(s) }
        if ends(".tar.gz")  || ends(".tgz")  { return .tarGz }
        if ends(".tar.bz2") || ends(".tbz2") || ends(".tbz") { return .tarBz2 }
        if ends(".tar.xz")  || ends(".txz")  { return .tarXz }
        if ends(".tar.zst") || ends(".tzst") { return .tarZst }
        if ends(".tar")  { return .tar }
        if ends(".zip")  { return .zip }
        if ends(".7z")   { return .sevenZip }
        if ends(".rar")  { return .rar }
        if ends(".gz")   { return .gz }
        if ends(".bz2")  { return .bz2 }
        if ends(".xz")   { return .xz }
        if ends(".zst")  { return .zst }
        return nil
    }

    /// 多文件归档（决定默认是否解压到新文件夹）。
    var isMultiFile: Bool {
        switch self {
        case .gz, .bz2, .xz, .zst: return false
        default: return true
        }
    }

    /// 解压所需的远端命令；缺失时给出可读提示。
    var tool: String {
        switch self {
        case .tarGz, .tarBz2, .tarXz, .tarZst, .tar: return "tar"
        case .zip: return "unzip"
        case .sevenZip: return "7z"
        case .rar: return "unrar"
        case .gz: return "gzip"
        case .bz2: return "bzip2"
        case .xz: return "xz"
        case .zst: return "zstd"
        }
    }

    /// 去掉归档后缀得到基名（新建文件夹名 / 单文件解压后的文件名）。
    func baseName(_ name: String) -> String {
        let suffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz",
                        ".tar.zst", ".tzst", ".tar", ".zip", ".7z", ".rar", ".gz", ".bz2", ".xz", ".zst"]
        let lower = name.lowercased()
        for s in suffixes where lower.hasSuffix(s) { return String(name.dropLast(s.count)) }
        return name
    }
}

// MARK: - 解压任务

enum ExtractPhase: Equatable { case ready, running, done, failed(String) }

/// 单个解压任务：在目标主机上经多路复用 ssh 跑一条 tar/unzip 等命令，完成后局部刷新并发系统通知。
/// 解压无逐字节进度（命令侧不易获取），故用「运行中」转盘 + 完成/失败态，而非进度条；可后台运行。
@MainActor
final class ExtractTask: ObservableObject {
    nonisolated let id = UUID()
    let archive: RemoteFile
    let kind: ArchiveKind
    let parentDir: String          // 归档所在目录（解压产物落此层）
    let folderName: String         // 同名新文件夹 / 单文件解压后的文件名
    // 所属主机（用于后台中控按主机分组；创建后即设，仅展示用）
    var hostId: String? = nil
    var hostName: String = ""

    @Published var phase: ExtractPhase = .ready
    @Published var toSubfolder: Bool   // 解压到同名新文件夹（否则当前目录）

    private let fs: RemoteFS
    private let onDone: () -> Void

    init(archive: RemoteFile, kind: ArchiveKind, parentDir: String,
         fs: RemoteFS, onDone: @escaping () -> Void) {
        self.archive = archive
        self.kind = kind
        self.parentDir = parentDir
        self.folderName = kind.baseName(archive.name)
        self.fs = fs
        self.onDone = onDone
        self.toSubfolder = kind.isMultiFile
    }

    /// 实际解压目标目录。
    var destDir: String {
        toSubfolder ? childPath(parentDir, folderName) : parentDir
    }

    func begin() {
        guard phase == .ready else { return }
        phase = .running
        let cmd = remoteCommand()
        let fs = self.fs
        Task { @MainActor in
            let r = await fs.run(cmd, timeout: 1800)
            if r.code == 0 {
                phase = .done
                Notifier.notify(title: String(localized: "解压完成"), body: "\(archive.name) → \(destDir)")
                onDone()
            } else {
                let err = String(data: r.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                phase = .failed(err.isEmpty ? String(localized: "解压失败（退出码 \(r.code)）") : err)
                Notifier.notify(title: String(localized: "解压失败"), body: archive.name)
            }
        }
    }

    func retry() {
        guard case .failed = phase else { return }
        phase = .ready
        begin()
    }

    private func childPath(_ dir: String, _ name: String) -> String {
        (dir == "/" ? "" : dir) + "/" + name
    }

    /// 构造远端解压命令：路径全部经 base64 还原后用双引号引用，杜绝空格/特殊字符与注入问题。
    /// 先校验所需命令存在，再 mkdir -p 目标目录，最后按类型解压。
    private func remoteCommand() -> String {
        let aB64 = Data(archive.path.utf8).base64EncodedString()
        let dB64 = Data(destDir.utf8).base64EncodedString()
        let head = "A=$(printf %s '\(aB64)'|base64 -d); D=$(printf %s '\(dB64)'|base64 -d); "
        let check = "command -v \(kind.tool) >/dev/null 2>&1 || { echo '远端缺少 \(kind.tool) 命令' >&2; exit 127; }; "
        let mk = "mkdir -p -- \"$D\" && "

        switch kind {
        case .tarGz:    return head + check + mk + "tar -xzf \"$A\" -C \"$D\""
        case .tarBz2:   return head + check + mk + "tar -xjf \"$A\" -C \"$D\""
        case .tarXz:    return head + check + mk + "tar -xJf \"$A\" -C \"$D\""
        case .tarZst:   return head + check + mk + "tar --use-compress-program=unzstd -xf \"$A\" -C \"$D\""
        case .tar:      return head + check + mk + "tar -xf \"$A\" -C \"$D\""
        case .zip:      return head + check + mk + "unzip -o \"$A\" -d \"$D\""
        case .sevenZip: return head + check + mk + "7z x -y -o\"$D\" \"$A\""
        case .rar:      return head + check + mk + "unrar x -o+ \"$A\" \"$D/\""
        case .gz, .bz2, .xz, .zst:
            let sB64 = Data(folderName.utf8).base64EncodedString()
            let s = "S=$(printf %s '\(sB64)'|base64 -d); "
            let dec: String
            switch kind {
            case .gz:  dec = "gzip -dc -- \"$A\""
            case .bz2: dec = "bzip2 -dc -- \"$A\""
            case .xz:  dec = "xz -dc -- \"$A\""
            default:   dec = "zstd -dc -- \"$A\""
            }
            return head + s + check + mk + "\(dec) > \"$D/$S\""
        }
    }
}

// MARK: - 解压详情

/// 与传输共用工作区内嵌详情；命令无字节进度，不显示虚构百分比。
struct ExtractDialog: View {
    @ObservedObject var task: ExtractTask
    let onHide: () -> Void
    let onClose: () -> Void

    private var status: (text: String, color: Color) {
        switch task.phase {
        case .ready: return (String(localized: "待解压"), Pal.overlay)
        case .running: return (String(localized: "解压中"), Pal.mauve)
        case .done: return (String(localized: "已完成"), Pal.green)
        case .failed: return (String(localized: "解压失败"), Pal.red)
        }
    }

    var body: some View {
        FileTaskDetailSurface {
            FileTaskDetailHeader(title: String(localized: "解压文件"), hostName: task.hostName,
                                 icon: "doc.zipper", status: status.text, color: status.color, onHide: onHide)
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    FileTaskPathRow(title: String(localized: "压缩文件"), path: task.archive.path).frame(width: 250)
                    stage.frame(minWidth: 260, idealWidth: 300, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) {
                    stage
                    FileTaskPathRow(title: String(localized: "压缩文件"), path: task.archive.path)
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

    private var stage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if task.phase == .ready {
                destinationPicker
            } else {
                FileTaskPathRow(title: String(localized: "解压到"), path: task.destDir)
                switch task.phase {
                case .running:
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("正在远端解压…").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                            Text("收起后会继续运行，完成时通知你。")
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .done:
                    Label("文件已解压完成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.green)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("解压未完成", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.red)
                        Text(message.isEmpty ? String(localized: "远端未返回详细原因，请检查目标目录和解压工具。") : message)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Pal.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                case .ready: EmptyView()
                }
            }
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解压位置").font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.overlay)
            VStack(spacing: 6) {
                destinationOption(String(localized: "同名新文件夹"), detail: task.folderName, selected: task.toSubfolder) {
                    task.toSubfolder = true
                }
                destinationOption(String(localized: "当前目录"), detail: task.parentDir, selected: !task.toSubfolder) {
                    task.toSubfolder = false
                }
            }
            FileTaskPathRow(title: String(localized: "实际目标"), path: task.destDir)
            Text("目标位置已有的同名文件可能被覆盖。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func destinationOption(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Pal.mauve : Pal.overlay)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                    Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Pal.subtext)
                        .lineLimit(1).truncationMode(.middle).help(detail)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(selected ? Pal.mauve.opacity(0.09) : Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Pal.mauve.opacity(0.35) : Pal.fill(0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).pointerCursor()
            .accessibilityLabel(title + "，" + detail)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var buttons: some View {
        switch task.phase {
        case .ready:
            FileTaskAction(title: String(localized: "取消"), action: onClose)
            FileTaskAction(title: String(localized: "开始解压"), prominent: true) { task.begin() }
        case .running:
            FileTaskAction(title: String(localized: "收起并继续工作"), prominent: true, action: onHide)
        case .done:
            FileTaskAction(title: String(localized: "清除记录"), action: onClose)
            FileTaskAction(title: String(localized: "关闭详情"), prominent: true, action: onHide)
        case .failed:
            FileTaskAction(title: String(localized: "关闭详情"), action: onHide)
            FileTaskAction(title: String(localized: "重试解压"), prominent: true) { task.retry() }
        }
    }
}
