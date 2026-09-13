//! 连接与认证：ProbeHandler 记录主机指纹，connect_and_auth 供会话与探针共用。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};

/// -R 转发路由槽：forward_open 安装发送端，Handler 回调投递服务器转来的通道。
pub(crate) type ForwardSlot =
    Mutex<Option<tokio::sync::mpsc::UnboundedSender<russh::Channel<russh::client::Msg>>>>;

/// PoC 阶段对未知主机一律放行（与现有 libssh2 引擎的保守口径一致），
/// 但把指纹带回给调用方；信任策略（known_hosts / 弹窗）后续在 Swift 侧接入。
#[derive(Debug, Default)]
pub(crate) struct ProbeHandler {
    pub fingerprint: Arc<Mutex<Option<String>>>,
    pub forward_slot: Arc<ForwardSlot>,
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

/// 连接 + 握手 + 认证（整体受 timeout 约束）。返回会话句柄与指纹槽。
pub(crate) async fn connect_and_auth(
    host: &str,
    port: u16,
    user: &str,
    password: Option<&str>,
    key_path: Option<&str>,
    key_passphrase: Option<&str>,
    timeout: Duration,
) -> Result<
    (
        Handle<ProbeHandler>,
        Arc<Mutex<Option<String>>>,
        Arc<ForwardSlot>,
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
    let handler = ProbeHandler::default();
    let fingerprint = handler.fingerprint.clone();
    let handler_slot = handler.forward_slot.clone();
    let fut = async {
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
        Ok::<_, String>(handle)
    };
    let handle = match tokio::time::timeout(timeout, fut).await {
        Ok(result) => result,
        Err(_) => Err("连接/认证超时".into()),
    }?;

    Ok((handle, fingerprint, handler_slot))
}
