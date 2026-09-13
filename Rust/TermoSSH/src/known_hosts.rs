//! known_hosts 主机密钥策略：对标 libssh2 引擎的口径——
//! 仅当「明确与已存指纹不匹配」（疑似 MITM）才拒绝；未知主机/解析失败放行
//! （UI 预检弹窗负责建立首次信任）。持久文件 ~/.ssh/known_hosts + 会话文件
//! ~/.termo/session_known_hosts（应用启动时清空）。
//!
//! 支持条目：`host`（22 端口）与 `[host]:port`，逗号分隔多主机名；
//! 哈希条目（|1|…）、@标记、通配符暂不支持（按未知放行，同旧行为）。

use std::collections::HashMap;
use std::sync::OnceLock;

use data_encoding::{BASE64, BASE64_NOPAD};
use sha2::Digest;

/// 判定结果：0=已知匹配 1=未知 2=不匹配(疑似 MITM)。
pub const HOST_MATCH: i32 = 0;
pub const HOST_UNKNOWN: i32 = 1;
pub const HOST_MISMATCH: i32 = 2;

/// host+port → known_hosts 主机段。
pub fn host_spec(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

/// blob（known_hosts 第三列 b64）→ "SHA256:<unpadded b64>"。
pub fn blob_fingerprint(blob_b64: &str) -> Option<String> {
    let raw = BASE64.decode(blob_b64.trim().as_bytes()).ok()?;
    let digest = sha2::Sha256::digest(&raw);
    Some(format!("SHA256:{}", BASE64_NOPAD.encode(digest.as_slice())))
}

/// 解析单个 known_hosts 行 → (主机段集合, 指纹)；不支持的条目返回 None。
fn parse_line(line: &str) -> Option<(Vec<String>, String)> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let mut fields = line.split_whitespace();
    let host_field = fields.next()?;
    let _algo = fields.next()?;
    let blob = fields.next()?;
    if host_field.starts_with('@') || host_field.starts_with('|') {
        return None;
    }
    if host_field.contains('*') || host_field.contains('?') {
        return None;
    }
    let fp = blob_fingerprint(blob)?;
    let hosts = host_field
        .split(',')
        .map(str::trim)
        .map(str::to_string)
        .collect();
    Some((hosts, fp))
}

type FpMap = HashMap<String, Vec<String>>;

/// 读文件 → {主机段: [指纹]}（解析失败的行跳过）。
fn load(path: &str) -> FpMap {
    let mut map: FpMap = HashMap::new();
    let Ok(content) = std::fs::read_to_string(path) else {
        return map;
    };
    for line in content.lines() {
        if let Some((hosts, fp)) = parse_line(line) {
            for h in hosts {
                map.entry(h).or_default().push(fp.clone());
            }
        }
    }
    map
}

/// 判定 host:port 的密钥指纹状态（两个文件；进程级缓存由调用方持有）。
pub fn check_status(
    host: &str,
    port: u16,
    fingerprint: &str,
    real_known_hosts: &str,
    session_known_hosts: &str,
    real_cache: &OnceLock<FpMap>,
    session_cache: &OnceLock<FpMap>,
) -> i32 {
    let spec = host_spec(host, port);
    let mut has_entry = false;
    for map in [
        real_cache.get_or_init(|| load(real_known_hosts)),
        session_cache.get_or_init(|| load(session_known_hosts)),
    ] {
        // 取反条目命中 → 明确撤销 → 不匹配
        if map
            .get(&format!("!{spec}"))
            .is_some_and(|fps| fps.iter().any(|f| f == fingerprint))
        {
            return HOST_MISMATCH;
        }
        if let Some(fps) = map.get(&spec) {
            has_entry = true;
            if fps.iter().any(|f| f == fingerprint) {
                return HOST_MATCH;
            }
        }
    }
    if has_entry {
        HOST_MISMATCH
    } else {
        HOST_UNKNOWN
    }
}

/// 生成可写入 known_hosts 的信任行（非哈希、显式端口段）。
pub fn trust_line(host: &str, port: u16, algorithm_name: &str, blob_b64: &str) -> String {
    format!("{} {} {}", host_spec(host, port), algorithm_name, blob_b64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn init_cache(content: &str) -> (std::path::PathBuf, OnceLock<FpMap>) {
        let path =
            std::env::temp_dir().join(format!("termo-kh-{}-{:p}", std::process::id(), &content));
        std::fs::write(&path, content).expect("write");
        (path, OnceLock::new())
    }

    #[test]
    fn match_unknown_mismatch() {
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIB6kM6vXc9ZpIs7CySPNo";
        let (p1, c1) = init_cache(&format!("myhost ssh-ed25519 {blob}\n"));
        let real_fp = blob_fingerprint(blob).expect("fp");
        let fp_b = "SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
        assert_eq!(
            check_status(
                "myhost",
                22,
                &real_fp,
                p1.to_str().unwrap(),
                "/nonexistent",
                &c1,
                &OnceLock::new()
            ),
            HOST_MATCH
        );
        assert_eq!(
            check_status(
                "myhost",
                22,
                fp_b,
                p1.to_str().unwrap(),
                "/nonexistent",
                &c1,
                &OnceLock::new()
            ),
            HOST_MISMATCH
        );
        assert_eq!(
            check_status(
                "other",
                22,
                &real_fp,
                p1.to_str().unwrap(),
                "/nonexistent",
                &c1,
                &OnceLock::new()
            ),
            HOST_UNKNOWN
        );
        let _ = std::fs::remove_file(p1);
    }

    #[test]
    fn port_22_uses_bare_host_spec() {
        assert_eq!(host_spec("h", 22), "h");
        assert_eq!(host_spec("h", 2222), "[h]:2222");
    }

    #[test]
    fn unsupported_lines_are_skipped() {
        assert!(parse_line("|1|abc= ssh-ed25519 AAAA").is_none());
        assert!(parse_line("*.lan ssh-ed25519 AAAA").is_none());
        assert!(parse_line("@cert-authority *.lan AAAA").is_none());
        assert!(parse_line("").is_none());
        assert!(parse_line("# comment").is_none());
    }

    #[test]
    fn trust_line_uses_port_spec() {
        assert_eq!(
            trust_line("h", 22, "ssh-ed25519", "QQ=="),
            "h ssh-ed25519 QQ=="
        );
        assert_eq!(
            trust_line("h", 2222, "ssh-rsa", "QQ=="),
            "[h]:2222 ssh-rsa QQ=="
        );
    }
}
