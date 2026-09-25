//! SFTP：对标 libssh2 引擎 `termo_sftp_*` 的语义——
//! offset 读写（32 KiB 分块）、EOF 语义（0）、SFTP 状态码透传（>0 且 <0xF000）、
//! 传输/协议错误映射 ≥0xF000（上层据此粘住失败、回退 shell）、posix-rename 原子覆盖
//! （extended 扩展；失败原样返回，不删除目标、不自动重放改名）。
//!
//! 已知限制（沿用 russh-sftp 3.0.0）：文件名为 UTF-8（非 UTF-8 见其 issue #42 wontfix）。

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use russh_sftp::client::error::Error as RawSftpError;
use russh_sftp::client::RawSftpSession;
use russh_sftp::protocol::File;
use russh_sftp::protocol::{FileAttributes, OpenFlags, Packet, StatusCode};

use crate::runtime;
use crate::session::RusshSession;

/// FFI 错误码：>0 且 <0xF000 = SFTP 协议状态码；≥0xF000 = 传输/内部错误。
pub(crate) const TRANSPORT_BASE: i32 = 0xF000;
/// 单请求分块上限（与 OpenSSH 写包上限一致，覆盖 limits@openssh.com 常见值）。
const CHUNK: u32 = 32 * 1024;
/// init/subsystem 设置阶段超时。
const INIT_TIMEOUT: Duration = Duration::from_secs(15);

/// SFTP 操作错误：状态码 + 文案（对齐 Swift 侧 SFTPError 语义）。
#[derive(Debug)]
pub struct SftpOpError {
    pub code: i32,
    pub message: String,
}

impl SftpOpError {
    pub fn is_transport(&self) -> bool {
        self.code >= TRANSPORT_BASE
    }
}

fn map_error(e: RawSftpError) -> SftpOpError {
    match e {
        RawSftpError::Status(status) => SftpOpError {
            code: status.status_code as u32 as i32,
            message: status.error_message,
        },
        other => SftpOpError {
            code: TRANSPORT_BASE + 1,
            message: format!("SFTP 传输错误: {other}"),
        },
    }
}

/// 已初始化的 SFTP 子系统会话（对应 libssh2 侧 `LIBSSH2_SFTP*`）。
pub struct RusshSftp {
    raw: Arc<RawSftpSession>,
    /// 最近一次失败的状态码（对齐 libssh2 last_errno；open/opendir 返回 NULL 时供上层取因）。
    last_code: std::sync::atomic::AtomicI32,
}

/// 打开的文件/目录句柄（对应 libssh2 侧文件句柄；持有会话 Arc → 句柄级操作无需会话）。
pub struct RusshSftpFile {
    raw: Arc<RawSftpSession>,
    handle: String,
    /// 目录句柄的未读条目缓冲（readdir 逐个弹出）。
    dir: Option<VecDeque<File>>,
}

/// 归一化后的文件属性（对齐 TermoSFTPAttrs：仅本端用到的字段 + has_* 标记）。
#[derive(Debug, Default, Clone, Copy)]
pub struct SftpAttrs {
    pub has_size: bool,
    pub has_perm: bool,
    pub has_mtime: bool,
    pub size: u64,
    pub permissions: u32,
    pub mtime: u32,
}

fn from_wire_attrs(a: FileAttributes) -> SftpAttrs {
    SftpAttrs {
        has_size: a.size.is_some(),
        has_perm: a.permissions.is_some(),
        has_mtime: a.mtime.is_some(),
        size: a.size.unwrap_or(0),
        permissions: a.permissions.unwrap_or(0),
        mtime: a.mtime.unwrap_or(0),
    }
}

fn wire_attrs_for_create() -> FileAttributes {
    FileAttributes {
        permissions: Some(0o100_644),
        ..Default::default()
    }
}

impl RusshSession {
    /// 在已认证会话上开 session channel + sftp 子系统并完成握手。
    pub async fn sftp_init(&self) -> Result<RusshSftp, String> {
        let channel = self
            .inner()
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
        let setup = async {
            channel
                .request_subsystem(true, "sftp")
                .await
                .map_err(|e| format!("子系统请求失败: {e}"))?;
            let raw = RawSftpSession::new_with_config(
                channel.into_stream(),
                russh_sftp::client::Config {
                    request_timeout_secs: 20,
                    ..russh_sftp::client::Config::default()
                },
            );
            raw.init()
                .await
                .map_err(|e| format!("SFTP 初始化失败: {e}"))?;
            Ok(RusshSftp {
                raw: Arc::new(raw),
                last_code: std::sync::atomic::AtomicI32::new(0),
            })
        };
        match tokio::time::timeout(INIT_TIMEOUT, setup).await {
            Ok(Ok(sftp)) => Ok(sftp),
            Ok(Err(message)) => Err(message),
            Err(_) => Err("SFTP 初始化超时".into()),
        }
    }

