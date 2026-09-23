//! C ABI：版本探针、连接探针、会话句柄（open/exec2/cancel/sha256/close）。
//!
//! 约定与 libssh2 引擎一致：缓冲超长截断且 NUL 结尾（exec2 的 out/errout 为
//! 二进制安全、按 *out_len/*err_len 取用）；返回值不抛 panic（catch_unwind 拦截）。

use std::ffi::c_char;

use crate::forward::{ForwardKind, ForwardSpec, ForwardStateCallback, RusshForward};
use crate::handler::HostPolicy;
use crate::scan::{scan_hostkey_blocking, ExecPullCallback};
use crate::session::{clamp_timeout, ExecResult, RusshSession};
use crate::sftp::{RusshSftp, RusshSftpFile, SftpAttrs};
use crate::shell::{RusshShell, ShellClosedCallback, ShellDataCallback};
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
/// 认证前仅接受 real/session known_hosts 中明确匹配的主机密钥；HOSTKEY_* 为验证失败。
/// 成功返回会话句柄；失败返回 NULL 并写 err。指纹形如 "SHA256:base64"。超时 ms ≤0 用 20s。
///
/// # Safety
/// 字符串指针须指向有效 NUL 结尾缓冲；fingerprint_out/err 可为 NULL，
/// 非 NULL 时保证 fingerprint_cap/errlen 字节可写。
#[no_mangle]
#[allow(clippy::too_many_arguments)] // 与 libssh2 C ABI 对齐
pub unsafe extern "C" fn termo_russh_session_open(
    host: *const c_char,
    port: i32,
    user: *const c_char,
    password: *const c_char,
    key_path: *const c_char,
    key_passphrase: *const c_char,
    real_known_hosts: *const c_char,
    session_known_hosts: *const c_char,
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
    let real = read_str(real_known_hosts);
    let session = read_str(session_known_hosts);
    if host.is_empty() || user.is_empty() || !(1..=65535).contains(&port) {
        copy_into(err, errlen, "参数无效（host/user 为空或端口越界）");
        return std::ptr::null_mut();
    }
    let pass = (!password.is_empty()).then_some(password.as_str());
    let key = (!key_path.is_empty()).then_some(key_path.as_str());
    let key_pass = (!key_passphrase.is_empty()).then_some(key_passphrase.as_str());
    let policy = (!real.is_empty() || !session.is_empty()).then_some(HostPolicy {
        host: host.clone(),
        port: port as u16,
        real_known_hosts: real,
        session_known_hosts: session,
    });
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
            policy,
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

/// 会话是否已失效（超时/取消后粘住）。失效会话不可归还会话池复用，
/// 调用方（Swift 侧 RemoteFS/会话池）应 close 并重建。
///
/// # Safety
/// s 可为 NULL（返回 false）。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_is_poisoned(s: *mut RusshSession) -> bool {
    !s.is_null() && (*s).is_poisoned()
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

// ── 交互式 shell（PTY）──────────────────────────────────────────────────────

/// 开 PTY(xterm-256color, cols×rows) + shell 并启动泵任务（非法尺寸默认 80×24）。
/// 成功返回句柄；失败返回 NULL 并写 err。
/// on_data 在泵任务线程增量回调；on_closed 结束时回调一次（退出码；掉线=255）。
///
/// # Safety
/// s 须为有效会话且未经 close；on_data/on_closed 必须为有效的 C 函数指针；
/// userdata 生命周期须覆盖整个 shell（close 之后不再回调）；
/// err 可为 NULL，非 NULL 时保证 errlen 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_shell_open(
    s: *mut RusshSession,
    cols: i32,
    rows: i32,
    command: *const c_char,          // 可选：非空则 PTY+exec 该命令（如 tmux attach）
    on_data: Option<ShellDataCallback>,
    on_closed: Option<ShellClosedCallback>,
    userdata: *mut std::ffi::c_void,
    err: *mut c_char,
    errlen: i32,
) -> *mut RusshShell {
    if s.is_null() {
        copy_into(err, errlen, "参数无效（会话为空）");
        return std::ptr::null_mut();
    }
    let (Some(on_data), Some(on_closed)) = (on_data, on_closed) else {
        copy_into(err, errlen, "参数无效（回调为空）");
        return std::ptr::null_mut();
    };
    let session = &*s;
    let command = if command.is_null() { None } else { Some(crate::read_str(command)) };
    let command = command.filter(|c| !c.is_empty());
    let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime().block_on(session.shell_open(cols, rows, command, on_data, on_closed, userdata))
    }));
    match opened {
        Ok(Ok(shell)) => Box::into_raw(Box::new(shell)),
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

/// 写入远端 PTY（线程安全：入队立即返回）。返回入队字节数或 -1。
///
/// # Safety
/// sh 须来自 termo_russh_shell_open 且未经 close；buf 须有 len 字节可读。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_shell_write(
    sh: *mut RusshShell,
    buf: *const c_char,
    len: i32,
) -> std::ffi::c_long {
    if sh.is_null() || buf.is_null() || len < 0 {
        return -1;
    }
    let bytes = std::slice::from_raw_parts(buf as *const u8, len as usize);
    (*sh).write(bytes)
}

