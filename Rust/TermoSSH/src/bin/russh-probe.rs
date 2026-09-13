//! 手动端到端测试工具：对真实 SSH 服务器跑连接/认证探针、exec2 或 PTY shell。
//!
//! 用法：
//!   cargo run --release -p termo-ssh --bin russh-probe -- HOST PORT USER
//!        [--password PASS | --key PATH [PASSPHRASE]]
//!        [--exec CMD [--stdin-file PATH] | --shell] [--timeout MS]
//!
//! 缺省 exec `true`（仅验证连接/认证/通道）；`--shell` 进入 PTY 交互（stdin EOF
//! 或远端退出结束）。密码与口令仅作为命令行参数临时传入，请勿在共享机器上
//! 使用真实凭据。

use std::io::{Read, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use termo_ssh::{clamp_timeout, ExecResult, RusshSession, RusshShell};

fn usage() {
    eprintln!(
        "用法: russh-probe HOST PORT USER [--password PASS | --key PATH [PASSPHRASE]] [--exec CMD [--stdin-file PATH] | --shell] [--timeout MS]"
    );
}

/// --shell 桥：回调线程写 stdout，主线程把 stdin 喂给 PTY。
struct Bridge {
    exited: AtomicBool,
    code: AtomicI32,
}

unsafe extern "C" fn bridge_on_data(
    _ud: *mut std::ffi::c_void,
    bytes: *const std::ffi::c_char,
    len: i32,
) {
    let bytes = std::slice::from_raw_parts(bytes as *const u8, len.max(0) as usize);
    let mut out = std::io::stdout();
    out.write_all(bytes).ok();
    out.flush().ok();
}

unsafe extern "C" fn bridge_on_closed(ud: *mut std::ffi::c_void, exit_code: i32) {
    let bridge = &*(ud as *const Bridge);
    bridge.code.store(exit_code, Ordering::SeqCst);
    bridge.exited.store(true, Ordering::SeqCst);
}

fn run_shell(session: &RusshSession) -> i32 {
    let bridge = Box::new(Bridge {
        exited: AtomicBool::new(false),
        code: AtomicI32::new(-1),
    });
    let bridge_ptr = Box::into_raw(bridge);
    let shell = session.shell_open_blocking(
        80,
        24,
        bridge_on_data,
        bridge_on_closed,
        bridge_ptr as *mut std::ffi::c_void,
    );
    let shell: RusshShell = match shell {
        Ok(shell) => shell,
        Err(message) => {
            eprintln!("失败: {message}");
            unsafe { drop(Box::from_raw(bridge_ptr)) };
            return -1;
        }
    };

    let mut buf = [0u8; 4096];
    loop {
        if unsafe { (*bridge_ptr).exited.load(Ordering::SeqCst) } {
            break;
        }
        match std::io::stdin().read(&mut buf) {
            Ok(0) | Err(_) => {
                shell.close(); // stdin EOF：close 返回后 on_closed 已触发
                break;
            }
            Ok(n) => {
                if shell.write(&buf[..n]) < 0 {
                    break;
                }
            }
        }
    }
    let code = unsafe { (*bridge_ptr).code.load(Ordering::SeqCst) };
    unsafe { drop(Box::from_raw(bridge_ptr)) };
    code
}

fn main() -> ExitCode {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 3 {
        usage();
        return ExitCode::FAILURE;
    }
    let host = args.remove(0);
    let Ok(port) = args.remove(0).parse::<u16>() else {
        usage();
        return ExitCode::FAILURE;
    };
    let user = args.remove(0);

    let mut password = None;
    let mut key_path = None;
    let mut key_passphrase = None;
    let mut command: Option<String> = None;
    let mut stdin_file: Option<String> = None;
    let mut shell_mode = false;
    let mut timeout_ms = 20_000;
    while !args.is_empty() {
        match args.remove(0).as_str() {
            "--password" => password = Some(args.remove(0)),
            "--key" => {
                key_path = Some(args.remove(0));
                if !args.is_empty() && !args[0].starts_with("--") {
                    key_passphrase = Some(args.remove(0));
                }
            }
            "--exec" => command = Some(args.remove(0)),
            "--stdin-file" => stdin_file = Some(args.remove(0)),
            "--shell" => shell_mode = true,
            "--timeout" => timeout_ms = args.remove(0).parse().unwrap_or(20_000),
            _ => {
                usage();
                return ExitCode::FAILURE;
            }
        }
    }
    let timeout = clamp_timeout(timeout_ms);

    let session = match RusshSession::connect_blocking(
        &host,
        port,
        &user,
        password.as_deref(),
        key_path.as_deref(),
        key_passphrase.as_deref(),
        timeout,
    ) {
        Ok(session) => session,
        Err(message) => {
            eprintln!("失败: {message}");
            return ExitCode::FAILURE;
        }
    };

    println!("主机指纹: {}", session.fingerprint().unwrap_or("(无)"));

    if shell_mode {
        let code = run_shell(&session);
        session.close();
        println!("\n[shell 结束，退出码 {code}]");
        return if code == 0 {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }

    let stdin = match stdin_file.map(std::fs::read) {
        Some(Ok(bytes)) => bytes,
        Some(Err(e)) => {
            eprintln!("失败: stdin 读取失败: {e}");
            session.close();
            return ExitCode::FAILURE;
        }
        None => Vec::new(),
    };

    let result = session.exec2_blocking(&command.unwrap_or_else(|| "true".into()), stdin, timeout);
    session.close();
    match result {
        ExecResult::Done(output) => {
            println!("退出码: {}", output.exit_code.unwrap_or(-1));
            if !output.stdout.is_empty() {
                println!("stdout ({} 字节):", output.stdout.len());
                std::io::Write::write_all(&mut std::io::stdout(), &output.stdout).ok();
                println!();
            }
            if !output.stderr.is_empty() {
                eprintln!("stderr ({} 字节):", output.stderr.len());
                std::io::Write::write_all(&mut std::io::stderr(), &output.stderr).ok();
                eprintln!();
            }
            ExitCode::SUCCESS
        }
        ExecResult::Timeout => {
            eprintln!("失败: 超时");
            ExitCode::FAILURE
        }
        ExecResult::Cancelled => {
            eprintln!("失败: 已取消");
            ExitCode::FAILURE
        }
        ExecResult::Error(message) => {
            eprintln!("失败: {message}");
            ExitCode::FAILURE
        }
    }
}
