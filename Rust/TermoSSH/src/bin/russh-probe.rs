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

use termo_ssh::{clamp_timeout, ExecResult, ForwardKind, ForwardSpec, RusshSession, RusshShell};

fn usage() {
    eprintln!(
        "用法: russh-probe HOST PORT USER [--password PASS | --key PATH [PASSPHRASE]] [--exec CMD [--stdin-file PATH] | --shell] [--forward L:port:host:dport | R:port:host:dport | D:port]... [--sftp-ls PATH | --sftp-get REMOTE LOCAL | --sftp-put LOCAL REMOTE] [--timeout MS]"
    );
}

/// 解析 --forward 规格："L:port:host:dport" / "R:port:host:dport" / "D:port"。
fn parse_forward(s: &str) -> Result<ForwardSpec, String> {
    let (kind, rest) = match s.split_at(s.find(':').ok_or("缺 ':'")?) {
        ("L", r) | ("l", r) => (ForwardKind::Local, &r[1..]),
        ("R", r) | ("r", r) => (ForwardKind::Remote, &r[1..]),
        ("D", r) | ("d", r) => (ForwardKind::Dynamic, &r[1..]),
        _ => return Err("kind 须为 L/R/D".into()),
    };
    let parts: Vec<&str> = rest.split(':').collect();
    let (bind_addr, listen_port, dest_host, dest_port) = match (kind, parts.as_slice()) {
        (ForwardKind::Dynamic, [port]) => (
            "0.0.0.0".to_string(),
            port.parse::<u16>().map_err(|_| "端口无效")?,
            String::new(),
            0,
        ),
        (_, [port, host, dport]) => (
            "0.0.0.0".to_string(),
            port.parse::<u16>().map_err(|_| "端口无效")?,
            host.to_string(),
            dport.parse::<u16>().map_err(|_| "目标端口无效")?,
        ),
        _ => return Err("格式须为 L:port:host:dport / R:port:host:dport / D:port".into()),
    };
    Ok(ForwardSpec {
        kind,
        bind_addr,
        listen_port,
        dest_host,
        dest_port,
    })
}