/// 通知 PTY 尺寸变化（线程安全）。返回 0=成功 / -1=泵已退出。
///
/// # Safety
/// sh 须来自 termo_russh_shell_open 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_shell_resize(
    sh: *mut RusshShell,
    cols: i32,
    rows: i32,
) -> i32 {
    if sh.is_null() {
        return -1;
    }
    (*sh).resize(cols, rows)
}

/// 停泵 + 关闭/释放句柄（close 返回后不再有回调；不关底层会话）。
///
/// # Safety
/// sh 须来自 termo_russh_shell_open，且只 close 一次。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_shell_close(sh: *mut RusshShell) {
    if !sh.is_null() {
        let shell = Box::from_raw(sh);
        shell.close();
        drop(shell);
    }
}

// ── 端口转发（-L / -R / -D）─────────────────────────────────────────────────

/// 开启转发。kind：0=本地(-L) 1=远程(-R) 2=动态 SOCKS5(-D)。
/// -L/-D 在 bind_addr:listen_port 开本地监听（bind_addr 空 → 0.0.0.0）；
/// -R 在服务器 bind_addr:listen_port 开远端监听，进来的连接转回本机 dest。
/// 监听建立失败（端口占用等）立即返回 NULL 并写 err。
/// on_state(ok=0) 表示连接断开/致命错误（上层据此重连/标记失败）。
///
/// # Safety
/// s 须为有效会话；on_state 须为有效 C 函数指针；userdata 生命周期覆盖整个
/// forward（close 之后不再回调）；字符串指针须为有效 NUL 结尾缓冲；
/// err 可为 NULL，非 NULL 时保证 errlen 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_forward_open(
    s: *mut RusshSession,
    kind: i32,
    bind_addr: *const c_char,
    listen_port: i32,
    dest_host: *const c_char,
    dest_port: i32,
    on_state: Option<ForwardStateCallback>,
    userdata: *mut std::ffi::c_void,
    err: *mut c_char,
    errlen: i32,
) -> *mut RusshForward {
    if s.is_null() {
        copy_into(err, errlen, "参数无效（会话为空）");
        return std::ptr::null_mut();
    }
    let kind = match kind {
        0 => ForwardKind::Local,
        1 => ForwardKind::Remote,
        2 => ForwardKind::Dynamic,
        _ => {
            copy_into(err, errlen, "参数无效（kind 须为 0/1/2）");
            return std::ptr::null_mut();
        }
    };
    let Some(on_state) = on_state else {
        copy_into(err, errlen, "参数无效（回调为空）");
        return std::ptr::null_mut();
    };
    let bind_addr = read_str(bind_addr);
    let dest_host = read_str(dest_host);
    if kind != ForwardKind::Dynamic && (dest_host.is_empty() || !(1..=65535).contains(&dest_port)) {
        copy_into(err, errlen, "参数无效（-L/-R 须提供 dest_host:dest_port）");
        return std::ptr::null_mut();
    }
    if !(0..=65535).contains(&listen_port) {
        copy_into(err, errlen, "参数无效（listen_port 越界）");
        return std::ptr::null_mut();
    }

    let session = &*s;
    let spec = ForwardSpec {
        kind,
        bind_addr,
        listen_port: listen_port as u16,
        dest_host,
        dest_port: dest_port as u16,
    };
    let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime().block_on(session.forward_open(spec, on_state, userdata))
    }));
    match opened {
        Ok(Ok(forward)) => Box::into_raw(Box::new(forward)),
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

/// 主机指纹（MD5，"aa:bb:…"）。指向会话内部缓冲，close 后失效；无则空串。
///
/// # Safety
/// s 必须来自 termo_russh_session_open 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_session_md5(s: *mut RusshSession) -> *const c_char {
    static EMPTY: &[u8] = b"\0";
    if s.is_null() {
        return EMPTY.as_ptr() as *const c_char;
    }
    (*s).md5_cstring().as_ptr()
}

