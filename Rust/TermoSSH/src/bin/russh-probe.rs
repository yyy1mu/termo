//! 手动端到端测试工具：对真实 SSH 服务器跑连接/认证探针或 exec2。
//!
//! 用法：
//!   cargo run --release -p termo-ssh --bin russh-probe -- HOST PORT USER
//!        [--password PASS | --key PATH [PASSPHRASE]]
//!        [--exec CMD [--stdin-file PATH]] [--timeout MS]
//!
//! 缺省 exec `true`（仅验证连接/认证/通道）。密码与口令仅作为命令行参数临时
//! 传入，请勿在共享机器上使用真实凭据。

use std::process::ExitCode;

use termo_ssh::{clamp_timeout, ExecResult, RusshSession};

fn usage() {
    eprintln!(
        "用法: russh-probe HOST PORT USER [--password PASS | --key PATH [PASSPHRASE]] [--exec CMD [--stdin-file PATH]] [--timeout MS]"
    );
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
