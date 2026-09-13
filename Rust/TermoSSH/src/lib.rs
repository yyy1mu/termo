//! Rust SSH backend proof of concept (russh 0.63.3, ring backend).
//!
//! Milestones: backend version probe → connect/auth/exec probe → session +
//! exec2 (stdin/timeout/cancel) with libssh2-parity semantics. The production
//! libssh2 backend stays untouched until the russh adapters pass compatibility
//! tests.

mod ffi;
mod forward;
mod handler;
mod keys;
mod known_hosts;
mod scan;
mod session;
mod sftp;
mod shell;

use std::ffi::{c_char, CStr};

pub use forward::{ForwardKind, ForwardSpec, ForwardStateCallback, RusshForward};
pub use handler::HostPolicy;
pub use keys::{fingerprint_of_public, generate, pubkey_from_private, GeneratedKey, PubkeyDerive};
pub use scan::{scan_hostkey_blocking, ExecPullCallback, HostKeyScan};
pub use session::{clamp_timeout, ExecOutput, ExecResult, ProbeOutcome, RusshSession};
pub use sftp::{RusshSftp, RusshSftpFile, SftpAttrs, SftpOpError};
pub use shell::{RusshShell, ShellClosedCallback, ShellDataCallback};

/// 整个进程共用一个 multi-thread runtime，避免每条 SSH 连接各建一套调度器。
pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("build tokio runtime")
    })
}

/// 在共享 runtime 上阻塞执行一个 future（供 CLI 等非 runtime 线程使用；
/// 禁止在回调线程内调用——会与 runtime 冲突）。
pub fn block_on<T: std::future::Future>(fut: T) -> T::Output {
    runtime().block_on(fut)
}

/// 读入 C 字符串（NULL → 空串）。
///
/// # Safety
/// p 非 NULL 时须指向有效 NUL 结尾缓冲。
pub(crate) unsafe fn read_str(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        CStr::from_ptr(p).to_string_lossy().into_owned()
    }
}

/// 拷贝并 NUL 结尾；超长截断。dst 为 NULL 或 cap<=0 时忽略。
///
/// # Safety
/// dst 非 NULL 时须有 cap 字节可写。
pub(crate) unsafe fn copy_into(dst: *mut c_char, cap: i32, s: &str) {
    if dst.is_null() || cap <= 0 {
        return;
    }
    let bytes = s.as_bytes();
    let n = bytes.len().min(cap as usize - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, dst, n);
    *dst.add(n) = 0;
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

    #[test]
    fn bounded_extends_up_to_cap_and_drains_rest() {
        let mut b = session::testutil::bounded(4);
        b.extend(b"abcdef");
        assert_eq!(b.into_vec(), b"abcd");
    }

    #[test]
    fn timeout_clamps() {
        assert_eq!(
            session::clamp_timeout(0),
            std::time::Duration::from_millis(20_000)
        );
        assert_eq!(
            session::clamp_timeout(-5),
            std::time::Duration::from_millis(20_000)
        );
        assert_eq!(
            session::clamp_timeout(100),
            std::time::Duration::from_millis(1_000)
        );
        assert_eq!(
            session::clamp_timeout(i32::MAX),
            std::time::Duration::from_millis(24 * 60 * 60 * 1_000)
        );
    }
}