unsafe extern "C" fn cli_on_state(
    _ud: *mut std::ffi::c_void,
    ok: i32,
    message: *const std::ffi::c_char,
) {
    if ok == 0 {
        let msg = std::ffi::CStr::from_ptr(message).to_string_lossy();
        eprintln!("[转发致命错误] {msg}");
    }
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

    // 独立模式（无需 HOST PORT USER）：--key-gen / --key-info
    if let Some(first) = args.first().cloned() {
        match first.as_str() {
            "--key-gen" => {
                args.remove(0);
                let Some(kind) = args.first().cloned() else {
                    usage();
                    return ExitCode::FAILURE;
                };
                args.remove(0);
                let key_type = match kind.as_str() {
                    "ed25519" => 0,
                    "rsa" => 1,
                    other => {
                        eprintln!("失败: --key-gen 须为 ed25519|rsa，收到 {other}");
                        return ExitCode::FAILURE;
                    }
                };
                return key_gen(key_type);
            }
            "--key-info" => {
                args.remove(0);
                let Some(path) = args.first().cloned() else {
                    usage();
                    return ExitCode::FAILURE;
                };
                args.remove(0);
                let passphrase = args.first().filter(|a| !a.starts_with("--")).cloned();
                return key_info(&path, passphrase.as_deref());
            }
            _ => {}
        }
    }

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
    let mut forwards: Vec<ForwardSpec> = Vec::new();
    let mut sftp_ls: Option<String> = None;
    let mut sftp_get: Option<(String, String)> = None;
    let mut sftp_put: Option<(String, String)> = None;
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
            "--forward" => match parse_forward(&args.remove(0)) {
                Ok(spec) => forwards.push(spec),
                Err(message) => {
                    eprintln!("失败: --forward {message}");
                    return ExitCode::FAILURE;
                }
            },
            "--sftp-ls" => sftp_ls = Some(args.remove(0)),
            "--sftp-get" => {
                let remote = args.remove(0);
                let local = args.remove(0);
                sftp_get = Some((remote, local));
            }
            "--sftp-put" => {
                let local = args.remove(0);
                let remote = args.remove(0);
                sftp_put = Some((local, remote));
            }
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

    // SFTP 手动回归：ls / get / put
    if sftp_ls.is_some() || sftp_get.is_some() || sftp_put.is_some() {
        let sftp = match session.sftp_init_blocking() {
            Ok(sftp) => sftp,
            Err(message) => {
                eprintln!("失败: {message}");
                session.close();
                return ExitCode::FAILURE;
            }
        };
        let ok = run_sftp(
            &sftp,
            sftp_ls.as_deref(),
            sftp_get.as_ref(),
            sftp_put.as_ref(),
        );
        session.close();
        return if ok {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }

    // 开启转发规则；然后阻塞在 stdin（EOF 退出），期间隧道工作
    if !forwards.is_empty() {
        let mut active = Vec::new();
        for (i, spec) in forwards.into_iter().enumerate() {
            match session.forward_open_blocking(spec.clone(), cli_on_state, std::ptr::null_mut()) {
                Ok(fwd) => {
                    println!(
                        "[转发 #{}] {:?} {}:{} → {}:{} 已建立",
                        i,
                        spec.kind,
                        spec.bind_addr,
                        spec.listen_port,
                        spec.dest_host,
                        spec.dest_port
                    );
                    active.push(fwd);
                }
                Err(message) => {
                    eprintln!("[转发 #{}] 失败: {message}", i);
                    for f in active {
                        f.close();
                    }
                    session.close();
                    return ExitCode::FAILURE;
                }
            }
        }
        let _ = std::io::stdin().read_to_end(&mut Vec::new());
        for f in active {
            f.close();
        }
        session.close();
        println!("[转发已全部停止]");
        return ExitCode::SUCCESS;
    }

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

/// SFTP 手动回归：ls / get / put（32 KiB 分块，对齐 Swift 侧行为口径）。
fn run_sftp(
    sftp: &termo_ssh::RusshSftp,
    ls: Option<&str>,
    get: Option<&(String, String)>,
    put: Option<&(String, String)>,
) -> bool {
    use std::io::{Read, Write};

    if let Some(path) = ls {
        let mut dir = match termo_ssh::block_on(sftp.opendir(path)) {
            Ok(dir) => dir,
            Err(e) => {
                eprintln!("失败: opendir {path}: code={} {}", e.code, e.message);
                return false;
            }
        };
        loop {
            match termo_ssh::block_on(dir.readdir()) {
                Ok(Some((name, attrs))) => {
                    let is_dir = (attrs.permissions & 0o170000) == 0o040000;
                    let size = if is_dir {
                        String::from("<dir>")
                    } else {
                        attrs.size.to_string()
                    };
                    println!("{size:>12}  {name}");
                }
                Ok(None) => break,
                Err(e) => {
                    eprintln!("失败: readdir: code={} {}", e.code, e.message);
                    return false;
                }
            }
        }
        return true;
    }

    if let Some((remote, local)) = get {
        let file = match termo_ssh::block_on(sftp.open(remote, 0x1)) {
            Ok(file) => file,
            Err(e) => {
                eprintln!("失败: open {remote}: code={} {}", e.code, e.message);
                return false;
            }
        };
        let mut out = match std::fs::File::create(local) {
            Ok(out) => out,
            Err(e) => {
                eprintln!("失败: 创建 {local}: {e}");
                return false;
            }
        };
        let mut offset = 0u64;
        loop {
            match termo_ssh::block_on(file.read(offset, 32 * 1024)) {
                Ok(data) => {
                    if data.is_empty() {
                        break;
                    }
                    if out.write_all(&data).is_err() {
                        eprintln!("失败: 本地写入");
                        return false;
                    }
                    offset += data.len() as u64;
                }
                Err(e) => {
                    eprintln!("失败: read @{offset}: code={} {}", e.code, e.message);
                    return false;
                }
            }
        }
        println!("[get] {remote} → {local}（{offset} 字节）");
        return true;
    }

    if let Some((local, remote)) = put {
        let mut input = match std::fs::File::open(local) {
            Ok(input) => input,
            Err(e) => {
                eprintln!("失败: 打开 {local}: {e}");
                return false;
            }
        };
        let file = match termo_ssh::block_on(sftp.open(remote, 0x2 | 0x8 | 0x10)) {
            Ok(file) => file,
            Err(e) => {
                eprintln!("失败: open {remote}: code={} {}", e.code, e.message);
                return false;
            }
        };
        let mut offset = 0u64;
        let mut buf = vec![0u8; 32 * 1024];
        loop {
            match input.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if let Err(e) = termo_ssh::block_on(file.write(offset, &buf[..n])) {
                        eprintln!("失败: write @{offset}: code={} {}", e.code, e.message);
                        return false;
                    }
                    offset += n as u64;
                }
                Err(e) => {
                    eprintln!("失败: 本地读取: {e}");
                    return false;
                }
            }
        }
        println!("[put] {local} → {remote}（{offset} 字节）");
        return true;
    }

    false
}

/// --key-gen：生成并打印（私钥文本属敏感信息，仅本地手工测试用）。
fn key_gen(key_type: i32) -> ExitCode {
    match termo_ssh::generate(key_type, "russh-probe", "") {
        Ok(key) => {
            println!("私钥:\n{}", key.private_openssh);
            println!("公钥: {}", key.public_line);
            println!("指纹: {}", key.fingerprint);
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("失败: {message}");
            ExitCode::FAILURE
        }
    }
}

/// --key-info PATH [PASSPHRASE]：派生公钥/类型/加密态。
fn key_info(path: &str, passphrase: Option<&str>) -> ExitCode {
    match termo_ssh::pubkey_from_private(path, passphrase.unwrap_or("")) {
        Ok(termo_ssh::PubkeyDerive::Ok {
            public_line,
            key_type,
            encrypted,
        }) => {
            let kind = if key_type == 1 { "rsa" } else { "ed25519" };
            match termo_ssh::fingerprint_of_public(&public_line) {
                Ok(fp) => {
                    println!("类型: {kind}\n加密: {encrypted}\n公钥: {public_line}\n指纹: {fp}")
                }
                Err(message) => {
                    eprintln!("失败: {message}");
                    return ExitCode::FAILURE;
                }
            }
            ExitCode::SUCCESS
        }
        Ok(termo_ssh::PubkeyDerive::EncryptedPemNoPassphrase) => {
            eprintln!("失败: 加密 PEM 未提供口令");
            ExitCode::FAILURE
        }
        Err(message) => {
            eprintln!("失败: {message}");
            ExitCode::FAILURE
        }
    }
}
