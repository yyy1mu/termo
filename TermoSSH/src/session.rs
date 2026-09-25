//! 会话与 exec2：对标 libssh2 引擎 `termo_ssh_exec2` 的语义——
//! 二进制安全 stdout/stderr、可选 stdin（写完 send EOF）、上限截断但持续抽干、
//! 整体超时、跨线程取消（粘住）、超时/取消后会话失效（调用方应丢弃重建）。

use std::ffi::CString;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::Disconnect;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::runtime;

/// exec2 默认超时（与 libssh2 侧 20s 口径一致）；下限 1s、上限 24h（Swift 侧同口径）。
pub(crate) const DEFAULT_TIMEOUT_MS: i32 = 20_000;
/// exec2 默认输出上限（与 libssh2 版一致：stdout 1 MiB / stderr 64 KiB）。
const STDOUT_CAP: usize = 1024 * 1024;
const STDERR_CAP: usize = 64 * 1024;
const TIMEOUT_MIN_MS: i64 = 1_000;
const TIMEOUT_MAX_MS: i64 = 24 * 60 * 60 * 1_000;

pub fn clamp_timeout(timeout_ms: i32) -> Duration {
    let ms = if timeout_ms <= 0 {
        i64::from(DEFAULT_TIMEOUT_MS)
    } else {
        i64::from(timeout_ms)
    };
    Duration::from_millis(ms.clamp(TIMEOUT_MIN_MS, TIMEOUT_MAX_MS) as u64)
}

/// 有上限的缓冲：写满后继续「抽干」但不累积（避免远端写阻塞导致永不 EOF）。
#[derive(Debug, Default)]
pub(crate) struct Bounded {
    buf: Vec<u8>,
    cap: usize,
}

impl Bounded {
    pub(crate) fn new(cap: usize) -> Self {
        Self {
            buf: Vec::new(),
            cap,
        }
    }

    pub(crate) fn extend(&mut self, bytes: &[u8]) {
        let room = self.cap.saturating_sub(self.buf.len());
        self.buf.extend_from_slice(&bytes[..bytes.len().min(room)]);
    }

    pub(crate) fn into_vec(self) -> Vec<u8> {
        self.buf
    }
}

/// exec2 结果状态：0=完成、1=超时、2=被取消、-1=错误（与 C ABI 返回值同义）。
#[derive(Debug)]
pub enum ExecResult {
    /// 完成：输出与退出码见 `ExecOutput`。
    Done(ExecOutput),
    /// 整体超时（会话已失效，应丢弃重建）。
    Timeout,
    /// 被取消（会话已失效，应丢弃重建）。
    Cancelled,
    /// 通道/协议错误（会话可用性未定，保守起见也应重建）。
    Error(String),
}

/// exec2 输出（二进制安全，可能被上限截断——与 libssh2 版一致）。
#[derive(Debug)]
pub struct ExecOutput {
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    /// 无 exit-status（如被信号杀死）时为 None。
    pub exit_code: Option<i32>,
}

pub(crate) struct SessionInner {
    pub(crate) handle: russh::client::Handle<crate::handler::ProbeHandler>,
    owners: Mutex<usize>,
    /// -R 转发路由槽（forward_open 安装/摘除）。
    pub(crate) forward_slot: Arc<crate::handler::ForwardSlot>,
}

// forward 模块经 SessionInner 访问会话内部（Arc 共享）。
impl RusshSession {
    pub(crate) fn inner(&self) -> &Arc<SessionInner> {
        &self.inner
    }
}

impl SessionInner {
    /// 会话是否已断开（转发监督轮询用）。
    pub(crate) fn is_dead(&self) -> bool {
        self.handle.is_closed()
    }
}

impl SessionInner {
    /// 在该会话上开一个 session channel（shell 等模块复用）。
    pub(crate) async fn channel_open(
        inner: &RusshSession,
    ) -> Result<russh::Channel<russh::client::Msg>, russh::Error> {
        inner.inner.handle.channel_open_session().await
    }
}