/// 主机密钥扫描结果（与 libssh2 版 TermoHostKeyScan 字段一一对应）。
#[repr(C)]
pub struct TermoRusshHostKeyScan {
    pub status: i32,
    pub sha256: [u8; 80],
    pub md5: [u8; 64],
    pub line: [u8; 1024],
}

/// 扫描 host:port 的主机密钥（不认证、不发密码）；结果写 *out。
///
/// # Safety
/// host/known_hosts 路径须为有效 NUL 结尾字符串；out 非空且可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_scan_hostkey(
    host: *const c_char,
    port: i32,
    real_known_hosts: *const c_char,
    session_known_hosts: *const c_char,
    out: *mut TermoRusshHostKeyScan,
) -> i32 {
    if host.is_null() || out.is_null() {
        return -1;
    }
    let host = read_str(host);
    let real = read_str(real_known_hosts);
    let session = read_str(session_known_hosts);
    match scan_hostkey_blocking(&host, port as u16, &real, &session) {
        Ok(scan) => {
            *out = TermoRusshHostKeyScan {
                status: scan.status,
                sha256: scan.sha256,
                md5: scan.md5,
                line: scan.line,
            };
            0
        }
        Err(_) => -1,
    }
}

/// 流式上传 exec（pull 回调喂 stdin）：返回 0=完成 / 1=被取消 / -1=错误。
///
/// # Safety
/// s 须为有效会话；command 须为有效 NUL 结尾字符串；pull 须为有效 C 函数指针；
/// err 可为 NULL，非 NULL 时保证 errlen 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_exec_upload(
    s: *mut RusshSession,
    command: *const c_char,
    pull: Option<ExecPullCallback>,
    userdata: *mut std::ffi::c_void,
    _exit_code: *mut i32,
    err: *mut c_char,
    errlen: i32,
) -> i32 {
    let (Some(pull), false) = (pull, s.is_null() || command.is_null()) else {
        return write_err(err, errlen, -1, "参数无效");
    };
    let command = read_str(command);
    let fut = (*s).exec_upload(&command, pull, userdata);
    let run = || runtime().block_on(fut);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(run)) {
        Ok(Ok(code)) => code,
        Ok(Err(message)) => write_err(err, errlen, -1, &message),
        Err(_) => write_err(err, errlen, -1, "内部 panic（已被 FFI 边界拦截）"),
    }
}

