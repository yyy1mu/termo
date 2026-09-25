import SwiftUI

/// 文件操作目标：右击菜单（重命名 / 权限 / 删除 / 上传后刷新）的后端。
/// 由 SFTP 浏览器实现，供操作确认界面调用并刷新对应目录。
@MainActor
protocol FileOpsTarget: AnyObject {
    /// handle 非空时可中途取消（目录递归删除较慢时用）。
    func performDelete(_ file: RemoteFile, handle: CommandHandle?) async -> Result<Void, RemoteFSError>
    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError>
    func performChmod(_ file: RemoteFile, mode: String) async -> Result<Void, RemoteFSError>
    func currentPerms(_ file: RemoteFile) async -> Int?
    /// 在 dir 下新建文件或文件夹，成功后局部刷新。
    func performCreate(_ name: String, isDir: Bool, inDir dir: String) async -> Result<Void, RemoteFSError>
}

/// 单个文件右击菜单的菜单项（抽出以便浏览器在多选时与批量菜单切换复用）。
@ViewBuilder
func fileOpsMenuItems(file: RemoteFile, host: Host, model: AppModel,
                      target: any FileOpsTarget, onRefresh: @escaping () -> Void) -> some View {
    Group {
        if file.isDir {
            Button { model.beginUpload(into: file, host: host) } label: {
                Label("上传文件…", systemImage: "square.and.arrow.up")
            }
            Button { model.fileMenuRequestCreate(isDir: false, inDir: file.path, host: host, target: target) } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
            }
            Button { model.fileMenuRequestCreate(isDir: true, inDir: file.path, host: host, target: target) } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Divider()
        } else {
            Button { model.downloadFiles([file], host: host) } label: {
                Label("下载", systemImage: "square.and.arrow.down")
            }
            if ArchiveKind.detect(file.name) != nil {
                Button { model.requestExtract(file, host: host) } label: {
                    Label("解压", systemImage: "doc.zipper")
                }
            }
            Divider()
        }
        Button(action: onRefresh) { Label("刷新", systemImage: "arrow.clockwise") }
        Divider()
        Button { model.fileMenuRequestRename(file, host: host, target: target) } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button { model.fileMenuRequestChmod(file, host: host, target: target) } label: {
            Label("权限", systemImage: "lock")
        }
        Divider()
        Button(role: .destructive) {
            model.fileMenuRequestDelete(file, host: host, target: target)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }
}
