//! Rust SSH backend proof of concept (russh 0.63.3, ring backend).
//!
//! Milestone 1: version probe + blocking connect/auth/exec probe behind a
//! stable C ABI. The production libssh2 backend stays untouched until the
//! russh adapters pass compatibility tests.

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};
use russh::Disconnect;

/// 默认探针超时（与 libssh2 侧 termo_ssh_exec2 的 20s 口径一致）。
const DEFAULT_TIMEOUT_MS: i32 = 20_000;

// ── 共享 Tokio runtime ─────────────────────────────────────────────────────
// 整个进程共用一个 multi-thread runtime，避免每条 SSH 连接各建一套调度器。

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}

// ── 连接处理器：记录主机指纹 ───────────────────────────────────────────────
// PoC 阶段对未知主机一律放行（与现有 libssh2 引擎的保守口径一致），
// 但把指纹带回给调用方；信任策略（known_hosts / 弹窗）后续在 Swift 侧接入。

#[derive(Debug, Default)]
struct ProbeHandler {
    fingerprint: Arc<Mutex<Option<String>>>,
}

impl client::Handler for ProbeHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let fp = match server_public_key {
            russh::keys::PublicKeyOrCertificate::PublicKey { key, .. } => {
                key.fingerprint(HashAlg::Sha256).to_string()
            }
            russh::keys::PublicKeyOrCertificate::Certificate(cert) => {
                cert.public_key().fingerprint(HashAlg::Sha256).to_string()
            }
        };
        *self.fingerprint.lock().expect("fingerprint mutex") = Some(fp);
        Ok(true)
    }
}

/// 探针结果：主机指纹（"SHA256:…"）与远端 `true` 的退出码。
#[derive(Debug)]
pub struct ProbeOutcome {
    pub fingerprint: Option<String>,
    pub exit_code: i32,
}

fn ensure_auth(result: AuthResult) -> Result<(), String> {
    match result {
        AuthResult::Success => Ok(()),
        AuthResult::Failure { .. } => Err("认证被拒绝".into()),
    }
}

/// 连接 + 认证 + exec `true`（异步部分；由 probe_blocking 包装超时与 panic 隔离）。
async fn probe(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    key_path: Option<&str>,
    key_passphrase: Option<&str>,
) -> Result<ProbeOutcome, String> {
    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        nodelay: true,
        ..client::Config::default()
    });
    let handler = ProbeHandler::default();
    let fingerprint = handler.fingerprint.clone();

    let mut handle: Handle<ProbeHandler> =
        client::connect(config, format!("{host}:{port}"), handler)
            .await
            .map_err(|e| format!("连接失败: {e}"))?;

    if let Some(path) = key_path.filter(|p| !p.is_empty()) {
        let key = russh::keys::load_secret_key(path, key_passphrase.filter(|p| !p.is_empty()))
            .map_err(|e| format!("私钥加载失败: {e}"))?;
        // RSA 按 server-sig-algs 协商最佳哈希；Ed25519 等忽略该值。
        let hash = handle
            .best_supported_rsa_hash()
            .await
            .ok()
            .flatten()
            .flatten();
        let auth = handle
            .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
            .await
            .map_err(|e| format!("公钥认证失败: {e}"))?;
        ensure_auth(auth)?;
    } else {
        let auth = handle
            .authenticate_password(user, password.unwrap_or_default())
            .await
            .map_err(|e| format!("密码认证失败: {e}"))?;
        ensure_auth(auth)?;
    }

    let mut channel = handle
        .channel_open_session()
        .await
        .map_err(|e| format!("通道打开失败: {e}"))?;
    channel
        .exec(true, "true")
        .await
        .map_err(|e| format!("exec 失败: {e}"))?;

    let mut exit_code = -1;
    while let Some(msg) = channel.wait().await {
        if let russh::ChannelMsg::ExitStatus { exit_status } = msg {
            exit_code = exit_status as i32;
        }
    }
    let _ = handle
        .disconnect(Disconnect::ByApplication, "probe done", "en")
        .await;

    let fp = fingerprint.lock().expect("fingerprint mutex").clone();
    Ok(ProbeOutcome {
        fingerprint: fp,
        exit_code,
    })
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
    let timeout = Duration::from_millis(timeout_ms.clamp(1_000, 86_400_000) as u64);
    let fut = probe(host, port, user, password, key_path, key_passphrase);
    catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(async {
            match tokio::time::timeout(timeout, fut).await {
                Ok(result) => result,
                Err(_) => Err("连接超时".into()),
            }
        })
    }))
    .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
}

