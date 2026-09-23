//! 连接与认证：ProbeHandler 记录主机指纹并执行 known_hosts 策略，
//! connect_and_auth 供会话与扫描共用。
//!
//! 认证前必须匹配已信任的密钥；未知、变化、撤销、读取失败均拒绝。扫描不认证。

use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};

use crate::known_hosts;

/// -R 转发路由槽：forward_open 安装发送端，Handler 回调投递服务器转来的通道。
pub(crate) type ForwardSlot =
    Mutex<Option<tokio::sync::mpsc::UnboundedSender<russh::Channel<russh::client::Msg>>>>;

/// known_hosts 策略入参（两个文件 + 宿主信息）。
#[derive(Debug, Clone)]
pub struct HostPolicy {
    pub host: String,
    pub port: u16,
    pub real_known_hosts: String,
    pub session_known_hosts: String,
}

/// 主机密钥观测结果（握手后可用）。
#[derive(Debug, Default)]
pub struct HostKeyInfo {
    pub status: Mutex<i32>,
    pub sha256: Mutex<String>,
    pub md5: Mutex<String>,
    pub line: Mutex<String>,
}

impl HostKeyInfo {
    fn arc_default() -> Arc<Self> {
        Arc::new(Self {
            status: Mutex::new(known_hosts::HOST_UNKNOWN),
            sha256: Mutex::new(String::new()),
            md5: Mutex::new(String::new()),
            line: Mutex::new(String::new()),
        })
    }
}

/// 每次握手独立读取信任文件，不能跨连接缓存过期信任。
pub(crate) type FpCache = known_hosts::FileCache;

pub fn new_cache() -> FpCache {
    OnceLock::new()
}

/// 扫描只观测；真实连接仅在指纹匹配时允许进入认证。
pub(crate) struct ProbeHandler {
    pub fingerprint: Arc<Mutex<Option<String>>>,
    pub forward_slot: Arc<ForwardSlot>,
    pub host_info: Arc<HostKeyInfo>,
    pub policy: Option<HostPolicy>,
    /// true=连接路径（仅匹配允许）；false=扫描路径（仅观测，不认证）
    pub enforce: bool,
    pub real_cache: FpCache,
    pub session_cache: FpCache,
}

impl ProbeHandler {
    fn record_and_decide(&self, key: &russh::keys::PublicKey) -> Result<bool, russh::Error> {
        let sha256 = key.fingerprint(HashAlg::Sha256).to_string();
        // known_hosts 行与 MD5 指纹基于线格式 blob（"algo b64blob comment" 前两段）
        let openssh = key.to_openssh().map_err(|_| russh::Error::UnknownKey)?;
        let mut parts = openssh.split_whitespace();
        let algo_name = parts.next().unwrap_or("").to_string();
        let blob_b64 = parts.next().unwrap_or("").to_string();
        let md5 = blob_md5(&blob_b64);
        let line = known_hosts::trust_line(
            self.policy.as_ref().map(|p| p.host.as_str()).unwrap_or(""),
            self.policy.as_ref().map(|p| p.port).unwrap_or(22),
            &algo_name,
            &blob_b64,
        );

        let mut status = known_hosts::HOST_UNKNOWN;
        if let Some(policy) = &self.policy {
            status = known_hosts::check_status(
                &policy.host,
                policy.port,
                &sha256,
                &policy.real_known_hosts,
                &policy.session_known_hosts,
                &self.real_cache,
                &self.session_cache,
            );
        }

        *self.fingerprint.lock().expect("fingerprint mutex") = Some(sha256);
        *self.host_info.status.lock().expect("status") = status;
        *self.host_info.sha256.lock().expect("sha256") = self
            .fingerprint
            .lock()
            .expect("fingerprint mutex")
            .clone()
            .unwrap_or_default();
        *self.host_info.md5.lock().expect("md5") = md5;
        *self.host_info.line.lock().expect("line") = line;

        // 扫描可观测未知/变更密钥，但认证连接必须有明确的信任记录。
        Ok(!self.enforce || status == known_hosts::HOST_MATCH)
    }
}

/// 解码 known_hosts 风格的 b64 blob 并算 MD5 指纹（"aa:bb:…"）。
fn blob_md5(blob_b64: &str) -> String {
    use data_encoding::BASE64;
    let raw = BASE64.decode(blob_b64.as_bytes()).unwrap_or_default();
    let digest = md5::compute(&raw);
    let hex = format!("{digest:x}");
    let bytes: Vec<&str> = hex
        .as_bytes()
        .chunks(2)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect();
    bytes.join(":")
}

impl client::Handler for ProbeHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        match server_public_key {
            russh::keys::PublicKeyOrCertificate::PublicKey { key, .. } => {
                self.record_and_decide(key)
            }
            // 尚未实现 CA 验证；不能把未经验证的证书当作可信服务器。
            russh::keys::PublicKeyOrCertificate::Certificate(_) => {
                *self.host_info.status.lock().expect("status") = known_hosts::HOST_UNSUPPORTED;
                Ok(false)
            }
        }
    }

    /// -R：服务器转来的新连接通道。无激活的 -R 转发时 drop reply（自动 reject）。
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: russh::Channel<russh::client::Msg>,
        _connected_address: &str,
        _connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: russh::client::ChannelOpenHandle,
        _session: &mut russh::client::Session,
    ) -> Result<(), Self::Error> {
        let sender = self.forward_slot.lock().expect("forward slot").clone();
        if sender.as_ref().is_some_and(|s| !s.is_closed()) {
            reply.accept().await;
            let _ = sender.expect("checked above").send(channel);
        }
        Ok(())
    }
}