/// 已认证的 russh 会话句柄（对应 libssh2 侧 `TermoSSHSession*`）。
pub struct RusshSession {
    inner: Arc<SessionInner>,
    fingerprint: Option<String>,
    host_info: Arc<crate::handler::HostKeyInfo>,
    /// C ABI 侧返回的稳定指针载体（close 前有效）。
    fp_cstring: OnceLock<CString>,
    md5_cstring: OnceLock<CString>,
    cancelled: AtomicBool,
    closed: AtomicBool,
    cancel_signal: tokio::sync::watch::Sender<bool>,
    poisoned: AtomicBool,
    /// 在飞的 exec 任务（同一会话约定单飞行；Swift 侧本就按会话串行）。
    current: Mutex<Option<JoinHandle<()>>>,
}

impl RusshSession {
    /// 连接 + 握手 + 认证。key_path 非空走公钥认证，否则密码认证。
    #[allow(clippy::too_many_arguments)] // 参数与 libssh2 C ABI 对齐
    pub async fn connect(
        host: &str,
        port: u16,
        user: &str,
        password: Option<&str>,
        key_path: Option<&str>,
        key_passphrase: Option<&str>,
        timeout: Duration,
        policy: Option<crate::handler::HostPolicy>,
    ) -> Result<Self, String> {
        let options = crate::options::ConnectionOptions {
            timeout,
            ..Default::default()
        };
        Self::connect_configured(
            host,
            port,
            user,
            password,
            key_path,
            key_passphrase,
            policy,
            &options,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn connect_configured(
        host: &str,
        port: u16,
        user: &str,
        password: Option<&str>,
        key_path: Option<&str>,
        key_passphrase: Option<&str>,
        policy: Option<crate::handler::HostPolicy>,
        options: &crate::options::ConnectionOptions,
    ) -> Result<Self, String> {
        let (handle, fp_slot, forward_slot, host_info) =
            crate::handler::connect_and_auth_configured(
                host,
                port,
                user,
                password,
                key_path,
                key_passphrase,
                policy,
                options,
            )
            .await?;
        let fingerprint = fp_slot.lock().expect("fingerprint mutex").clone();
        Ok(Self {
            inner: Arc::new(SessionInner {
                handle,
                owners: Mutex::new(1),
                forward_slot,
            }),
            fingerprint,
            host_info,
            fp_cstring: OnceLock::new(),
            md5_cstring: OnceLock::new(),
            cancelled: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            cancel_signal: tokio::sync::watch::channel(false).0,
            poisoned: AtomicBool::new(false),
            current: Mutex::new(None),
        })
    }

    /// Share an authenticated transport, with independent exec/cancellation state.
    /// Fork and last-owner close use the same lock, so a closed transport cannot be resurrected.
    pub fn fork(&self) -> Result<Self, String> {
        let mut owners = self.inner.owners.lock().expect("transport owners");
        if self.is_poisoned() {
            return Err("SSH 连接已关闭或失效".into());
        }
        *owners += 1;
        Ok(Self {
            inner: Arc::clone(&self.inner),
            fingerprint: self.fingerprint.clone(),
            host_info: Arc::clone(&self.host_info),
            fp_cstring: OnceLock::new(),
            md5_cstring: OnceLock::new(),
            cancelled: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            cancel_signal: tokio::sync::watch::channel(false).0,
            poisoned: AtomicBool::new(false),
            current: Mutex::new(None),
        })
    }

    pub fn is_disconnected(&self) -> bool {
        self.inner.is_dead()
    }

    pub(crate) async fn wait_cancelled(&self) {
        let mut receiver = self.cancel_signal.subscribe();
        if !*receiver.borrow_and_update() {
            let _ = receiver.changed().await;
        }
    }

    /// 主机指纹（"SHA256:…"），握手后即可用。
    pub fn fingerprint(&self) -> Option<&str> {
        self.fingerprint.as_deref()
    }

    /// 指纹的稳定 C 字符串（close 前有效；无指纹则空串）。
    pub(crate) fn fingerprint_cstring(&self) -> &CString {
        self.fp_cstring.get_or_init(|| {
            CString::new(self.fingerprint.clone().unwrap_or_default()).unwrap_or_default()
        })
    }

    /// MD5 指纹的稳定 C 字符串（close 前有效）。
    pub(crate) fn md5_cstring(&self) -> &CString {
        self.md5_cstring.get_or_init(|| {
            CString::new(self.host_info.md5.lock().expect("md5").clone()).unwrap_or_default()
        })
    }

    /// 会话是否已失效（超时/取消后粘住）。失效会话不可复用，应丢弃重建。
    pub fn is_poisoned(&self) -> bool {
        self.poisoned.load(Ordering::SeqCst)
            || self.cancelled.load(Ordering::SeqCst)
            || self.closed.load(Ordering::SeqCst)
            || self.is_disconnected()
    }

    /// 请求中止在飞 exec（可从任意线程调用；粘住：之后所有 exec 直接返回取消）。
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.cancel_signal.send_replace(true);
        if let Some(handle) = self.current.lock().expect("exec slot").take() {
            handle.abort();
        }
    }

    /// exec 一条命令（异步版）。
    pub async fn exec2(&self, command: &str, stdin: Vec<u8>, timeout: Duration) -> ExecResult {
        self.exec_observed(command, stdin, timeout, None).await
    }

    pub async fn exec_observed(
        &self,
        command: &str,
        stdin: Vec<u8>,
        timeout: Duration,
        observer: Option<ExecObserver>,
    ) -> ExecResult {
        if self.cancelled.load(Ordering::SeqCst) {
            return ExecResult::Cancelled;
        }
        if self.poisoned.load(Ordering::SeqCst) {
            return ExecResult::Error("会话已失效（超时/取消后请重建）".into());
        }
        let (tx, rx) = oneshot::channel();
        let inner = Arc::clone(&self.inner);
        let command = command.to_string();
        let task = runtime().spawn(async move {
            let result = exec2_task(inner, command, stdin, timeout, observer).await;
            let _ = tx.send(result);
        });
        {
            let mut slot = self.current.lock().expect("exec slot");
            if self.cancelled.load(Ordering::SeqCst) {
                task.abort();
                return ExecResult::Cancelled;
            }
            *slot = Some(task);
        }
        match rx.await {
            Ok(result @ ExecResult::Timeout) => {
                self.poisoned.store(true, Ordering::SeqCst);
                result
            }
            Ok(result) => result,
            // tx 被丢弃 = 任务被 abort（cancel）或 panic；按取消处理并粘住失效。
            Err(_) => {
                self.poisoned.store(true, Ordering::SeqCst);
                ExecResult::Cancelled
            }
        }
    }

    /// exec 一条命令（阻塞版，供 C ABI / CLI 使用；阻塞调用线程而非 runtime worker）。
    pub fn exec2_blocking(&self, command: &str, stdin: Vec<u8>, timeout: Duration) -> ExecResult {
        runtime().block_on(self.exec2(command, stdin, timeout))
    }

    /// 阻塞建立会话（供 C ABI / CLI；整体超时 + panic 隔离）。
    #[allow(clippy::too_many_arguments)] // 参数与 libssh2 C ABI 对齐
    pub fn connect_blocking(
        host: &str,
        port: u16,
        user: &str,
        password: Option<&str>,
        key_path: Option<&str>,
        key_passphrase: Option<&str>,
        timeout: Duration,
        policy: Option<crate::handler::HostPolicy>,
    ) -> Result<Self, String> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            runtime().block_on(Self::connect(
                host,
                port,
                user,
                password,
                key_path,
                key_passphrase,
                timeout,
                policy,
            ))
        }))
        .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
    }

    /// 阻塞开转发（供 C ABI / CLI；panic 隔离）。
    pub fn forward_open_blocking(
        &self,
        spec: crate::forward::ForwardSpec,
        on_state: crate::forward::ForwardStateCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<crate::forward::RusshForward, String> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            runtime().block_on(self.forward_open(spec, on_state, userdata))
        }))
        .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
    }

    /// 阻塞开 PTY shell（供 C ABI / CLI；panic 隔离）。command 非空则 PTY+exec 该命令。
    pub fn shell_open_blocking(
        &self,
        cols: i32,
        rows: i32,
        command: Option<String>,
        on_data: crate::shell::ShellDataCallback,
        on_closed: crate::shell::ShellClosedCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<crate::shell::RusshShell, String> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            runtime().block_on(self.shell_open(cols, rows, command, on_data, on_closed, userdata))
        }))
        .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
    }

    /// Only the last operation owner disconnects the shared transport.
    pub fn close(&self) {
        let last = {
            let mut owners = self.inner.owners.lock().expect("transport owners");
            if self.closed.swap(true, Ordering::SeqCst) {
                return;
            }
            *owners -= 1;
            *owners == 0
        };
        self.cancel();
        if last {
            self.disconnect();
        }
    }

    /// Explicit transport invalidation, used for network changes only.
    pub fn disconnect(&self) {
        let inner = Arc::clone(&self.inner);
        runtime().spawn(async move {
            let _ = tokio::time::timeout(
                Duration::from_secs(2),
                inner
                    .handle
                    .disconnect(Disconnect::ByApplication, "bye", "en"),
            )
            .await;
        });
    }
}