/// 流式 exec：stdout 增量回调直到 EOF/错误/被取消。返回 0=结束/被取消、-1=错误。
///
/// # Safety
/// s 须为有效会话；command 须为有效 NUL 结尾字符串；on_data 须为有效 C 函数指针。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_exec_stream(
    s: *mut RusshSession,
    command: *const c_char,
    on_data: Option<ShellDataCallback>,
    userdata: *mut std::ffi::c_void,
    err: *mut c_char,
    errlen: i32,
) -> i32 {
    let (Some(on_data), false) = (on_data, s.is_null() || command.is_null()) else {
        return write_err(err, errlen, -1, "参数无效");
    };
    let command = read_str(command);
    let fut = (*s).exec_stream(&command, on_data, userdata);
    let run = || runtime().block_on(fut);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(run)) {
        Ok(Ok(())) => 0,
        Ok(Err(message)) => write_err(err, errlen, -1, &message),
        Err(_) => write_err(err, errlen, -1, "内部 panic（已被 FFI 边界拦截）"),
    }
}

/// SFTP：最近一次失败的状态码（对齐 libssh2 last_errno）。
///
/// # Safety
/// sftp 须来自 termo_russh_sftp_init 且未经 shutdown。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_last_errno(sftp: *mut RusshSftp) -> i32 {
    if sftp.is_null() {
        return 0;
    }
    (*sftp).last()
}

/// SFTP：显式记录状态码（open/opendir 失败路径由适配层写入）。
///
/// # Safety
/// sftp 须有效。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_set_last(sftp: *mut RusshSftp, code: i32) {
    if !sftp.is_null() {
        (*sftp).set_last(code);
    }
}

/// 停止转发并回收监督任务（close 返回后不再有 on_state 回调）。
///
/// # Safety
/// f 须来自 termo_russh_forward_open，且只 close 一次。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_forward_close(f: *mut RusshForward) {
    if !f.is_null() {
        let forward = Box::from_raw(f);
        forward.close();
        drop(forward);
    }
}

// ── SFTP（russh-sftp Raw API；语义对齐 libssh2 版）──────────────────────────
// 约定同 libssh2 头：返回 int 的函数 0=成功；>0 且 <0xF000=SFTP 状态码（如 2=无此文件）；
// ≥0xF000=传输/内部错误。open/opendir/init 失败返回 NULL。

/// SFTP 属性（对齐 TermoSFTPAttrs）。
#[repr(C)]
pub struct TermoRusshSFTPAttrs {
    pub has_size: i32,
    pub has_perm: i32,
    pub has_mtime: i32,
    pub size: u64,
    pub permissions: u32,
    pub mtime: u32,
}

impl TermoRusshSFTPAttrs {
    fn from(a: SftpAttrs) -> Self {
        Self {
            has_size: a.has_size as i32,
            has_perm: a.has_perm as i32,
            has_mtime: a.has_mtime as i32,
            size: a.size,
            permissions: a.permissions,
            mtime: a.mtime,
        }
    }
}

/// SFTP 调用统一入口：block_on + panic 隔离；Err 供各导出写 err 并返回状态码。
fn sftp_run<T>(
    fut: impl std::future::Future<Output = Result<T, crate::sftp::SftpOpError>>,
) -> Result<T, (i32, String)> {
    let run = || runtime().block_on(fut);
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(run))
        .unwrap_or_else(|_| {
            Err(crate::sftp::SftpOpError {
                code: 0xF001,
                message: "内部 panic（已被 FFI 边界拦截）".to_owned(),
            })
        })
        .map_err(|e| (e.code, e.message))
}

unsafe fn write_err(err: *mut c_char, errlen: i32, code: i32, message: &str) -> i32 {
    copy_into(err, errlen, message);
    code
}

