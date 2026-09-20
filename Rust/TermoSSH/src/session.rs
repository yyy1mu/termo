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

use crate::handler::connect_and_auth;
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
        let (handle, fp_slot, forward_slot, host_info) = connect_and_auth(
            host,
            port,
            user,
            password,
            key_path,
            key_passphrase,
            timeout,
            policy,
        )
        .await?;
        let fingerprint = fp_slot.lock().expect("fingerprint mutex").clone();
        Ok(Self {
            inner: Arc::new(SessionInner {
                handle,
                forward_slot,
            }),
            fingerprint,
            host_info,
            fp_cstring: OnceLock::new(),
            md5_cstring: OnceLock::new(),
            cancelled: AtomicBool::new(false),
            poisoned: AtomicBool::new(false),
            current: Mutex::new(None),
        })
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
        self.poisoned.load(Ordering::SeqCst) || self.cancelled.load(Ordering::SeqCst)
    }

    /// 请求中止在飞 exec（可从任意线程调用；粘住：之后所有 exec 直接返回取消）。
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(handle) = self.current.lock().expect("exec slot").take() {
            handle.abort();
        }
    }

    /// exec 一条命令（异步版）。
    pub async fn exec2(&self, command: &str, stdin: Vec<u8>, timeout: Duration) -> ExecResult {
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
            let result = exec2_task(inner, command, stdin, timeout).await;
            let _ = tx.send(result);
        });
        *self.current.lock().expect("exec slot") = Some(task);
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

    /// 断开并释放（尽力而为，2s 内未完成则直接放弃等待）。
    pub fn close(&self) {
        let _ = runtime().block_on(async {
            tokio::time::timeout(
                Duration::from_secs(2),
                self.inner
                    .handle
                    .disconnect(Disconnect::ByApplication, "bye", "en"),
            )
            .await
        });
    }
}

/// exec2 任务体：开通道 → exec → （stdin → EOF）→ 抽干双流 → 收集退出码。
async fn exec2_task(
    inner: Arc<SessionInner>,
    command: String,
    stdin: Vec<u8>,
    timeout: Duration,
) -> ExecResult {
    let fut = async {
        let mut channel = inner
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
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
        while let Some(msg) = channel.wait().await {
            match msg {
                russh::ChannelMsg::Data { data } => stdout.extend(&data),
                russh::ChannelMsg::ExtendedData { ext: 1, data } => stderr.extend(&data),
                russh::ChannelMsg::ExtendedData { .. } => {}
                russh::ChannelMsg::ExitStatus { exit_status } => {
                    exit_code = Some(exit_status as i32);
                }
                _ => {}
            }
        }
        let _ = channel.close().await;
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