// ── C ABI 辅助：读入 / 写出 C 字符串 ────────────────────────────────────────

unsafe fn read_str(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

/// 拷贝并 NUL 结尾；超长截断。dst 为 NULL 或 cap<=0 时忽略。
unsafe fn copy_into(dst: *mut c_char, cap: i32, s: &str) {
    if dst.is_null() || cap <= 0 {
        return;
    }
    let bytes = s.as_bytes();
    let n = bytes.len().min(cap as usize - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, dst, n);
    *dst.add(n) = 0;
}

// ── C ABI ──────────────────────────────────────────────────────────────────

/// 返回 russh 后端版本（静态字符串，调用方勿释放）。
#[no_mangle]
pub extern "C" fn termo_russh_backend_version() -> *const c_char {
    c"russh-0.63.3".as_ptr()
}

/// 连接/认证/exec 探针。key_path 非空走公钥认证，否则密码认证。
/// 返回：0=成功（指纹/退出码已写回）、1=认证被拒绝、-1=错误（err 写原因）。
/// 指纹形如 "SHA256:base64"（截断到 fingerprint_cap-1）。超时 ms ≤0 用 20s。
///
/// # Safety
/// 所有字符串指针须指向有效的 NUL 结尾缓冲；fingerprint_out/err 需保证
/// fingerprint_cap/errlen 字节可写（可为 NULL）；exit_code_out 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_probe(
    host: *const c_char,
    port: i32,
    user: *const c_char,
    password: *const c_char,
    key_path: *const c_char,
    key_passphrase: *const c_char,
    fingerprint_out: *mut c_char,
    fingerprint_cap: i32,
    exit_code_out: *mut i32,
    timeout_ms: i32,
    err: *mut c_char,
    errlen: i32,
) -> i32 {
    let host = read_str(host);
    let user = read_str(user);
    let password = read_str(password);
    let key_path = read_str(key_path);
    let key_passphrase = read_str(key_passphrase);
    if host.is_empty() || user.is_empty() || !(1..=65535).contains(&port) {
        copy_into(err, errlen, "参数无效（host/user 为空或端口越界）");
        return -1;
    }
    let timeout = if timeout_ms <= 0 {
        DEFAULT_TIMEOUT_MS
    } else {
        timeout_ms
    };
    let pass = (!password.is_empty()).then_some(password.as_str());
    let key = (!key_path.is_empty()).then_some(key_path.as_str());
    let key_pass = (!key_passphrase.is_empty()).then_some(key_passphrase.as_str());

    match probe_blocking(&host, port as u16, &user, pass, key, key_pass, timeout) {
        Ok(outcome) => {
            if let Some(fp) = outcome.fingerprint.as_deref() {
                copy_into(fingerprint_out, fingerprint_cap, fp);
            }
            if !exit_code_out.is_null() {
                *exit_code_out = outcome.exit_code;
            }
            0
        }
        Err(message) => {
            let rejected = message == "认证被拒绝";
            copy_into(err, errlen, &message);
            if rejected {
                1
            } else {
                -1
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_into_truncates_and_terminates() {
        let mut buf = [0 as c_char; 8];
        unsafe { copy_into(buf.as_mut_ptr(), buf.len() as i32, "SHA256:abcdefghijk") };
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy();
        assert_eq!(s, "SHA256:");
    }

    #[test]
    fn copy_into_ignores_invalid_dst() {
        unsafe { copy_into(std::ptr::null_mut(), 16, "x") };
    }
}
