import Foundation

// MARK: - 标签右键操作的弹窗上下文

struct TabRenameContext: Identifiable {
    let id: Int  // 目标标签 id
    let currentTitle: String
}

struct MultiCloseContext: Identifiable {
    let id = UUID()
    let ids: [Int]  // 待关闭的标签 id 集合
}

// MARK: - 文件栏右键操作的弹窗上下文

struct FileOpContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
}

struct BatchDeleteContext: Identifiable {
    let id = UUID()
    let files: [RemoteFile]
    let host: Host
    let target: any FileOpsTarget
}

struct ChmodContext: Identifiable {
    let id = UUID()
    let file: RemoteFile
    let host: Host
    let target: any FileOpsTarget
    let mode: Int  // 当前权限（八进制值，如 0o755）
}

struct CreateContext: Identifiable {
    let id = UUID()
    let dir: String  // 在此目录下新建
    let isDir: Bool  // true=文件夹，false=文件
    let host: Host
    let target: any FileOpsTarget
}

struct FileInfoContext: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var hostId: String? = nil
}
