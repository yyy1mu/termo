//! All authenticated connections require a trusted host key. The scan path only
//! observes keys; it never authenticates. Each handshake reads a fresh snapshot.
use data_encoding::{BASE64, BASE64_NOPAD};
use hmac::{Hmac, KeyInit, Mac};
use sha2::Digest;
use std::sync::OnceLock;

pub const HOST_MATCH: i32 = 0;
pub const HOST_UNKNOWN: i32 = 1;
pub const HOST_MISMATCH: i32 = 2;
pub const HOST_UNREADABLE: i32 = 3;
pub const HOST_REVOKED: i32 = 4;
pub const HOST_UNSUPPORTED: i32 = 5;

#[derive(Clone)]
pub(crate) struct Entry {
    patterns: String,
    fingerprint: Option<String>,
    revoked: bool,
    authority: bool,
}
pub(crate) type FileCache = OnceLock<Result<Vec<Entry>, ()>>;

pub fn host_spec(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

pub fn blob_fingerprint(blob: &str) -> Option<String> {
    let raw = BASE64
        .decode(blob.as_bytes())
        .or_else(|_| BASE64_NOPAD.decode(blob.as_bytes()))
        .ok()?;
    Some(format!(
        "SHA256:{}",
        BASE64_NOPAD.encode(&sha2::Sha256::digest(raw))
    ))
}

fn load(path: &str) -> Result<Vec<Entry>, ()> {
    if path.is_empty() {
        return Ok(Vec::new());
    }
    let content = match std::fs::read_to_string(path) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(_) => return Err(()),
    };
    let mut entries = Vec::new();
    for line in content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
    {
        let mut fields = line.split_whitespace();
        let first = fields.next().unwrap_or("");
        let (marker, patterns) = if first.starts_with('@') {
            (first, fields.next().ok_or(())?)
        } else {
            ("", first)
        };
        let algorithm = fields.next();
        let blob = fields.next();
        let fingerprint = match (algorithm, blob) {
            (Some(algorithm), Some(blob))
                if marker.is_empty() || marker == "@revoked" || marker == "@cert-authority" =>
            {
                // A malformed matching record cannot silently become an unknown host.
                russh::keys::parse_public_key_base64(blob)
                    .ok()
                    .filter(|key| key.algorithm().as_str() == algorithm)
                    .and_then(|_| blob_fingerprint(blob))
            }
            _ => None,
        };
        entries.push(Entry {
            patterns: patterns.to_string(),
            fingerprint,
            revoked: marker == "@revoked",
            authority: marker == "@cert-authority",
        });
    }
    Ok(entries)
}

fn wildcard_match(pattern: &str, value: &str) -> bool {
    let (p, v) = (pattern.as_bytes(), value.as_bytes());
    let (mut i, mut j, mut star, mut resume) = (0, 0, None, 0);
    while j < v.len() {
        if i < p.len() && (p[i] == b'?' || p[i].eq_ignore_ascii_case(&v[j])) {
            i += 1;
            j += 1;
        } else if i < p.len() && p[i] == b'*' {
            star = Some(i);
            i += 1;
            resume = j;
        } else if let Some(s) = star {
            resume += 1;
            j = resume;
            i = s + 1;
        } else {
            return false;
        }
    }
    while i < p.len() && p[i] == b'*' {
        i += 1;
    }
    i == p.len()
}

fn pattern_matches(pattern: &str, spec: &str) -> bool {
    if let Some(hash) = pattern.strip_prefix("|1|") {
        let Some((salt, expected)) = hash.split_once('|') else {
            return false;
        };
        let (Ok(salt), Ok(expected)) = (
            BASE64.decode(salt.as_bytes()),
            BASE64.decode(expected.as_bytes()),
        ) else {
            return false;
        };
        let Ok(mut mac) = Hmac::<sha1::Sha1>::new_from_slice(&salt) else {
            return false;
        };
        mac.update(spec.as_bytes());
        mac.verify_slice(&expected).is_ok()
    } else {
        wildcard_match(pattern, spec)
    }
}

fn matches_host(patterns: &str, spec: &str) -> bool {
    let mut matched = false;
    for pattern in patterns.split(',') {
        if let Some(negative) = pattern.strip_prefix('!') {
            if pattern_matches(negative, spec) {
                return false;
            }
        } else if pattern_matches(pattern, spec) {
            matched = true;
        }
    }
    matched
}

/// Revocation and unreadable/malformed records win over matches, across both files.
pub(crate) fn check_status(
    host: &str,
    port: u16,
    fingerprint: &str,
    real_known_hosts: &str,
    session_known_hosts: &str,
    real_cache: &FileCache,
    session_cache: &FileCache,
) -> i32 {
    let spec = host_spec(host, port);
    let mut has_entry = false;
    let mut matched = false;
    for entries in [
        real_cache.get_or_init(|| load(real_known_hosts)),
        session_cache.get_or_init(|| load(session_known_hosts)),
    ] {
        let Ok(entries) = entries else {
            return HOST_UNREADABLE;
        };
        for entry in entries
            .iter()
            .filter(|entry| matches_host(&entry.patterns, &spec))
        {
            let Some(recorded) = &entry.fingerprint else {
                return HOST_UNREADABLE;
            };
            if entry.revoked {
                if recorded == fingerprint {
                    return HOST_REVOKED;
                }
                continue;
            }
            // A CA record is not direct trust in the server's ordinary public key.
            if entry.authority {
                continue;
            }
            has_entry = true;
            matched |= recorded == fingerprint;
        }
    }
    if matched {
        HOST_MATCH
    } else if has_entry {
        HOST_MISMATCH
    } else {
        HOST_UNKNOWN
    }
}

