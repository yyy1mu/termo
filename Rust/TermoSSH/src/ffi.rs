//! C ABI：版本探针、连接探针、会话句柄（open/exec2/cancel/sha256/close）。
//!
//! 约定与 libssh2 引擎一致：缓冲超长截断且 NUL 结尾（exec2 的 out/errout 为
//! 二进制安全、按 *out_len/*err_len 取用）；返回值不抛 panic（catch_unwind 拦截）。

use std::ffi::c_char;

use crate::session::{clamp_timeout, ExecResult, RusshSession};
use crate::{copy_into, read_str, runtime};

/// 返回 russh 后端版本（静态字符串，调用方勿释放）。
#[no_mangle]
pub extern "C" fn termo_russh_backend_version() -> *const c_char {
    c"russh-0.63.3".as_ptr()
}

/// 连接/认证/exec 探针（一次性；不复用会话）。
/// 返回：0=成功、1=认证被拒绝、-1=错误（err 写原因）。
///
/// # Safety
/// 字符串指针须指向有效 NUL 结尾缓冲；fingerprint_out/err 可为 NULL，
/// 非 NULL 时保证 fingerprint_cap/errlen 字节可写；exit_code_out 可为 NULL。
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
    let pass = (!password.is_empty()).then_some(password.as_str());
    let key = (!key_path.is_empty()).then_some(key_path.as_str());
    let key_pass = (!key_passphrase.is_empty()).then_some(key_passphrase.as_str());

    match crate::session::probe_blocking(&host, port as u16, &user, pass, key, key_pass, timeout_ms)
    {
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

/// 建立已认证会话。key_path 非空走公钥认证，否则密码认证。
/// 成功返回会话句柄；失败返回 NULL 并写 err（认证被拒同样为 NULL+err，由文案区分）。
/// 指纹形如 "SHA256:base64"（可为 NULL 缓冲）。超时 ms ≤0 用 20s。
///
/// # Safety
/// 字符串指针须指向有效 NUL 结尾缓冲；fingerprint_out/err 可为 NULL，
/// 非 NULL 时保证 fingerprint_cap/errlen 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_open(
    host: *const c_char,
    port: i32,
    user: *const c_char,
    password: *const c_char,
    key_path: *const c_char,
    key_passphrase: *const c_char,
    fingerprint_out: *mut c_char,
    fingerprint_cap: i32,
    timeout_ms: i32,
    err: *mut c_char,
    errlen: i32,
) -> *mut RusshSession {
    let host = read_str(host);
    let user = read_str(user);
    let password = read_str(password);
    let key_path = read_str(key_path);
    let key_passphrase = read_str(key_passphrase);
    if host.is_empty() || user.is_empty() || !(1..=65535).contains(&port) {
        copy_into(err, errlen, "参数无效（host/user 为空或端口越界）");
        return std::ptr::null_mut();
    }
    let pass = (!password.is_empty()).then_some(password.as_str());
    let key = (!key_path.is_empty()).then_some(key_path.as_str());
    let key_pass = (!key_passphrase.is_empty()).then_some(key_passphrase.as_str());
    let timeout = clamp_timeout(timeout_ms);

    let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime().block_on(RusshSession::connect(
            &host,
            port as u16,
            &user,
            pass,
            key,
            key_pass,
            timeout,
        ))
    }));
    match opened {
        Ok(Ok(session)) => {
            if let Some(fp) = session.fingerprint() {
                copy_into(fingerprint_out, fingerprint_cap, fp);
            }
            Box::into_raw(Box::new(session))
        }
        Ok(Err(message)) => {
            copy_into(err, errlen, &message);
            std::ptr::null_mut()
        }
        Err(_) => {
            copy_into(err, errlen, "内部 panic（已被 FFI 边界拦截）");
            std::ptr::null_mut()
        }
    }
}

/// exec 带 stdin + 整体超时 + 可取消。返回：0=完成、1=超时、2=被取消、-1=错误。
/// stdout 写 out/*out_len、stderr 写 errout/*err_len（均二进制安全、不补 NUL）；
/// 超过 cap 截断但持续抽干远端（不因输出上限死锁）。退出码写 *exit_code（无则为 -1）。
///
/// # Safety
/// command 须为有效 NUL 结尾字符串；stdin_bytes 非空时须有 stdin_len 字节可读；
/// out/errout 缓冲须保证 out_cap/errout_cap 字节可写（可为 NULL，此时长度写 0）；
/// s 必须来自 termo_russh_session_open 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_exec2(
    s: *mut RusshSession,
    command: *const c_char,
    stdin_bytes: *const c_char,
    stdin_len: i32,
    out: *mut c_char,
    out_cap: i32,
    out_len: *mut i32,
    errout: *mut c_char,
    errout_cap: i32,
    err_len: *mut i32,
    exit_code: *mut i32,
    timeout_ms: i32,
    err: *mut c_char,
    errlen: i32,
) -> i32 {
    if s.is_null() || command.is_null() {
        copy_into(err, errlen, "参数无效（会话或命令为空）");
        return -1;
    }
    let command = read_str(command);
    let stdin = if stdin_bytes.is_null() || stdin_len <= 0 {
        Vec::new()
    } else {
        std::slice::from_raw_parts(stdin_bytes as *const u8, stdin_len as usize).to_vec()
    };
    let timeout = clamp_timeout(timeout_ms);
    if !out_len.is_null() {
        *out_len = 0;
    }
    if !err_len.is_null() {
        *err_len = 0;
    }
    if !exit_code.is_null() {
        *exit_code = -1;
    }

    let session = &*s;
    match session.exec2_blocking(&command, stdin, timeout) {
        ExecResult::Done(output) => {
            copy_bytes(out, out_cap, out_len, &output.stdout);
            copy_bytes(errout, errout_cap, err_len, &output.stderr);
            if !exit_code.is_null() {
                *exit_code = output.exit_code.unwrap_or(-1);
            }
            0
        }
        ExecResult::Timeout => 1,
        ExecResult::Cancelled => 2,
        ExecResult::Error(message) => {
            copy_into(err, errlen, &message);
            -1
        }
    }
}

/// 请求中止当前 exec（粘住；可从任意线程调用）。
///
/// # Safety
/// s 必须来自 termo_russh_session_open 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_cancel(s: *mut RusshSession) {
    if !s.is_null() {
        (*s).cancel();
    }
}

/// 主机指纹（"SHA256:…"）。指向会话内部缓冲，close 后失效；无则返回空串。
///
/// # Safety
/// s 必须来自 termo_russh_session_open 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_sha256(s: *mut RusshSession) -> *const c_char {
    static EMPTY: &[u8] = b"\0";
    if s.is_null() {
        return EMPTY.as_ptr() as *const c_char;
    }
    (*s).fingerprint_cstring().as_ptr()
}

/// 断开并释放会话。
///
/// # Safety
/// s 必须来自 termo_russh_session_open，且只 close 一次。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_close(s: *mut RusshSession) {
    if !s.is_null() {
        let session = Box::from_raw(s);
        session.close();
        drop(session);
    }
}

/// 把二进制缓冲拷进调用方缓冲（截断），写实际长度；cap<=0 或缓冲 NULL 时长度写 0。
unsafe fn copy_bytes(dst: *mut c_char, cap: i32, written: *mut i32, src: &[u8]) {
    if dst.is_null() || cap <= 0 {
        if !written.is_null() {
            *written = 0;
        }
        return;
    }
    let n = src.len().min(cap as usize);
    std::ptr::copy_nonoverlapping(src.as_ptr() as *const c_char, dst, n);
    if !written.is_null() {
        *written = n as i32;
    }
}
