//! 密钥工具：对标 libssh2 引擎 `termo_key_*`——
//! Ed25519 / RSA-4096 生成、OpenSSH 私钥文本导出（口令经 AES-256-CTR + bcrypt KDF 加密，
//! 与现有 ed25519 输出格式一致）、从私钥文件派生公钥行（OpenSSH 容器加密态也可派生）、
//! 公钥行 SHA-256 指纹。纯 CPU 实现，不依赖 OpenSSL（替代 TermoKeyGen.c 的关键一步）。
//!
//! 注：新生成的 RSA 私钥为 OpenSSH 格式（原实现为 PKCS#8 PEM）；两者服务器均接受，
//! 但与旧版生成的文件字节不兼容（仅影响新生成的密钥）。

use russh::keys::ssh_key::LineEnding;
use russh::keys::{Algorithm, HashAlg, PrivateKey, PublicKey};

/// FFI key type：0=ed25519 1=rsa(4096)（与 termo_key_generate 同义）。
pub const KEY_TYPE_ED25519: i32 = 0;
pub const KEY_TYPE_RSA: i32 = 1;

/// 生成结果：私钥文本（OpenSSH）、公钥行、"SHA256:…" 指纹。
#[derive(Debug, Clone)]
pub struct GeneratedKey {
    pub private_openssh: String,
    pub public_line: String,
    pub fingerprint: String,
}

/// 私钥→公钥派生结果（rc=1 场景单列，供 FFI 区分）。
#[derive(Debug, Clone)]
pub enum PubkeyDerive {
    /// 派生成功；encrypted 表示源私钥处于加密态。
    Ok {
        public_line: String,
        key_type: i32,
        encrypted: bool,
    },
    /// 加密 PEM 且未提供口令：无法派生（与 libssh2 版 rc=1 对应）。
    EncryptedPemNoPassphrase,
}

fn key_type_of(algorithm: Algorithm) -> i32 {
    match algorithm {
        Algorithm::Rsa { .. } => KEY_TYPE_RSA,
        // 与原实现口径一致：OpenSSH 容器内未显式识别的类型默认按 ed25519 上报
        _ => KEY_TYPE_ED25519,
    }
}

fn public_line_of(key: &PrivateKey) -> Result<String, String> {
    key.public_key()
        .to_openssh()
        .map_err(|e| format!("公钥编码失败: {e}"))
}

/// 生成密钥对。passphrase 非空则加密私钥（OpenSSH 容器 + bcrypt KDF）。
pub fn generate(key_type: i32, comment: &str, passphrase: &str) -> Result<GeneratedKey, String> {
    let algorithm = match key_type {
        KEY_TYPE_ED25519 => Algorithm::Ed25519,
        KEY_TYPE_RSA => Algorithm::Rsa { hash: None },
        other => return Err(format!("类型须为 0/1，收到 {other}")),
    };
    let mut key =
        PrivateKey::random(&mut rand::rng(), algorithm).map_err(|e| format!("生成失败: {e}"))?;
    if !comment.is_empty() {
        key.set_comment(comment);
    }
    if !passphrase.is_empty() {
        key = key
            .encrypt(&mut rand::rng(), passphrase)
            .map_err(|e| format!("私钥加密失败: {e}"))?;
    }
    let private_openssh = key
        .to_openssh(LineEnding::LF)
        .map_err(|e| format!("私钥编码失败: {e}"))?
        .to_string();
    let public_line = public_line_of(&key)?;
    let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
    Ok(GeneratedKey {
        private_openssh,
        public_line,
        fingerprint,
    })
}

/// 从私钥文件派生公钥行。OpenSSH 容器（含加密态）总能派生；
/// 传统 PEM 仅在未加密或提供口令时可派生。
pub fn pubkey_from_private(path: &str, passphrase: &str) -> Result<PubkeyDerive, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("读取私钥失败: {e}"))?;
    if bytes.len() > 1024 * 1024 {
        return Err("私钥文件过大（>1MiB）".into());
    }
    let text = String::from_utf8_lossy(&bytes);

    if text.contains("BEGIN OPENSSH PRIVATE KEY") {
        // 容器公开段为明文：无需口令即可派生（与原实现口径一致）
        let key = PrivateKey::from_openssh(&bytes).map_err(|e| format!("解析私钥失败: {e}"))?;
        let encrypted = key.is_encrypted();
        let key_type = key_type_of(key.algorithm());
        let public_line = public_line_of(&key)?;
        return Ok(PubkeyDerive::Ok {
            public_line,
            key_type,
            encrypted,
        });
    }

    // 传统 PEM / PKCS#8
    let encrypted_pem = text.contains("ENCRYPTED");
    if encrypted_pem && passphrase.is_empty() {
        return Ok(PubkeyDerive::EncryptedPemNoPassphrase);
    }
    let key = russh::keys::load_secret_key(path, (!passphrase.is_empty()).then_some(passphrase))
        .map_err(|e| format!("解析私钥失败: {e}"))?;
    let key_type = key_type_of(key.algorithm());
    let public_line = public_line_of(&key)?;
    Ok(PubkeyDerive::Ok {
        public_line,
        key_type,
        encrypted: encrypted_pem,
    })
}