/// 在已认证会话上初始化 SFTP 子系统。
///
/// # Safety
/// s 须为有效会话；err 可为 NULL，非 NULL 时保证 errlen 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_init(
    s: *mut RusshSession,
    err: *mut c_char,
    errlen: i32,
) -> *mut RusshSftp {
    if s.is_null() {
        copy_into(err, errlen, "参数无效（会话为空）");
        return std::ptr::null_mut();
    }
    match (*s).sftp_init_blocking() {
        Ok(sftp) => Box::into_raw(Box::new(sftp)),
        Err(message) => {
            copy_into(err, errlen, &message);
            std::ptr::null_mut()
        }
    }
}

/// 关闭 SFTP 子系统（不关底层会话）。
///
/// # Safety
/// sftp 须来自 termo_russh_sftp_init，且只 shutdown 一次。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_shutdown(sftp: *mut RusshSftp) {
    if !sftp.is_null() {
        drop(Box::from_raw(sftp));
    }
}

/// stat（follow=1）/ lstat（follow=0）。返回 0=成功（attrs 已写）或状态码。
///
/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串；attrs 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_stat(
    sftp: *mut RusshSftp,
    path: *const c_char,
    follow: i32,
    attrs: *mut TermoRusshSFTPAttrs,
) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    let fut = (*sftp).stat(&path, follow != 0);
    match sftp_run(fut) {
        Ok(a) => {
            if !attrs.is_null() {
                *attrs = TermoRusshSFTPAttrs::from(a);
            }
            0
        }
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// 设权限位（mode & 07777）。
///
/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_setstat_perm(
    sftp: *mut RusshSftp,
    path: *const c_char,
    mode: u32,
) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    match sftp_run((*sftp).set_permissions(&path, mode)) {
        Ok(()) => 0,
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_mkdir(sftp: *mut RusshSftp, path: *const c_char) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    match sftp_run((*sftp).mkdir(&path)) {
        Ok(()) => 0,
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_rmdir(sftp: *mut RusshSftp, path: *const c_char) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    match sftp_run((*sftp).rmdir(&path)) {
        Ok(()) => 0,
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_unlink(sftp: *mut RusshSftp, path: *const c_char) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    match sftp_run((*sftp).remove(&path)) {
        Ok(()) => 0,
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// 重命名；overwrite=1 → posix-rename 原子覆盖（不支持的服务器回退删+改）。
///
/// # Safety
/// sftp 须有效；from/to 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_rename(
    sftp: *mut RusshSftp,
    from: *const c_char,
    to: *const c_char,
    overwrite: i32,
) -> i32 {
    if sftp.is_null() || from.is_null() || to.is_null() {
        return 0xF001;
    }
    let (from, to) = (read_str(from), read_str(to));
    let result = if overwrite != 0 {
        sftp_run((*sftp).posix_rename(&from, &to))
    } else {
        sftp_run((*sftp).rename(&from, &to))
    };
    match result {
        Ok(()) => 0,
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// 解析绝对路径写入 out（截断到 out_cap-1，NUL 结尾）。
///
/// # Safety
/// sftp 须有效；out 须有 out_cap 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_realpath(
    sftp: *mut RusshSftp,
    path: *const c_char,
    out: *mut c_char,
    out_cap: i32,
) -> i32 {
    if sftp.is_null() || path.is_null() {
        return 0xF001;
    }
    let path = read_str(path);
    match sftp_run((*sftp).realpath(&path)) {
        Ok(real) => {
            copy_into(out, out_cap, &real);
            0
        }
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// 打开文件；pflags 直接透传 SSH_FXF_* 线上值（与 SFTPFlag 同值）。
///
/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_open(
    sftp: *mut RusshSftp,
    path: *const c_char,
    pflags: u32,
) -> *mut RusshSftpFile {
    if sftp.is_null() || path.is_null() {
        return std::ptr::null_mut();
    }
    let path = read_str(path);
    match sftp_run((*sftp).open(&path, pflags)) {
        Ok(file) => Box::into_raw(Box::new(file)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 打开目录。
///
/// # Safety
/// sftp 须有效；path 须为有效 NUL 结尾字符串。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_opendir(
    sftp: *mut RusshSftp,
    path: *const c_char,
) -> *mut RusshSftpFile {
    if sftp.is_null() || path.is_null() {
        return std::ptr::null_mut();
    }
    let path = read_str(path);
    match sftp_run((*sftp).opendir(&path)) {
        Ok(file) => Box::into_raw(Box::new(file)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 句柄 fstat。
///
/// # Safety
/// file 须来自 open/opendir 且未经 close。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_fstat(
    file: *mut RusshSftpFile,
    attrs: *mut TermoRusshSFTPAttrs,
) -> i32 {
    if file.is_null() {
        return 0xF001;
    }
    match sftp_run((*file).fstat()) {
        Ok(a) => {
            if !attrs.is_null() {
                *attrs = TermoRusshSFTPAttrs::from(a);
            }
            0
        }
        Err((code, message)) => write_err(std::ptr::null_mut(), 0, code, &message),
    }
}

/// 从 offset 读一块：返回字节数 / 0=EOF / 负=错误（-状态码或 -0xF001）。
///
/// # Safety
/// file 须有效；buf 须有 len 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_read(
    file: *mut RusshSftpFile,
    offset: u64,
    buf: *mut c_char,
    len: i32,
) -> i64 {
    if file.is_null() || buf.is_null() || len <= 0 {
        return -0xF001;
    }
    let fut = (*file).read(offset, len as u32);
    match sftp_run(fut) {
        Ok(data) => {
            let n = data.len().min(len as usize);
            std::ptr::copy_nonoverlapping(data.as_ptr() as *const c_char, buf, n);
            n as i64
        }
        Err((code, _)) => -i64::from(code.max(1)),
    }
}

/// 从 offset 写整块：返回已写字节 / 负=错误。
///
/// # Safety
/// file 须有效；buf 须有 len 字节可读。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_write(
    file: *mut RusshSftpFile,
    offset: u64,
    buf: *const c_char,
    len: i32,
) -> i64 {
    if file.is_null() || buf.is_null() || len <= 0 {
        return -0xF001;
    }
    let data = std::slice::from_raw_parts(buf as *const u8, len as usize).to_vec();
    match sftp_run((*file).write(offset, &data)) {
        Ok(n) => n as i64,
        Err((code, _)) => -i64::from(code.max(1)),
    }
}

/// 读一个目录项：name 写 name_buf（NUL 结尾）。返回名字长度 / 0=EOF / 负=错误。
/// EOF 后句柄已自动关闭。
///
/// # Safety
/// file 须来自 opendir 且未经 close；name_buf 须有 cap 字节可写；attrs 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_readdir(
    file: *mut RusshSftpFile,
    name_buf: *mut c_char,
    cap: i32,
    attrs: *mut TermoRusshSFTPAttrs,
) -> i32 {
    if file.is_null() || name_buf.is_null() || cap <= 0 {
        return -0xF001;
    }
    let fut = (*file).readdir();
    match sftp_run(fut) {
        Ok(Some((name, a))) => {
            copy_into(name_buf, cap, &name);
            if !attrs.is_null() {
                *attrs = TermoRusshSFTPAttrs::from(a);
            }
            name.len() as i32
        }
        Ok(None) => 0,
        Err((code, _)) => -code,
    }
}

/// 关闭文件/目录句柄。
///
/// # Safety
/// file 须来自 open/opendir，且只 close 一次。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_sftp_close(file: *mut RusshSftpFile) {
    if !file.is_null() {
        let mut f = Box::from_raw(file);
        let run = || runtime().block_on(f.close());
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(run));
        drop(f);
    }
}

// ── 密钥工具（替代 TermoKeyGen.c 的 OpenSSL 路径）───────────────────────────

/// 生成密钥对。type：0=ed25519 1=rsa(4096)。
/// out_priv=私钥文本（OpenSSH）、out_pub=公钥行、out_fp="SHA256:…"。
/// passphrase 非空则加密私钥（AES-256-CTR + bcrypt KDF）。返回 0/-1(+err)。
///
/// # Safety
/// 各 out 缓冲须保证对应 cap 字节可写（可为 NULL）；字符串指针须有效。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_key_generate(
    key_type: i32,
    comment: *const c_char,
    passphrase: *const c_char,
    out_priv: *mut c_char,
    priv_cap: i32,
    out_pub: *mut c_char,
    pub_cap: i32,
    out_fp: *mut c_char,
    fp_cap: i32,
    err: *mut c_char,
    errlen: i32,
) -> i32 {
    let comment = read_str(comment);
    let passphrase = read_str(passphrase);
    let run = || crate::keys::generate(key_type, &comment, &passphrase);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(run)) {
        Ok(Ok(key)) => {
            copy_into(out_priv, priv_cap, &key.private_openssh);
            copy_into(out_pub, pub_cap, &key.public_line);
            copy_into(out_fp, fp_cap, &key.fingerprint);
            0
        }
        Ok(Err(message)) => write_err(err, errlen, -1, &message),
        Err(_) => write_err(err, errlen, -1, "内部 panic（已被 FFI 边界拦截）"),
    }
}

/// 从私钥文件派生公钥行（无注释时带容器注释）。
/// 返回 0=成功（out_type 0=ed25519/1=rsa；out_encrypted=加密态）/
/// 1=加密 PEM 且无口令无法派生 / -1=错误。
///
/// # Safety
/// priv_path/passphrase 须为有效 NUL 结尾字符串；out_type/out_encrypted 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_key_pubkey_from_private(
    priv_path: *const c_char,
    passphrase: *const c_char,
    out_pub: *mut c_char,
    pub_cap: i32,
    out_type: *mut i32,
    out_encrypted: *mut i32,
) -> i32 {
    if priv_path.is_null() {
        return -1;
    }
    let path = read_str(priv_path);
    let passphrase = read_str(passphrase);
    let run = || crate::keys::pubkey_from_private(&path, &passphrase);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(run)) {
        Ok(Ok(crate::keys::PubkeyDerive::Ok {
            public_line,
            key_type,
            encrypted,
        })) => {
            copy_into(out_pub, pub_cap, &public_line);
            if !out_type.is_null() {
                *out_type = key_type;
            }
            if !out_encrypted.is_null() {
                *out_encrypted = encrypted as i32;
            }
            0
        }
        Ok(Ok(crate::keys::PubkeyDerive::EncryptedPemNoPassphrase)) => 1,
        Ok(Err(message)) => write_err(std::ptr::null_mut(), 0, -1, &message),
        Err(_) => write_err(
            std::ptr::null_mut(),
            0,
            -1,
            "内部 panic（已被 FFI 边界拦截）",
        ),
    }
}

/// 由公钥行算 "SHA256:…" 指纹。返回 0/-1。
///
/// # Safety
/// pub_line 须为有效 NUL 结尾字符串；out_fp 须有 fp_cap 字节可写。
#[no_mangle]
pub unsafe extern "C" fn termo_russh_key_fingerprint(
    pub_line: *const c_char,
    out_fp: *mut c_char,
    fp_cap: i32,
) -> i32 {
    if pub_line.is_null() {
        return -1;
    }
    let line = read_str(pub_line);
    let run = || crate::keys::fingerprint_of_public(&line);
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(run)) {
        Ok(Ok(fp)) => {
            copy_into(out_fp, fp_cap, &fp);
            0
        }
        Ok(Err(message)) => write_err(std::ptr::null_mut(), 0, -1, &message),
        Err(_) => write_err(
            std::ptr::null_mut(),
            0,
            -1,
            "内部 panic（已被 FFI 边界拦截）",
        ),
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
