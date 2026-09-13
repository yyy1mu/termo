//! 连接与认证：ProbeHandler 记录主机指纹，connect_and_auth 供会话与探针共用。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::{self, AuthResult, Handle};
use russh::keys::{HashAlg, PrivateKeyWithHashAlg};

/// PoC 阶段对未知主机一律放行（与现有 libssh2 引擎的保守口径一致），
/// 但把指纹带回给调用方；信任策略（known_hosts / 弹窗）后续在 Swift 侧接入。
#[derive(Debug, Default)]
pub(crate) struct ProbeHandler {
    pub fingerprint: Arc<Mutex<Option<String>>>,
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
) -> Result<(Handle<ProbeHandler>, Arc<Mutex<Option<String>>>), String> {
    let config = Arc::new(client::Config {
        inactivity_timeout: Some(Duration::from_secs(30)),
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        nodelay: true,
        ..client::Config::default()
    });
    let handler = ProbeHandler::default();
    let fingerprint = handler.fingerprint.clone();
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

    Ok((handle, fingerprint))
}