fn ensure_auth(result: AuthResult) -> Result<(), String> {
    match result {
        AuthResult::Success => Ok(()),
        AuthResult::Failure { .. } => Err("认证被拒绝".into()),
    }
}

/// 连接 + 握手 + 认证（整体受 timeout 约束）。返回会话句柄、指纹槽、转发槽、主机密钥信息。
#[allow(clippy::too_many_arguments)] // 参数与 libssh2 C ABI 对齐
pub(crate) async fn connect_and_auth(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    key_path: Option<&str>,
    key_passphrase: Option<&str>,
    timeout: Duration,
    policy: Option<HostPolicy>,
) -> Result<
    (
        Handle<ProbeHandler>,
        Arc<Mutex<Option<String>>>,
        Arc<ForwardSlot>,
        Arc<HostKeyInfo>,
    ),
    String,
> {
    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        nodelay: true,
        ..client::Config::default()
    });
    let handler = ProbeHandler {
        fingerprint: Arc::new(Mutex::new(None)),
        forward_slot: Arc::new(Mutex::new(None)),
        host_info: HostKeyInfo::arc_default(),
        real_cache: new_cache(),
        session_cache: new_cache(),
        policy,
        enforce: true,
    };
    let fingerprint = handler.fingerprint.clone();
    let forward_slot = handler.forward_slot.clone();
    let host_info = handler.host_info.clone();
    let mut handle: Handle<ProbeHandler> =
        client::connect(config, format!("{host}:{port}"), handler)
            .await
            .map_err(|e| {
                // 网络/DNS/握手故障不能误报成指纹变化。
                if fingerprint.lock().expect("fingerprint").is_some()
                    || *host_info.status.lock().expect("status") == known_hosts::HOST_UNSUPPORTED
                {
                    match *host_info.status.lock().expect("status") {
                        known_hosts::HOST_UNKNOWN => {
                            "HOSTKEY_UNKNOWN: 尚未信任此主机，请先核对并确认指纹".to_string()
                        }
                        known_hosts::HOST_MISMATCH => {
                            "HOSTKEY_MISMATCH: 主机指纹与历史记录不一致，已停止连接".to_string()
                        }
                        known_hosts::HOST_UNREADABLE => {
                            "HOSTKEY_UNREADABLE: 无法读取或解析主机信任记录，已停止连接".to_string()
                        }
                        known_hosts::HOST_REVOKED => {
                            "HOSTKEY_REVOKED: 此主机密钥已被撤销，已停止连接".to_string()
                        }
                        known_hosts::HOST_UNSUPPORTED => {
                            "HOSTKEY_UNSUPPORTED: 暂不支持此主机的证书验证，已停止连接".to_string()
                        }
                        _ => format!("SSH 握手失败: {e}"),
                    }
                } else {
                    format!("SSH 连接失败: {e}")
                }
            })?;

    let auth = async {
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
            let result = handle
                .authenticate_publickey(user, PrivateKeyWithHashAlg::new(Arc::new(key), hash))
                .await
                .map_err(|e| format!("公钥认证失败: {e}"))?;
            ensure_auth(result)?;
        } else {
            let result = handle
                .authenticate_password(user, password.unwrap_or_default())
                .await
                .map_err(|e| format!("密码认证失败: {e}"))?;
            ensure_auth(result)?;
        }
        Ok(())
    };
    match tokio::time::timeout(timeout, auth).await {
        Ok(Ok(())) => {}
        Ok(Err(message)) => return Err(message),
        Err(_) => return Err("连接/认证超时".into()),
    }

    Ok((handle, fingerprint, forward_slot, host_info))
}

/// 仅握手不认证（主机密钥扫描用）。不匹配也放行，由调用方读观测结果。
pub(crate) async fn handshake_only(
    host: &str,
    port: u16,
    policy: Option<HostPolicy>,
    timeout: Duration,
) -> Result<Arc<HostKeyInfo>, String> {
    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(10)),
        ..client::Config::default()
    });
    let handler = ProbeHandler {
        fingerprint: Arc::new(Mutex::new(None)),
        forward_slot: Arc::new(Mutex::new(None)),
        host_info: HostKeyInfo::arc_default(),
        real_cache: new_cache(),
        session_cache: new_cache(),
        policy,
        enforce: false,
    };
    let host_info = handler.host_info.clone();
    let handle: Handle<ProbeHandler> = client::connect(config, format!("{host}:{port}"), handler)
        .await
        .map_err(|e| format!("握手失败: {e}"))?;
    let _ = tokio::time::timeout(
        timeout,
        handle.disconnect(russh::Disconnect::ByApplication, "scan", "en"),
    )
    .await;
    Ok(host_info)
}

