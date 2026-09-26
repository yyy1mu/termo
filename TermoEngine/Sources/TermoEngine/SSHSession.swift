import CTermoSSH
import Foundation

/// 同一 SSH 传输上的独立操作句柄。取消/超时只影响本句柄，最后一个持有者释放传输。
/// 每个句柄用自己的串行队列，监控流、终端和文件操作之间可并发。
/// connect/exec 同步阻塞，须在后台调用。
public final class SSHSession: @unchecked Sendable {
    public struct SSHError: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? {
            if message.hasPrefix("HOSTKEY_"), let separator = message.range(of: ": ") {
                return String(message[separator.upperBound...])
            }
            return message
        }
        /// 主机密钥与已知记录不匹配（疑似 MITM）——上层可据此给出区别于普通失败的提示。
        public var isHostKeyMismatch: Bool { message.hasPrefix("HOSTKEY_MISMATCH") }
        public var isHostKeyFailure: Bool { message.hasPrefix("HOSTKEY_") }
    }
    public struct ExecResult { public let output: String; public let stderr: String; public let exitCode: Int }
    /// 二进制安全的 exec 结果（供 RemoteFS.run）：stdout/stderr 为原始字节，timedOut/cancelled 标识非正常结束。
    public struct ExecBytes { public let stdout: Data; public let stderr: Data; public let exitCode: Int32; public let timedOut: Bool; public let cancelled: Bool }

    private var handle: OpaquePointer?          // TermoSSHSession*
    private let queue: DispatchQueue
    private let handleLock = NSLock()
    private var onClose: (() -> Void)?
    public let transportID: UUID
    public let fingerprintSHA256: String
    public let fingerprintMD5: String

    private init(handle: OpaquePointer, queue: DispatchQueue, transportID: UUID = UUID(), onClose: (() -> Void)? = nil) {
        self.transportID = transportID
        self.onClose = onClose
        self.handle = handle
        self.queue = queue
        self.fingerprintSHA256 = String(cString: termo_ssh_session_sha256(handle))
        self.fingerprintMD5 = String(cString: termo_ssh_session_md5(handle))
    }

    /// 连接 + 握手 + 认证（同步，务必后台调用）。keyPath 非空走公钥认证。
    /// 握手后、认证前必须匹配 known_hosts；未知、变更、撤销或读取失败均拒绝。
    /// known_hosts 路径由平台层显式传入（真实持久文件 + 本会话临时文件），引擎不含任何 Swift 全局状态。
    public static func connect(host: String, port: Int, user: String,
                               password: String?, keyPath: String?, keyPassphrase: String?,
                               options: SSHTransportOptions,
                               realKnownHosts: String,
                               sessionKnownHosts: String) throws -> SSHSession {
        var err = [CChar](repeating: 0, count: 256)
        let handle = options.withRawOptions { rawOptions in
            termo_ssh_open(host, Int32(port), user, password, keyPath, keyPassphrase,
                           realKnownHosts, sessionKnownHosts, rawOptions, &err, 256)
        }
        guard let h = handle else {
            throw SSHError(message: String(cString: err))
        }
        return SSHSession(handle: h, queue: DispatchQueue(label: "termo.ssh.\(host):\(port)"))
    }

    /// 在已认证的传输上创建独立操作；不重复握手或发送密码。
    public func fork(onClose: @escaping () -> Void) throws -> SSHSession {
        try queue.sync {
            guard let handle, let child = termo_ssh_session_fork(handle) else {
                throw SSHError(message: String(localized: "SSH 连接已断开"))
            }
            return SSHSession(handle: child, queue: DispatchQueue(label: "termo.ssh.operation"),
                              transportID: transportID, onClose: onClose)
        }
    }

    public var isDisconnected: Bool {
        handleLock.lock(); defer { handleLock.unlock() }
        return handle.map { termo_ssh_session_is_disconnected($0) } ?? true
    }

    /// 仅用于网络切换等需要主动使整条连接失效的情况。
    public func disconnectTransport() {
        handleLock.lock(); defer { handleLock.unlock() }
        if let handle { termo_ssh_session_disconnect(handle) }
    }

    /// exec 一条命令，读回 stdout/stderr/退出码。
    public func exec(_ command: String, outCap: Int = 1 << 18, errCap: Int = 8192) throws -> ExecResult {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errout = [CChar](repeating: 0, count: errCap)
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = termo_ssh_exec(h, command, &out, Int32(outCap), &errout, Int32(errCap), &exitCode, &err, 256)
            if rc != 0 { throw SSHError(message: String(cString: err)) }
            return ExecResult(output: String(cString: out), stderr: String(cString: errout), exitCode: Int(exitCode))
        }
    }

    /// 二进制安全 exec（带 stdin/整体超时/可取消，**同步阻塞**，务必后台调用）。供 RemoteFS.run。
    /// 超时/取消不抛错（看返回的 timedOut/cancelled）；通道级错误抛 SSHError。
    public func execBytes(_ command: String, stdin: Data? = nil, timeout: Double,
                   outCap: Int = 1 << 20, errCap: Int = 1 << 16) throws -> ExecBytes {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            var out = [CChar](repeating: 0, count: outCap)
            var errb = [CChar](repeating: 0, count: errCap)
            var outLen: Int32 = 0, errLen: Int32 = 0, code: Int32 = 0
            var emsg = [CChar](repeating: 0, count: 256)
            let tmo = Int32((max(1, min(timeout, 86_400)) * 1000).rounded())
            let rc: Int32
            if let data = stdin, !data.isEmpty {
                rc = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    termo_ssh_exec2(h, command,
                                    raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count),
                                    &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                    &code, tmo, &emsg, 256)
                }
            } else {
                rc = termo_ssh_exec2(h, command, nil, 0,
                                     &out, Int32(outCap), &outLen, &errb, Int32(errCap), &errLen,
                                     &code, tmo, &emsg, 256)
            }
            if rc == -1 { throw SSHError(message: String(cString: emsg)) }
            let outData = Data(bytes: out, count: Int(outLen))
            let errData = Data(bytes: errb, count: Int(errLen))
            return ExecBytes(stdout: outData, stderr: errData, exitCode: code,
                             timedOut: rc == 1, cancelled: rc == 2)
        }
    }

    private final class ExecObserverBox {
        let callback: (Bool, Data) -> Void
        init(_ callback: @escaping (Bool, Data) -> Void) { self.callback = callback }
    }

    /// Non-PTY exec; drains both streams even after the consumer's display limit is reached.
    public func execObserved(_ command: String, timeout: Int,
                      onData: @escaping (Bool, Data) -> Void) throws -> ExecBytes {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            let box = Unmanaged.passRetained(ExecObserverBox(onData)).toOpaque()
            defer { Unmanaged<ExecObserverBox>.fromOpaque(box).release() }
            var code: Int32 = -1
            var error = [CChar](repeating: 0, count: 512)
            let rc = termo_ssh_exec_observed(h, command, { ud, isStderr, bytes, count in
                guard let ud, let bytes, count > 0 else { return }
                Unmanaged<ExecObserverBox>.fromOpaque(ud).takeUnretainedValue()
                    .callback(isStderr != 0, Data(bytes: bytes, count: Int(count)))
            }, box, &code, Int32(timeout * 1000), &error, 512)
            if rc == -1 { throw SSHError(message: String(cString: error)) }
            return ExecBytes(stdout: Data(), stderr: Data(), exitCode: code,
                             timedOut: rc == 1, cancelled: rc == 2)
        }
    }

    /// 流式上传 exec（替代 spawn ssh + cat）：pull 每次被调用填 buf（≤cap），返回写入字节 / 0=结束 / <0=取消。
    /// 返回 (rc, exitCode)：rc 0=完成 1=被取消 ；通道级错误抛 SSHError。**同步阻塞**，务必后台调用。
    private final class PullBox {
        let pull: (UnsafeMutablePointer<CChar>, Int32) -> Int32
        init(_ pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) { self.pull = pull }
    }
    public func execUpload(_ command: String,
                    pull: @escaping (UnsafeMutablePointer<CChar>, Int32) -> Int32) throws -> (rc: Int, exitCode: Int) {
        try queue.sync {
            guard let h = handle else { throw SSHError(message: String(localized: "会话已关闭")) }
            let box = Unmanaged.passRetained(PullBox(pull)).toOpaque()
            defer { Unmanaged<PullBox>.fromOpaque(box).release() }
            var exitCode: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            let rc = termo_ssh_exec_upload(h, command, { ud, buf, cap in
                guard let ud, let buf else { return -1 }
                return Unmanaged<PullBox>.fromOpaque(ud).takeUnretainedValue().pull(buf, cap)
            }, box, &exitCode, &err, 256)
            if rc == -1 { throw SSHError(message: String(cString: err)) }
            return (Int(rc), Int(exitCode))
        }
    }

    /// 流式 exec（**同步阻塞当前线程**直到 EOF/错误/被 cancel）。务必在专用后台线程调用：
    /// 同一操作句柄只跑一个流；其他操作通过 fork 独立开通道。onData 在后台线程回调。
    private final class DataBox { let onData: (Data) -> Void; init(_ f: @escaping (Data) -> Void) { onData = f } }
    public func execStream(_ command: String, onData: @escaping (Data) -> Void) {
        queue.sync {
            guard let h = handle else { return }
            let box = Unmanaged.passRetained(DataBox(onData)).toOpaque()
            defer { Unmanaged<DataBox>.fromOpaque(box).release() }
            var err = [CChar](repeating: 0, count: 256)
            termo_ssh_exec_stream(h, command, { ud, bytes, len in
                guard let ud, let bytes, len > 0 else { return }
                let cb = Unmanaged<DataBox>.fromOpaque(ud).takeUnretainedValue()
                cb.onData(Data(bytes: bytes, count: Int(len)))
            }, box, &err, 256)
        }
    }

    /// 只取消本操作；与关闭句柄互斥，避免读取已释放的 FFI 指针。
    public func cancel() {
        handleLock.lock(); defer { handleLock.unlock() }
        if let h = handle { termo_ssh_cancel(h) }
    }

    public var isPoisoned: Bool {
        handleLock.lock(); defer { handleLock.unlock() }
        return handle.map { termo_russh_session_is_poisoned($0) } ?? true
    }

    /// 底层 TermoSSHSession* 句柄，供 SFTP C 调用使用。仅在持有方自己的串行队列上读用（SFTP 持有独立操作句柄）。
    public var rawHandle: OpaquePointer? { handle }

    public func close() {
        cancel()
        let callback: (() -> Void)? = queue.sync {
            handleLock.lock(); defer { handleLock.unlock() }
            if let h = handle { termo_ssh_close(h); handle = nil }
            let callback = onClose
            onClose = nil
            return callback
        }
        callback?()
    }

    deinit { close() }
}
