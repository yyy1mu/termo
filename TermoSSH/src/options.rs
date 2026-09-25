//! Validated per-host transport options shared by scanning, diagnostics and sessions.
use std::{borrow::Cow, ffi::c_char, time::Duration};

#[repr(C)]
pub struct ConnectionOptionsFFI {
    timeout_ms: i32,
    heartbeat_ms: i32,
    proxy_kind: i32,
    proxy_port: i32,
    proxy_host: *const c_char,
    host_key_algos: *const c_char,
    ciphers: *const c_char,
    kex_algos: *const c_char,
}

#[derive(Clone, Debug)]
pub struct ConnectionOptions {
    pub timeout: Duration,
    pub heartbeat: Option<Duration>,
    pub proxy: Option<Proxy>,
    pub preferred: russh::Preferred,
}

#[derive(Clone, Debug)]
pub struct Proxy {
    pub kind: i32,
    pub host: String,
    pub port: u16,
}

impl Default for ConnectionOptions {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(10),
            heartbeat: Some(Duration::from_secs(5)),
            proxy: None,
            preferred: russh::Preferred::default(),
        }
    }
}

impl ConnectionOptions {
    /// # Safety
    /// All non-null string pointers are NUL-terminated and remain valid during this read.
    pub unsafe fn read(raw: *const ConnectionOptionsFFI) -> Result<Self, String> {
        let Some(raw) = raw.as_ref() else {
            return Ok(Self::default());
        };
        if !(1000..=300000).contains(&raw.timeout_ms)
            || !(0..=3600000).contains(&raw.heartbeat_ms)
            || (raw.heartbeat_ms > 0 && raw.heartbeat_ms < 1000)
        {
            return Err("连接超时需为 1000–300000 ms；心跳为 0（关闭）或 1000–3600000 ms".into());
        }
        let mut out = Self {
            timeout: Duration::from_millis(raw.timeout_ms as u64),
            heartbeat: (raw.heartbeat_ms > 0)
                .then(|| Duration::from_millis(raw.heartbeat_ms as u64)),
            ..Self::default()
        };
        if raw.proxy_kind != 0 {
            let host = crate::read_str(raw.proxy_host);
            if ![1, 2].contains(&raw.proxy_kind)
                || host.is_empty()
                || !(1..=65535).contains(&raw.proxy_port)
            {
                return Err("代理配置无效".into());
            }
            out.proxy = Some(Proxy {
                kind: raw.proxy_kind,
                host,
                port: raw.proxy_port as u16,
            });
        }
        let key = crate::read_str(raw.host_key_algos);
        let cipher = crate::read_str(raw.ciphers);
        let kex = crate::read_str(raw.kex_algos);
        if !key.is_empty() {
            let supported = [
                "ssh-ed25519",
                "rsa-sha2-512",
                "rsa-sha2-256",
                "ssh-rsa",
                "ecdsa-sha2-nistp256",
                "ecdsa-sha2-nistp384",
                "ecdsa-sha2-nistp521",
            ];
            out.preferred.key = Cow::Owned(parse_list(&key, |v| {
                if !supported.contains(&v) {
                    return None;
                }
                v.parse::<russh::keys::Algorithm>().ok()
            })?);
        }
        if !cipher.is_empty() {
            out.preferred.cipher = Cow::Owned(parse_list(&cipher, |v| {
                if v == "none" {
                    return None;
                }
                russh::cipher::Name::try_from(v).ok()
            })?);
        }
        if !kex.is_empty() {
            out.preferred.kex = Cow::Owned(parse_list(&kex, |v| {
                if v == "none" || v.starts_with("ext-info-") || v.starts_with("kex-strict-") {
                    return None;
                }
                russh::kex::Name::try_from(v).ok()
            })?);
        }
        Ok(out)
    }

