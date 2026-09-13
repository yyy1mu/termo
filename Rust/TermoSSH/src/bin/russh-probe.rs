//! 手动端到端测试工具：对真实 SSH 服务器跑连接/认证/exec 探针。
//!
//! 用法：
//!   cargo run --release -p termo-ssh --bin russh-probe -- HOST PORT USER [--password PASS | --key PATH [PASSPHRASE]] [--timeout MS]
//!
//! 密码与口令仅作为命令行参数临时传入，请勿在共享机器上使用真实凭据。

use std::process::ExitCode;

use termo_ssh::probe_blocking;

fn usage() {
    eprintln!(
        "用法: russh-probe HOST PORT USER [--password PASS | --key PATH [PASSPHRASE]] [--timeout MS]"
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
    let mut timeout_ms = 20_000;
    while !args.is_empty() {
        match args.remove(0).as_str() {
            "--password" => {
                password = Some(args.remove(0));
            }
            "--key" => {
                key_path = Some(args.remove(0));
                if !args.is_empty() && !args[0].starts_with("--") {
                    key_passphrase = Some(args.remove(0));
                }
            }
            "--timeout" => {
                timeout_ms = args.remove(0).parse().unwrap_or(20_000);
            }
            _ => {
                usage();
                return ExitCode::FAILURE;
            }
        }
    }

    match probe_blocking(
        &host,
        port,
        &user,
        password.as_deref(),
        key_path.as_deref(),
        key_passphrase.as_deref(),
        timeout_ms,
    ) {
        Ok(outcome) => {
            println!(
                "主机指纹: {}",
                outcome.fingerprint.as_deref().unwrap_or("(无)")
            );
            println!("exec true 退出码: {}", outcome.exit_code);
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("失败: {message}");
            ExitCode::FAILURE
        }
    }
}