    /// 阻塞版 sftp_init（供 C ABI / CLI；panic 隔离）。
    pub fn sftp_init_blocking(&self) -> Result<RusshSftp, String> {
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            runtime().block_on(self.sftp_init())
        }))
        .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
    }
}

type SftpResult<T> = Result<T, SftpOpError>;

impl RusshSftp {
    async fn op<T>(
        &self,
        fut: impl std::future::Future<Output = Result<T, RawSftpError>>,
    ) -> SftpResult<T> {
        fut.await.map_err(|e| {
            let mapped = map_error(e);
            self.last_code
                .store(mapped.code, std::sync::atomic::Ordering::SeqCst);
            mapped
        })
    }

    /// 最近一次失败的状态码（对齐 libssh2 last_errno）。
    pub fn last(&self) -> i32 {
        self.last_code.load(std::sync::atomic::Ordering::SeqCst)
    }

    /// 显式记录状态码（open/opendir 失败路径由 FFI 写入）。
    pub fn set_last(&self, code: i32) {
        self.last_code
            .store(code, std::sync::atomic::Ordering::SeqCst);
    }

    pub async fn stat(&self, path: &str, follow: bool) -> SftpResult<SftpAttrs> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            let wrapped = if follow {
                raw.stat(&path).await?
            } else {
                raw.lstat(&path).await?
            };
            Ok(from_wire_attrs(wrapped.attrs))
        })
        .await
    }

    pub async fn set_permissions(&self, path: &str, mode: u32) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            raw.setstat(
                path,
                FileAttributes {
                    permissions: Some(mode & 0o7777),
                    ..Default::default()
                },
            )
            .await?;
            Ok(())
        })
        .await
    }

    pub async fn mkdir(&self, path: &str) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            raw.mkdir(
                path,
                FileAttributes {
                    permissions: Some(0o100_755),
                    ..Default::default()
                },
            )
            .await?;
            Ok(())
        })
        .await
    }

    pub async fn rmdir(&self, path: &str) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            raw.rmdir(path).await?;
            Ok(())
        })
        .await
    }

    pub async fn remove(&self, path: &str) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            raw.remove(path).await?;
            Ok(())
        })
        .await
    }

    /// 改名（不覆盖；目标存在时服务器返回 Failure=4，与 libssh2 版一致透传）。
    pub async fn rename(&self, from: &str, to: &str) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let (from, to) = (from.to_string(), to.to_string());
        self.op(async move {
            raw.rename(from, to).await?;
            Ok(())
        })
        .await
    }

    /// posix-rename 原子覆盖；仅 STATUS OK 表示成功，任何失败都不删除目标或重试。
    pub async fn posix_rename(&self, from: &str, to: &str) -> SftpResult<()> {
        let raw = Arc::clone(&self.raw);
        let (from, to) = (from.to_string(), to.to_string());
        self.op(async move {
            // SSH_FXP_EXTENDED "posix-rename@openssh.com"：[string oldpath][string newpath]
            let mut data = Vec::with_capacity(8 + from.len() + to.len());
            data.extend_from_slice(&(from.len() as u32).to_be_bytes());
            data.extend_from_slice(from.as_bytes());
            data.extend_from_slice(&(to.len() as u32).to_be_bytes());
            data.extend_from_slice(to.as_bytes());
            match raw.extended("posix-rename@openssh.com", data).await? {
                Packet::Status(status) if status.status_code == StatusCode::Ok => Ok(()),
                Packet::Status(status) => Err(RawSftpError::Status(status)),
                _ => Err(RawSftpError::UnexpectedPacket),
            }
        })
        .await
    }

    pub async fn realpath(&self, path: &str) -> SftpResult<String> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        self.op(async move {
            let name = raw.realpath(path).await?;
            Ok(name
                .files
                .into_iter()
                .next()
                .map(|f| f.filename)
                .unwrap_or_default())
        })
        .await
    }

    /// 打开文件；CREAT 时默认 0644（与 libssh2 版一致）。pflags 为 SSH_FXF_* 线上值。
    pub async fn open(&self, path: &str, pflags: u32) -> SftpResult<RusshSftpFile> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        let flags = OpenFlags::from_bits_truncate(pflags);
        let attrs = if flags.contains(OpenFlags::CREATE) {
            wire_attrs_for_create()
        } else {
            FileAttributes::default()
        };
        let raw_for_file = Arc::clone(&self.raw);
        self.op(async move {
            let handle = raw.open(path, flags, attrs).await?;
            Ok(RusshSftpFile {
                raw: raw_for_file,
                handle: handle.handle,
                dir: None,
            })
        })
        .await
    }

    pub async fn opendir(&self, path: &str) -> SftpResult<RusshSftpFile> {
        let raw = Arc::clone(&self.raw);
        let path = path.to_string();
        let raw_for_file = Arc::clone(&self.raw);
        self.op(async move {
            let handle = raw.opendir(path).await?;
            Ok(RusshSftpFile {
                raw: raw_for_file,
                handle: handle.handle,
                dir: Some(VecDeque::new()),
            })
        })
        .await
    }
}