impl Drop for RusshSession {
    fn drop(&mut self) {
        self.close();
    }
}

/// Closing an operation must release its remote channel even when its future is aborted.
struct ExecChannelGuard(Option<Arc<russh::ChannelWriteHalf<russh::client::Msg>>>);
impl Drop for ExecChannelGuard {
    fn drop(&mut self) {
        if let Some(channel) = self.0.take() {
            runtime().spawn(async move {
                let _ = tokio::time::timeout(Duration::from_secs(2), async {
                    let _ = channel.signal(russh::Sig::TERM).await;
                    let _ = channel.close().await;
                })
                .await;
            });
        }
    }
}

pub type ExecObserver = Arc<dyn Fn(bool, &[u8]) + Send + Sync>;

/// exec2 任务体：开通道 → exec → （stdin → EOF）→ 抽干双流 → 收集退出码。
async fn exec2_task(
    inner: Arc<SessionInner>,
    command: String,
    stdin: Vec<u8>,
    timeout: Duration,
    observer: Option<ExecObserver>,
) -> ExecResult {
    let fut = async {
        let channel = inner
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
        let (mut reader, writer) = channel.split();
        let channel = Arc::new(writer);
        let mut cleanup = ExecChannelGuard(Some(Arc::clone(&channel)));
        channel
            .exec(true, command.as_str())
            .await
            .map_err(|e| format!("exec 失败: {e}"))?;
        if !stdin.is_empty() {
            // &[u8] 实现 AsyncRead：一次写入全部 stdin。
            channel
                .data(stdin.as_slice())
                .await
                .map_err(|e| format!("stdin 写入失败: {e}"))?;
        }
        // 无论是否有 stdin 都 send EOF（对齐 OpenSSH 关闭 stdin 的行为）：
        // 否则远端后台任务场景下 sshd 不关通道，exec 永不 EOF。
        channel.eof().await.map_err(|e| format!("EOF 失败: {e}"))?;

        let mut stdout = Bounded::new(STDOUT_CAP);
        let mut stderr = Bounded::new(STDERR_CAP);
        let mut exit_code = None;
        while let Some(msg) = reader.wait().await {
            match msg {
                russh::ChannelMsg::Data { data } => {
                    if let Some(ref observe) = observer {
                        observe(false, &data);
                    }
                    stdout.extend(&data);
                }
                russh::ChannelMsg::ExtendedData { ext: 1, data } => {
                    if let Some(ref observe) = observer {
                        observe(true, &data);
                    }
                    stderr.extend(&data);
                }
                russh::ChannelMsg::ExtendedData { .. } => {}
                russh::ChannelMsg::ExitStatus { exit_status } => {
                    exit_code = Some(exit_status as i32);
                }
                _ => {}
            }
        }
        let _ = channel.close().await;
        cleanup.0 = None;
        Ok(ExecOutput {
            stdout: stdout.into_vec(),
            stderr: stderr.into_vec(),
            exit_code,
        })
    };
    match tokio::time::timeout(timeout, fut).await {
        Ok(Ok(output)) => ExecResult::Done(output),
        Ok(Err(message)) => ExecResult::Error(message),
        Err(_) => ExecResult::Timeout,
    }
}