    pub fn config(&self) -> russh::client::Config {
        russh::client::Config {
            preferred: self.preferred.clone(),
            inactivity_timeout: None,
            keepalive_interval: self.heartbeat,
            keepalive_max: 3,
            nodelay: true,
            ..Default::default()
        }
    }
}

fn parse_list<T>(value: &str, parse: impl Fn(&str) -> Option<T>) -> Result<Vec<T>, String> {
    value
        .split(',')
        .map(|v| parse(v.trim()).ok_or_else(|| format!("不支持的 SSH 算法: {}", v.trim())))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn raw(values: &[CString; 4], timeout: i32, heartbeat: i32) -> ConnectionOptionsFFI {
        ConnectionOptionsFFI {
            timeout_ms: timeout,
            heartbeat_ms: heartbeat,
            proxy_kind: 1,
            proxy_port: 1080,
            proxy_host: values[0].as_ptr(),
            host_key_algos: values[1].as_ptr(),
            ciphers: values[2].as_ptr(),
            kex_algos: values[3].as_ptr(),
        }
    }

    #[test]
    fn parses_all_transport_settings() {
        let values = [
            "proxy.local",
            "ssh-ed25519",
            "aes256-ctr",
            "curve25519-sha256",
        ]
        .map(|value| CString::new(value).unwrap());
        let raw = raw(&values, 12_345, 6_789);
        let options = unsafe { ConnectionOptions::read(&raw) }.unwrap();
        assert_eq!(options.timeout, Duration::from_millis(12_345));
        assert_eq!(options.heartbeat, Some(Duration::from_millis(6_789)));
        let proxy = options.proxy.unwrap();
        assert_eq!(
            (proxy.kind, proxy.host.as_str(), proxy.port),
            (1, "proxy.local", 1080)
        );
        assert_eq!(options.preferred.key.len(), 1);
        assert_eq!(options.preferred.cipher.len(), 1);
        assert_eq!(options.preferred.kex.len(), 1);
    }

    #[test]
    fn rejects_invalid_ranges_and_unknown_algorithms() {
        let values =
            ["proxy.local", "", "not-a-cipher", ""].map(|value| CString::new(value).unwrap());
        let invalid_timeout = raw(&values, 999, 5_000);
        assert!(unsafe { ConnectionOptions::read(&invalid_timeout) }.is_err());
        let invalid_algorithm = raw(&values, 10_000, 0);
        assert!(unsafe { ConnectionOptions::read(&invalid_algorithm) }
            .unwrap_err()
            .contains("not-a-cipher"));
    }

    #[test]
    fn accepts_every_algorithm_presented_by_the_host_editor() {
        let host_keys = [
            "ssh-ed25519",
            "rsa-sha2-512",
            "rsa-sha2-256",
            "ecdsa-sha2-nistp256",
            "ecdsa-sha2-nistp384",
            "ecdsa-sha2-nistp521",
            "ssh-rsa",
        ];
        let ciphers = [
            "chacha20-poly1305@openssh.com",
            "aes256-gcm@openssh.com",
            "aes128-gcm@openssh.com",
            "aes256-ctr",
            "aes192-ctr",
            "aes128-ctr",
            "aes256-cbc",
            "aes128-cbc",
        ];
        let kex = [
            "mlkem768x25519-sha256",
            "curve25519-sha256",
            "curve25519-sha256@libssh.org",
            "ecdh-sha2-nistp256",
            "ecdh-sha2-nistp384",
            "ecdh-sha2-nistp521",
            "diffie-hellman-group-exchange-sha256",
            "diffie-hellman-group16-sha512",
            "diffie-hellman-group14-sha256",
            "diffie-hellman-group14-sha1",
        ];

        for value in host_keys {
            assert!(value.parse::<russh::keys::Algorithm>().is_ok(), "{value}");
        }
        for value in ciphers {
            assert!(russh::cipher::Name::try_from(value).is_ok(), "{value}");
        }
        for value in kex {
            assert!(russh::kex::Name::try_from(value).is_ok(), "{value}");
        }
    }
}