impl RusshSftpFile {
    async fn run<T>(
        &self,
        fut: impl std::future::Future<Output = Result<T, RawSftpError>>,
    ) -> SftpResult<T> {
        fut.await.map_err(map_error)
    }

    /// 句柄 fstat。
    pub async fn fstat(&self) -> SftpResult<SftpAttrs> {
        let raw = Arc::clone(&self.raw);
        let handle = self.handle.clone();
        self.run(async move {
            let wrapped = raw.fstat(handle).await?;
            Ok(from_wire_attrs(wrapped.attrs))
        })
        .await
    }

    /// 读一块；Ok(空)=EOF。内部按 ≤32 KiB 分块循环凑满 len。
    pub async fn read(&self, offset: u64, len: u32) -> SftpResult<Vec<u8>> {
        let raw = Arc::clone(&self.raw);
        let handle = self.handle.clone();
        self.run(async move {
            let mut out = Vec::with_capacity(len as usize);
            let mut offset = offset;
            let mut want = len;
            while want > 0 {
                let chunk = want.min(CHUNK);
                match raw.read(&handle, offset, chunk).await {
                    Ok(data) => {
                        if data.data.is_empty() {
                            break; // EOF
                        }
                        offset += data.data.len() as u64;
                        want = want.saturating_sub(data.data.len() as u32);
                        out.extend_from_slice(&data.data);
                        if (data.data.len() as u32) < chunk {
                            break; // 短读即 EOF
                        }
                    }
                    Err(RawSftpError::Status(status)) if status.status_code as u32 == 1 => break, // EOF
                    Err(e) => return Err(e),
                }
            }
            Ok(out)
        })
        .await
    }

    /// 写整块：按 ≤32 KiB 分块循环直到写完，返回已写字节数。
    pub async fn write(&self, offset: u64, data: &[u8]) -> SftpResult<usize> {
        let raw = Arc::clone(&self.raw);
        let handle = self.handle.clone();
        let data = data.to_vec();
        self.run(async move {
            let mut offset = offset;
            let mut written = 0usize;
            while written < data.len() {
                let end = (written + CHUNK as usize).min(data.len());
                raw.write(&handle, offset, data[written..end].to_vec())
                    .await?;
                offset += (end - written) as u64;
                written = end;
            }
            Ok(written)
        })
        .await
    }

    /// 读一个目录项；Ok(None)=EOF（目录读完，内部自动关闭句柄）。
    pub async fn readdir(&mut self) -> SftpResult<Option<(String, SftpAttrs)>> {
        loop {
            if let Some(f) = self.dir.as_mut().and_then(VecDeque::pop_front) {
                let attrs = from_wire_attrs(f.attrs);
                return Ok(Some((f.filename, attrs)));
            }
            if self.handle.is_empty() {
                return Ok(None); // 已 EOF 过
            }
            let raw = Arc::clone(&self.raw);
            let handle = self.handle.clone();
            let result = raw.readdir(handle).await;
            match result {
                Ok(name) => {
                    if let Some(dir) = self.dir.as_mut() {
                        dir.extend(name.files);
                    } else {
                        return Err(SftpOpError {
                            code: TRANSPORT_BASE + 2,
                            message: "句柄不是目录".into(),
                        });
                    }
                }
                Err(RawSftpError::Status(status)) if status.status_code as u32 == 1 => {
                    // 目录读完：关闭句柄（对齐 libssh2 版「readdir 0=EOF」）
                    let handle = std::mem::take(&mut self.handle);
                    let raw = Arc::clone(&self.raw);
                    let _ = raw.close(handle).await;
                    return Ok(None);
                }
                Err(e) => return Err(map_error(e)),
            }
        }
    }

