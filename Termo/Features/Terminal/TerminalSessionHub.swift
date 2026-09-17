import Foundation

/// 每主机一条共享终端连接（SSH 通道复用，等价 OpenSSH ControlMaster/ControlPersist 的效果）：
/// 同一主机的第 2…N 个终端标签不再重新握手/认证，直接在已有连接上开新 shell 通道（秒开、免密码）。
///
/// 共享语义（与 ControlMaster 的「共享命运」一致）：
/// - `acquire`：有存活会话直接复用；无则新建（一次完整登录）。新建期间持锁阻塞——
///   并发复制/掉线重连只摊销一次登录，其余调用方等锁后复用。
/// - 任一 shell 报 255（连接断开）→ `invalidate`：整条共享连接作废关闭，其上其余 shell 随之断开，
///   各标签走既有退避重连，重连时经 `acquire` 重新合并为一次登录。
/// - `release`：标签关闭时归还引用；归零即关闭会话（主机最后一个终端关掉后连接不残留）。
///
/// 线程安全：内部锁保护状态；`SSHSession`（russh 后端）的通道打开/写入本身线程安全。
final class TerminalSessionHub {
    private let lock = NSLock()
    private var session: SSHSession?
    private var refs = 0

    /// 是否有可复用的存活会话（供 AppModel 决定跳过认证/连接弹窗的快速路径）。
    var hasLiveSession: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    /// 取该主机的共享会话（没有则新建登录）。**同步阻塞，务必在后台线程调用**。
    /// 会话生命周期归 hub：调用方不 close，用完（标签关闭/驱动拆除）必须 `release`。
    func acquire(_ conn: SSHConnection) throws -> SSHSession {
        lock.lock()
        defer { lock.unlock() }
        if let s = session {
            refs += 1
            return s
        }
        let a = conn.libssh2Auth
        let s = try SSHSession.connect(host: conn.host, port: conn.port, user: conn.user,
                                       password: a.password, keyPath: a.keyPath,
                                       keyPassphrase: a.keyPassphrase)
        session = s
        refs = 1
        return s
    }

    /// 上报连接已断开（任一 shell 收到 255 或开通道失败）：作废并关闭当前共享会话，
    /// 之后 `acquire` 将重新登录。幂等：同一条会话的多次上报只有第一次生效。
    func invalidate(_ s: SSHSession) {
        lock.lock()
        guard session === s else { lock.unlock(); return }
        session = nil
        lock.unlock()
        // 其上其余 shell 的泵随连接关闭陆续断开（各报 255 走退避重连）。
        s.close()
    }

    /// 归还引用；归零时若会话仍是当前会话（未被 invalidate）则关闭它。
    func release(_ s: SSHSession) {
        lock.lock()
        refs -= 1
        let shouldClose = refs <= 0 && session === s
        if shouldClose { session = nil }
        lock.unlock()
        if shouldClose { s.close() }
    }
}