#[cfg(test)]
mod trust_tests {
    use super::*;
    use russh::server::{self, Server as _};
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Clone)]
    struct TestServer(Arc<AtomicUsize>);
    impl server::Server for TestServer {
        type Handler = Self;
        fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
            self.clone()
        }
    }
    impl server::Handler for TestServer {
        type Error = russh::Error;
        async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Ok(server::Auth::Accept)
        }
    }

    #[test]
    fn untrusted_handshake_never_sends_password() {
        crate::runtime().block_on(async {
            let key =
                russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)
                    .unwrap();
            let public = key.public_key().to_openssh().unwrap();
            let other =
                russh::keys::PrivateKey::random(&mut rand::rng(), russh::keys::Algorithm::Ed25519)
                    .unwrap();
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let port = listener.local_addr().unwrap().port();
            let auths = Arc::new(AtomicUsize::new(0));
            let mut server = TestServer(auths.clone());
            let config = Arc::new(server::Config {
                keys: vec![key],
                auth_rejection_time: Duration::ZERO,
                ..Default::default()
            });
            let serving =
                tokio::spawn(async move { server.run_on_socket(config, &listener).await });
            let dir =
                std::env::temp_dir().join(format!("termo-handshake-{}-{port}", std::process::id()));
            std::fs::create_dir(&dir).unwrap();
            let real = dir.join("known_hosts");
            let session = dir.join("session");
            let policy = HostPolicy {
                host: "127.0.0.1".into(),
                port,
                real_known_hosts: real.to_str().unwrap().into(),
                session_known_hosts: session.to_str().unwrap().into(),
            };
            let spec = known_hosts::host_spec("127.0.0.1", port);
            for (record, prefix) in [
                (String::new(), "HOSTKEY_UNKNOWN"),
                (
                    format!("{spec} {}\n", other.public_key().to_openssh().unwrap()),
                    "HOSTKEY_MISMATCH",
                ),
                (
                    format!("{spec} ssh-ed25519 invalid\n"),
                    "HOSTKEY_UNREADABLE",
                ),
                (
                    format!("{spec} {public}\n@revoked {spec} {public}\n"),
                    "HOSTKEY_REVOKED",
                ),
            ] {
                std::fs::write(&real, record).unwrap();
                let result = connect_and_auth(
                    "127.0.0.1",
                    port,
                    "fixture",
                    Some("fixture-only"),
                    None,
                    None,
                    Duration::from_secs(5),
                    Some(policy.clone()),
                )
                .await;
                assert!(result.is_err());
                assert!(
                    result.err().unwrap().starts_with(prefix),
                    "wrong error for {prefix}"
                );
                assert_eq!(
                    auths.load(Ordering::SeqCst),
                    0,
                    "password sent before trust"
                );
            }
            std::fs::write(&real, "").unwrap();
            let scan = handshake_only(
                "127.0.0.1",
                port,
                Some(policy.clone()),
                Duration::from_secs(5),
            )
            .await
            .unwrap();
            assert_eq!(*scan.status.lock().unwrap(), known_hosts::HOST_UNKNOWN);
            assert_eq!(
                auths.load(Ordering::SeqCst),
                0,
                "scan must never authenticate"
            );
            let no_policy = connect_and_auth(
                "127.0.0.1",
                port,
                "fixture",
                Some("fixture-only"),
                None,
                None,
                Duration::from_secs(5),
                None,
            )
            .await;
            assert!(no_policy.err().unwrap().starts_with("HOSTKEY_UNKNOWN"));
            assert_eq!(auths.load(Ordering::SeqCst), 0);
            for saved_in in [&real, &session] {
                std::fs::write(&real, "").unwrap();
                std::fs::write(&session, "").unwrap();
                std::fs::write(saved_in, format!("{spec} {public}\n")).unwrap();
                let (handle, _, _, _) = connect_and_auth(
                    "127.0.0.1",
                    port,
                    "fixture",
                    Some("fixture-only"),
                    None,
                    None,
                    Duration::from_secs(5),
                    Some(policy.clone()),
                )
                .await
                .unwrap();
                handle
                    .disconnect(russh::Disconnect::ByApplication, "done", "en")
                    .await
                    .unwrap();
            }
            assert_eq!(
                auths.load(Ordering::SeqCst),
                2,
                "persistent/session matches may authenticate"
            );
            serving.abort();
            let _ = serving.await;
            std::fs::remove_dir_all(dir).unwrap();
        });
    }

    #[test]
    fn refused_tcp_is_not_reported_as_changed_fingerprint() {
        crate::runtime().block_on(async {
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let port = listener.local_addr().unwrap().port();
            drop(listener);
            let error = connect_and_auth(
                "127.0.0.1",
                port,
                "fixture",
                Some("fixture-only"),
                None,
                None,
                Duration::from_secs(1),
                None,
            )
            .await
            .err()
            .unwrap();
            assert!(
                !error.starts_with("HOSTKEY_"),
                "network failure misreported: {error}"
            );
        });
    }
}