    /// 显式关闭句柄（文件/目录通用；幂等）。
    pub async fn close(&mut self) {
        let handle = std::mem::take(&mut self.handle);
        if handle.is_empty() {
            return;
        }
        let raw = Arc::clone(&self.raw);
        let _ = raw.close(handle).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh_sftp::protocol::{Handle, Status};
    use std::sync::{atomic::AtomicI32, Mutex};

    enum Reply {
        Status(StatusCode),
        Unexpected,
        Timeout,
    }

    struct Server {
        reply: Reply,
        operations: Arc<Mutex<Vec<String>>>,
    }

    impl russh_sftp::server::Handler for Server {
        type Error = StatusCode;

        fn unimplemented(&self) -> Self::Error {
            StatusCode::OpUnsupported
        }

        async fn extended(
            &mut self,
            id: u32,
            request: String,
            data: Vec<u8>,
        ) -> Result<Packet, Self::Error> {
            self.operations.lock().unwrap().push(request.clone());
            assert_eq!(request, "posix-rename@openssh.com");
            assert_eq!(data, b"\0\0\0\x0a/file.part\0\0\0\x05/file");
            match self.reply {
                Reply::Status(status_code) => Ok(Packet::Status(Status {
                    id,
                    status_code,
                    error_message: "server rename result".into(),
                    language_tag: String::new(),
                })),
                Reply::Unexpected => Ok(Packet::Handle(Handle {
                    id,
                    handle: "unexpected".into(),
                })),
                Reply::Timeout => {
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    Err(StatusCode::Failure)
                }
            }
        }

        async fn remove(&mut self, _id: u32, filename: String) -> Result<Status, Self::Error> {
            self.operations
                .lock()
                .unwrap()
                .push(format!("remove {filename}"));
            Err(StatusCode::Failure)
        }

        async fn rename(
            &mut self,
            _id: u32,
            from: String,
            to: String,
        ) -> Result<Status, Self::Error> {
            self.operations
                .lock()
                .unwrap()
                .push(format!("rename {from} {to}"));
            Err(StatusCode::Failure)
        }
    }

    async fn fixture(reply: Reply) -> (RusshSftp, Arc<Mutex<Vec<String>>>) {
        let (client, server) = tokio::io::duplex(4096);
        let operations = Arc::new(Mutex::new(Vec::new()));
        russh_sftp::server::run(
            server,
            Server {
                reply,
                operations: operations.clone(),
            },
        )
        .await;
        let raw = RawSftpSession::new_with_config(
            client,
            russh_sftp::client::Config {
                request_timeout_secs: 1,
                ..Default::default()
            },
        );
        raw.init().await.unwrap();
        (
            RusshSftp {
                raw: Arc::new(raw),
                last_code: AtomicI32::new(0),
            },
            operations,
        )
    }

    #[test]
    fn posix_rename_accepts_only_status_ok() {
        runtime().block_on(async {
            let (session, operations) = fixture(Reply::Status(StatusCode::Ok)).await;
            session.posix_rename("/file.part", "/file").await.unwrap();
            assert_eq!(*operations.lock().unwrap(), ["posix-rename@openssh.com"]);
            session.raw.close_session().unwrap();
        });
    }

    #[test]
    fn posix_rename_preserves_server_failure_without_delete_or_retry() {
        runtime().block_on(async {
            for status in [
                StatusCode::PermissionDenied,
                StatusCode::Failure,
                StatusCode::OpUnsupported,
            ] {
                let (session, operations) = fixture(Reply::Status(status)).await;
                let error = session
                    .posix_rename("/file.part", "/file")
                    .await
                    .unwrap_err();
                assert_eq!(error.code, status as i32);
                assert_eq!(error.message, "server rename result");
                assert_eq!(session.last(), error.code);
                assert_eq!(*operations.lock().unwrap(), ["posix-rename@openssh.com"]);
                session.raw.close_session().unwrap();
            }
        });
    }

    #[test]
    fn posix_rename_rejects_unexpected_reply_without_delete_or_retry() {
        runtime().block_on(async {
            let (session, operations) = fixture(Reply::Unexpected).await;
            let error = session
                .posix_rename("/file.part", "/file")
                .await
                .unwrap_err();
            assert!(error.is_transport());
            assert_eq!(*operations.lock().unwrap(), ["posix-rename@openssh.com"]);
            session.raw.close_session().unwrap();
        });
    }

    #[test]
    fn posix_rename_timeout_does_not_replay_an_ambiguous_operation() {
        runtime().block_on(async {
            let (session, operations) = fixture(Reply::Timeout).await;
            let error = session
                .posix_rename("/file.part", "/file")
                .await
                .unwrap_err();
            assert!(error.is_transport());
            assert_eq!(*operations.lock().unwrap(), ["posix-rename@openssh.com"]);
            session.raw.close_session().unwrap();
        });
    }
}