pub fn trust_line(host: &str, port: u16, algorithm_name: &str, blob_b64: &str) -> String {
    format!("{} {} {}", host_spec(host, port), algorithm_name, blob_b64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    const BLOB: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIJdD7y3aLq454yWBdwLWbieU1ebz9/cu7/QEXn9OIeZJ";
    static SEQ: AtomicUsize = AtomicUsize::new(0);
    fn check(real: &str, session: &str, host: &str, port: u16, fingerprint: &str) -> i32 {
        let dir = std::env::temp_dir().join(format!(
            "termo-known-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&dir).unwrap();
        let a = dir.join("real");
        let b = dir.join("session");
        std::fs::write(&a, real).unwrap();
        std::fs::write(&b, session).unwrap();
        let result = check_status(
            host,
            port,
            fingerprint,
            a.to_str().unwrap(),
            b.to_str().unwrap(),
            &OnceLock::new(),
            &OnceLock::new(),
        );
        std::fs::remove_dir_all(dir).unwrap();
        result
    }
    #[test]
    fn saved_and_session_fingerprints_match() {
        let fp = blob_fingerprint(BLOB).unwrap();
        let line = format!("host,alias ssh-ed25519 {BLOB}\n");
        assert_eq!(check(&line, "", "host", 22, &fp), HOST_MATCH);
        assert_eq!(check("", &line, "alias", 22, &fp), HOST_MATCH);
        assert_eq!(
            check(&line, "", "host", 22, "SHA256:changed"),
            HOST_MISMATCH
        );
        assert_eq!(check(&line, "", "new", 22, &fp), HOST_UNKNOWN);
    }
    #[test]
    fn hashed_host_and_nonstandard_port() {
        let spec = host_spec("2001:db8::1", 2222);
        let salt = b"fixture-salt";
        let mut mac = Hmac::<sha1::Sha1>::new_from_slice(salt).unwrap();
        mac.update(spec.as_bytes());
        let line = format!(
            "|1|{}|{} ssh-ed25519 {BLOB}\n",
            BASE64.encode(salt),
            BASE64.encode(&mac.finalize().into_bytes())
        );
        assert_eq!(
            check(
                &line,
                "",
                "2001:db8::1",
                2222,
                &blob_fingerprint(BLOB).unwrap()
            ),
            HOST_MATCH
        );
        assert_eq!(
            check(&line, "", "2001:db8::1", 2222, "changed"),
            HOST_MISMATCH
        );
        assert_eq!(check(&line, "", "2001:db8::1", 22, "changed"), HOST_UNKNOWN);
    }
    #[test]
    fn wildcard_negation_is_not_revocation() {
        let line = format!("*.example.com,!excluded.example.com ssh-ed25519 {BLOB}\n");
        let fp = blob_fingerprint(BLOB).unwrap();
        assert_eq!(check(&line, "", "prod.example.com", 22, &fp), HOST_MATCH);
        assert_eq!(
            check(&line, "", "excluded.example.com", 22, &fp),
            HOST_UNKNOWN
        );
    }
    #[test]
    fn revoked_wins_over_any_saved_or_session_match() {
        let line = format!("host ssh-ed25519 {BLOB}\n");
        let revoked = format!("@revoked host ssh-ed25519 {BLOB}\n");
        let fp = blob_fingerprint(BLOB).unwrap();
        assert_eq!(check(&line, &revoked, "host", 22, &fp), HOST_REVOKED);
        assert_eq!(check(&(revoked + &line), "", "host", 22, &fp), HOST_REVOKED);
    }
    #[test]
    fn malformed_record_and_unreadable_file_fail_closed() {
        assert_eq!(
            check("host ssh-ed25519 invalid\n", "", "host", 22, "fp"),
            HOST_UNREADABLE
        );
        assert_eq!(
            check_status(
                "host",
                22,
                "fp",
                "/",
                "",
                &OnceLock::new(),
                &OnceLock::new()
            ),
            HOST_UNREADABLE
        );
    }
    #[test]
    fn certificate_authority_is_not_direct_host_trust() {
        assert_eq!(
            check(
                &format!("@cert-authority host ssh-ed25519 {BLOB}\n"),
                "",
                "host",
                22,
                &blob_fingerprint(BLOB).unwrap()
            ),
            HOST_UNKNOWN
        );
    }
    #[test]
    fn each_handshake_reloads_trust_files() {
        let path = std::env::temp_dir().join(format!("termo-reload-{}", std::process::id()));
        std::fs::write(&path, format!("host ssh-ed25519 {BLOB}\n")).unwrap();
        let fp = blob_fingerprint(BLOB).unwrap();
        assert_eq!(
            check_status(
                "host",
                22,
                &fp,
                path.to_str().unwrap(),
                "",
                &OnceLock::new(),
                &OnceLock::new()
            ),
            HOST_MATCH
        );
        std::fs::write(&path, "").unwrap();
        assert_eq!(
            check_status(
                "host",
                22,
                &fp,
                path.to_str().unwrap(),
                "",
                &OnceLock::new(),
                &OnceLock::new()
            ),
            HOST_UNKNOWN
        );
        std::fs::remove_file(path).unwrap();
    }
}