#[cfg(test)]
pub(crate) mod testutil {
    use super::Bounded;

    pub(crate) fn bounded(cap: usize) -> Bounded {
        Bounded::new(cap)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_cap_zero_keeps_nothing() {
        let mut b = Bounded::new(0);
        b.extend(b"data");
        assert_eq!(b.into_vec(), b"");
    }
}

// ── 探针（复用会话路径；供 CLI 快速回归）────────────────────────────────────

/// 探针结果：主机指纹（"SHA256:…"）与远端 `true` 的退出码。
#[derive(Debug)]
pub struct ProbeOutcome {
    pub fingerprint: Option<String>,
    pub exit_code: i32,
}

/// 连接 + 认证 + exec `true`。超时/取消/错误统一为 Err（认证被拒文案不变）。
pub async fn probe(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    key_path: Option<&str>,
    key_passphrase: Option<&str>,
    timeout: Duration,
) -> Result<ProbeOutcome, String> {
    let session = RusshSession::connect(
        host,
        port,
        user,
        password,
        key_path,
        key_passphrase,
        timeout,
        None,
    )
    .await?;
    let fingerprint = session.fingerprint().map(str::to_owned);
    let result = session.exec2("true", Vec::new(), timeout).await;
    session.close();
    match result {
        ExecResult::Done(output) => Ok(ProbeOutcome {
            fingerprint,
            exit_code: output.exit_code.unwrap_or(-1),
        }),
        ExecResult::Timeout => Err("连接超时".into()),
        ExecResult::Cancelled => Err("已取消".into()),
        ExecResult::Error(message) => Err(message),
    }
}

/// 阻塞版探针：共享 runtime + 整体超时 + panic 隔离（C ABI 与 CLI 共用）。
pub fn probe_blocking(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    key_path: Option<&str>,
    key_passphrase: Option<&str>,
    timeout_ms: i32,
) -> Result<ProbeOutcome, String> {
    let timeout = clamp_timeout(timeout_ms);
    let fut = probe(
        host,
        port,
        user,
        password,
        key_path,
        key_passphrase,
        timeout,
    );
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| runtime().block_on(fut)))
        .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
}