/// 由公钥行计算 "SHA256:…" 指纹。
pub fn fingerprint_of_public(pub_line: &str) -> Result<String, String> {
    let public = PublicKey::from_openssh(pub_line).map_err(|e| format!("解析公钥失败: {e}"))?;
    Ok(public.fingerprint(HashAlg::Sha256).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_key_path(tag: &str) -> std::path::PathBuf {
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::SeqCst);
        std::env::temp_dir().join(format!("termo-ssh-test-{tag}-{}-{n}", std::process::id()))
    }

    #[test]
    fn ed25519_generate_roundtrip_and_fingerprint() {
        let key = generate(KEY_TYPE_ED25519, "test@termo", "").expect("generate");
        assert!(key
            .private_openssh
            .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
        assert!(key.fingerprint.starts_with("SHA256:"));
        // 公钥行 ↔ 指纹一致性
        let fp = fingerprint_of_public(&key.public_line).expect("fp");
        assert_eq!(fp, key.fingerprint);
        // 私钥可回读，且指纹一致
        let parsed = PrivateKey::from_openssh(key.private_openssh.as_bytes()).expect("parse");
        assert_eq!(
            parsed.fingerprint(HashAlg::Sha256).to_string(),
            key.fingerprint
        );
    }

    #[test]
    fn ed25519_encrypted_roundtrip() {
        let key = generate(KEY_TYPE_ED25519, "", "secret-pass").expect("generate");
        let parsed = PrivateKey::from_openssh(key.private_openssh.as_bytes()).expect("parse");
        assert!(parsed.is_encrypted());
        // 正确口令可解密、错误口令被拒
        assert!(parsed.decrypt("secret-pass").is_ok());
        assert!(parsed.decrypt("wrong-pass").is_err());
    }

    #[test]
    fn pubkey_from_private_openssh_encrypted_without_passphrase() {
        let key = generate(KEY_TYPE_ED25519, "enc@termo", "pw").expect("generate");
        let path = temp_key_path("ed-enc");
        std::fs::write(&path, &key.private_openssh).expect("write");
        let derived = pubkey_from_private(path.to_str().expect("utf8"), "").expect("derive");
        match derived {
            PubkeyDerive::Ok {
                public_line,
                key_type,
                encrypted,
            } => {
                assert_eq!(public_line, key.public_line);
                assert_eq!(key_type, KEY_TYPE_ED25519);
                assert!(encrypted);
            }
            other => panic!("期望派生成功，得到 {other:?}"),
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn encrypted_pem_without_passphrase_reports_rc1() {
        // 伪造一个「加密 PEM」文件：只要包含 ENCRYPTED 且非 OpenSSH 容器即命中路径
        let path = temp_key_path("pem-enc");
        std::fs::write(
            &path,
            "-----BEGIN ENCRYPTED PRIVATE KEY-----\nYWJj\n-----END ENCRYPTED PRIVATE KEY-----\n",
        )
        .expect("write");
        let derived = pubkey_from_private(path.to_str().expect("utf8"), "");
        assert!(matches!(
            derived,
            Ok(PubkeyDerive::EncryptedPemNoPassphrase)
        ));
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn rsa4096_generate_and_type_detection() {
        let key = generate(KEY_TYPE_RSA, "rsa@termo", "").expect("generate rsa");
        let path = temp_key_path("rsa");
        std::fs::write(&path, &key.private_openssh).expect("write");
        let derived = pubkey_from_private(path.to_str().expect("utf8"), "").expect("derive");
        match derived {
            PubkeyDerive::Ok {
                public_line,
                key_type,
                encrypted,
            } => {
                assert_eq!(public_line, key.public_line);
                assert_eq!(key_type, KEY_TYPE_RSA);
                assert!(!encrypted);
            }
            other => panic!("期望派生成功，得到 {other:?}"),
        }
        assert!(key.public_line.starts_with("ssh-rsa "));
        let _ = std::fs::remove_file(path);
    }
}