#[cfg(test)]
mod sharing_tests {
    use super::*;
    use russh::server::{self, Server as _};
    use std::sync::atomic::AtomicUsize;

    #[derive(Clone)]
    struct Server(Arc<AtomicUsize>);
    impl server::Server for Server {
        type Handler = Self;
        fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
            self.clone()
        }
    }
    impl server::Handler for Server {
        type Error = russh::Error;
        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(server::Auth::Accept)
        }
        async fn channel_open_session(
            &mut self,
            _: russh::Channel<server::Msg>,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            reply.accept().await;
            Ok(())
        }
        async fn channel_open_direct_tcpip(
            &mut self,
            _: russh::Channel<server::Msg>,
            _: &str,
            _: u32,
            _: &str,
            _: u32,
            reply: server::ChannelOpenHandle,
            _: &mut server::Session,
        ) -> Result<(), Self::Error> {
            reply.accept().await;
            Ok(())
        }
        async fn exec_request(
            &mut self,
            id: russh::ChannelId,
            command: &[u8],
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            session.channel_success(id)?;
            if command == b"stall" {
                return Ok(());
            }
            session.data(id, b"sample".as_slice())?;
            if command == b"observed" {
                session.extended_data(id, 1, b"warning".as_slice())?;
            }
            if command != b"stream" {
                if command != b"no-exit" {
                    session.exit_status_request(id, if command == b"observed" { 7 } else { 0 })?;
                }
                session.eof(id)?;
                session.close(id)?;
            }
            Ok(())
        }
        async fn pty_request(
            &mut self,
            id: russh::ChannelId,
            _: &str,
            _: u32,
            _: u32,
            _: u32,
            _: u32,
            _: &[(russh::Pty, u32)],
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            session.channel_success(id)
        }
        async fn shell_request(
            &mut self,
            id: russh::ChannelId,
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            session.channel_success(id)
        }
        async fn data(
            &mut self,
            id: russh::ChannelId,
            data: &[u8],
            session: &mut server::Session,
        ) -> Result<(), Self::Error> {
            session.data(id, data.to_vec())
        }
    }

    unsafe extern "C" fn count_data(
        ud: *mut std::ffi::c_void,
        _: *const std::ffi::c_char,
        len: i32,
    ) {
        (*(ud as *const AtomicUsize)).fetch_add(len as usize, Ordering::SeqCst);
    }
    unsafe extern "C" fn shell_closed(_: *mut std::ffi::c_void, _: i32) {}
    unsafe extern "C" fn forward_state(
        _: *mut std::ffi::c_void,
        _: i32,
        _: *const std::ffi::c_char,
    ) {
    }
    async fn open_forward(
        session: &RusshSession,
    ) -> (crate::forward::RusshForward, tokio::net::TcpStream) {
        let socket = tokio::net::TcpListener::bind(("127.0.0.1", 0))
            .await
            .unwrap();
        let port = socket.local_addr().unwrap().port();
        drop(socket);
        let forward = session
            .forward_open(
                crate::forward::ForwardSpec {
                    kind: crate::forward::ForwardKind::Local,
                    bind_addr: "127.0.0.1".into(),
                    listen_port: port,
                    dest_host: "fixture".into(),
                    dest_port: 22,
                },
                forward_state,
                std::ptr::null_mut(),
            )
            .await
            .unwrap();
        let socket = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        (forward, socket)
    }
    async fn echo(socket: &mut tokio::net::TcpStream) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        tokio::time::timeout(Duration::from_secs(3), async {
            socket.write_all(b"hello").await.unwrap();
            let mut bytes = [0; 5];
            socket.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes, b"hello");
        })
        .await
        .expect("forward output");
    }
    async fn received(count: &AtomicUsize, minimum: usize) {
        tokio::time::timeout(Duration::from_secs(3), async {
            while count.load(Ordering::SeqCst) < minimum {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("channel output");
    }

    #[test]
    fn monitor_terminal_and_commands_share_auth_but_not_cancellation() {
        runtime().block_on(async {
            let key =
                russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)
                    .unwrap();
            let public = key.public_key().to_openssh().unwrap();
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let port = listener.local_addr().unwrap().port();
            let auths = Arc::new(AtomicUsize::new(0));
            let mut server = Server(auths.clone());
            let config = Arc::new(server::Config {
                keys: vec![key],
                auth_rejection_time: Duration::ZERO,
                ..Default::default()
            });
            let serving =
                tokio::spawn(async move { server.run_on_socket(config, &listener).await });
            let directory =
                std::env::temp_dir().join(format!("termo-sharing-{}-{port}", std::process::id()));
            std::fs::create_dir(&directory).unwrap();
            let known = directory.join("known_hosts");
            std::fs::write(&known, format!("[127.0.0.1]:{port} {public}\n")).unwrap();
            let root = RusshSession::connect(
                "127.0.0.1",
                port,
                "fixture",
                Some("fixture-only"),
                None,
                None,
                Duration::from_secs(5),
                Some(crate::handler::HostPolicy {
                    host: "127.0.0.1".into(),
                    port,
                    real_known_hosts: known.to_str().unwrap().into(),
                    session_known_hosts: directory.join("session").to_str().unwrap().into(),
                }),
            )
            .await
            .unwrap();
            let monitor = Arc::new(root.fork().unwrap());
            let terminal = root.fork().unwrap();
            let chunks = Arc::new(AtomicUsize::new(0));
            let stream_owner = monitor.clone();
            let stream_chunks = chunks.clone();
            let stream = std::thread::spawn(move || {
                runtime()
                    .block_on(stream_owner.exec_stream(
                        "stream",
                        count_data,
                        Arc::as_ptr(&stream_chunks) as *mut std::ffi::c_void,
                    ))
                    .unwrap();
            });
            received(&chunks, 1).await;
            let echoed = AtomicUsize::new(0);
            let shell = terminal
                .shell_open(
                    80,
                    24,
                    None,
                    count_data,
                    shell_closed,
                    &echoed as *const _ as *mut std::ffi::c_void,
                )
                .await
                .unwrap();
            root.close();
            assert!(root.fork().is_err());
            monitor.cancel();
            tokio::time::timeout(
                Duration::from_secs(3),
                tokio::task::spawn_blocking(move || stream.join().unwrap()),
            )
            .await
            .expect("monitor cancellation did not stop the stream")
            .unwrap();
            monitor.close();
            assert!(!terminal.is_poisoned());
            assert_eq!(shell.write(b"hello"), 5);
            received(&echoed, 5).await;

            let command = terminal.fork().unwrap();
            assert!(matches!(
                command
                    .exec2("stall", Vec::new(), Duration::from_millis(30))
                    .await,
                ExecResult::Timeout
            ));
            assert!(command.is_poisoned());
            command.close();
            assert!(!terminal.is_poisoned());
            let next = terminal.fork().unwrap();
            assert!(matches!(
                next.exec2("ok", Vec::new(), Duration::from_secs(2)).await,
                ExecResult::Done(_)
            ));
            next.close();
            let observed = terminal.fork().unwrap();
            let output = Arc::new(Mutex::new((Vec::<u8>::new(), Vec::<u8>::new())));
            let observed_output = output.clone();
            let result = observed
                .exec_observed(
                    "observed",
                    Vec::new(),
                    Duration::from_secs(2),
                    Some(Arc::new(move |stderr, bytes| {
                        let mut streams = observed_output.lock().unwrap();
                        if stderr {
                            streams.1.extend_from_slice(bytes);
                        } else {
                            streams.0.extend_from_slice(bytes);
                        }
                    })),
                )
                .await;
            match result {
                ExecResult::Done(value) => assert_eq!(value.exit_code, Some(7)),
                _ => panic!("missing observed result"),
            }
            assert_eq!(output.lock().unwrap().0, b"sample");
            assert_eq!(output.lock().unwrap().1, b"warning");
            observed.close();
            let partial = terminal.fork().unwrap();
            let chunks = Arc::new(AtomicUsize::new(0));
            let count = chunks.clone();
            assert!(matches!(
                partial
                    .exec_observed(
                        "stream",
                        Vec::new(),
                        Duration::from_millis(150),
                        Some(Arc::new(move |_, bytes| {
                            count.fetch_add(bytes.len(), Ordering::SeqCst);
                        }))
                    )
                    .await,
                ExecResult::Timeout
            ));
            assert_eq!(
                chunks.load(Ordering::SeqCst),
                6,
                "retain output before timeout"
            );
            partial.close();
            let no_exit = terminal.fork().unwrap();
            match no_exit
                .exec2("no-exit", Vec::new(), Duration::from_secs(2))
                .await
            {
                ExecResult::Done(value) => assert_eq!(value.exit_code, None),
                _ => panic!("missing channel-close result"),
            }
            no_exit.close();
            // Cancelling before stream setup must also be immediate and local.
            let stopped = terminal.fork().unwrap();
            stopped.cancel();
            assert!(tokio::time::timeout(
                Duration::from_millis(100),
                stopped.exec_stream(
                    "stream",
                    count_data,
                    &echoed as *const _ as *mut std::ffi::c_void
                )
            )
            .await
            .unwrap()
            .is_err());
            stopped.close();
            assert_eq!(shell.write(b"again"), 5);
            received(&echoed, 10).await;
            // Stopping one tunnel closes its live sockets, without touching siblings or shell.
            let first = terminal.fork().unwrap();
            let second = terminal.fork().unwrap();
            let (forward_a, mut socket_a) = open_forward(&first).await;
            let (forward_b, mut socket_b) = open_forward(&second).await;
            echo(&mut socket_a).await;
            echo(&mut socket_b).await;
            tokio::task::spawn_blocking(move || forward_a.close())
                .await
                .unwrap();
            first.close();
            use tokio::io::AsyncReadExt;
            let end = tokio::time::timeout(Duration::from_secs(3), socket_a.read(&mut [0; 1]))
                .await
                .unwrap();
            assert!(matches!(end, Ok(0)) || end.is_err());
            echo(&mut socket_b).await;
            assert_eq!(shell.write(b"alive"), 5);
            received(&echoed, 15).await;
            tokio::task::spawn_blocking(move || forward_b.close())
                .await
                .unwrap();
            second.close();
            assert_eq!(auths.load(Ordering::SeqCst), 1);
            shell.close();
            terminal.close();
            tokio::time::timeout(Duration::from_secs(3), async {
                while !terminal.is_disconnected() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("last owner should disconnect");
            serving.abort();
            let _ = serving.await;
            std::fs::remove_dir_all(directory).unwrap();
        });
    }
}
