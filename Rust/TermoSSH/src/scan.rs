//! 扫描 + 流式 exec（上传/输出回调）：补齐调度层所需的 libssh2 对应语义。
//! - 扫描：仅握手（不认证），回传 status/SHA256/MD5/known_hosts 行
//! - exec_upload：pull 回调喂数据（<0 取消保留远端半截；0=EOF）
//! - exec_stream：stdout 增量回调直到 EOF/错误/被取消

use crate::handler::{handshake_only, HostPolicy};
use crate::runtime;
use crate::session::RusshSession;

/// 主机密钥扫描结果（#[repr(C)]，与 TermoRusshCore.h 的结构一致）。
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct HostKeyScan {
    pub status: i32,
    pub sha256: [u8; 80],
    pub md5: [u8; 64],
    pub line: [u8; 1024],
}

impl HostKeyScan {
    fn empty() -> Self {
        Self {
            status: -1,
            sha256: [0; 80],
            md5: [0; 64],
            line: [0; 1024],
        }
    }
}

/// 扫描 host:port 的主机密钥（不认证、不发密码）。策略文件参与比对。
pub async fn scan_hostkey(
    host: &str,
    port: u16,
    real_known_hosts: &str,
    session_known_hosts: &str,
) -> Result<HostKeyScan, String> {
    let policy = HostPolicy {
        host: host.to_string(),
        port,
        real_known_hosts: real_known_hosts.to_string(),
        session_known_hosts: session_known_hosts.to_string(),
    };
    let info = handshake_only(
        host,
        port,
        Some(policy),
        crate::session::clamp_timeout(15_000),
    )
    .await?;
    let mut out = HostKeyScan::empty();
    out.status = *info.status.lock().expect("status");
    put_str(
        &mut out.sha256,
        &info.sha256.lock().expect("sha256").clone(),
    );
    put_str(&mut out.md5, &info.md5.lock().expect("md5").clone());
    put_str(&mut out.line, &info.line.lock().expect("line").clone());
    Ok(out)
}

fn put_str(dst: &mut [u8], s: &str) {
    let n = s.len().min(dst.len().saturating_sub(1));
    dst[..n].copy_from_slice(&s.as_bytes()[..n]);
    dst[n] = 0;
}

/// 上传 pull 回调（>0=写入字节数 / 0=EOF / <0=取消）。
pub type ExecPullCallback = unsafe extern "C" fn(
    userdata: *mut std::ffi::c_void,
    buf: *mut std::ffi::c_char,
    cap: i32,
) -> i32;

impl RusshSession {
    /// 流式上传 exec：exec 命令后反复调 pull 取 stdin 数据写入远端。
    /// 取消（pull<0）立即停止且不 send EOF，保留远端半截供续传。返回 0=完成/1=取消/-1=错误。
    pub async fn exec_upload(
        &self,
        command: &str,
        pull: ExecPullCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<i32, String> {
        let channel = self
            .inner()
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
        channel
            .exec(true, command)
            .await
            .map_err(|e| format!("exec 失败: {e}"))?;
        let ud = userdata as usize;
        let (mut ch_read, ch_write) = channel.split();

        // 写入循环：pull 阻塞 C 侧，故放阻塞线程；写入经 runtime 泵
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Option<Vec<u8>>>(4);
        let (done_tx, _done_rx) = tokio::sync::oneshot::channel::<i32>();
        let pull_task: std::thread::JoinHandle<i32> = std::thread::spawn(move || {
            let mut buf = vec![0u8; 64 * 1024];
            let result: i32;
            loop {
                let n = unsafe {
                    pull(
                        ud as *mut std::ffi::c_void,
                        buf.as_mut_ptr() as *mut std::ffi::c_char,
                        buf.len() as i32,
                    )
                };
                if n < 0 {
                    result = 1; // 取消
                    break;
                }
                if n == 0 {
                    result = 0; // EOF
                    let _ = tx.blocking_send(None).ok(); // None = 正常 EOF 哨兵
                    break;
                }
                if tx.blocking_send(Some(buf[..n as usize].to_vec())).is_err() {
                    result = -1;
                    break;
                }
            }
            let _ = done_tx.send(result);
            result
        });

        let mut cancelled = false;
        let writer = runtime().spawn(async move {
            let mut write_error = false;
            while let Some(msg) = rx.recv().await {
                match msg {
                    Some(chunk) => {
                        if ch_write.data_bytes(chunk).await.is_err() {
                            write_error = true;
                            break;
                        }
                    }
                    None => {
                        let _ = ch_write.eof().await; // 正常 EOF
                    }
                }
            }
            let _ = ch_write.close().await;
            if write_error {
                Err("stdin 写入失败".to_string())
            } else {
                Ok(())
            }
        });
        // 等待 pull 结束（阻塞当前 async 上下文的后台线程池线程是安全的：任务由 spawn 承载）
        let pull_result: i32 = tokio::task::spawn_blocking(move || pull_task.join().unwrap_or(-1))
            .await
            .unwrap_or(-1);
        if pull_result < 0 {
            cancelled = true;
        }
        let _ = writer.await;

        if !cancelled {
            while let Some(msg) = ch_read.wait().await {
                if let russh::ChannelMsg::ExitStatus { .. } = msg {}
            }
        }
        if cancelled {
            Ok(1)
        } else {
            Ok(0)
        }
    }

    /// 流式 exec：stdout 增量回调直到 EOF/错误；会话 cancel 可中断（返回 0）。
    pub async fn exec_stream(
        &self,
        command: &str,
        on_data: crate::shell::ShellDataCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<(), String> {
        let channel = self
            .inner()
            .handle
            .channel_open_session()
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
        channel
            .exec(true, command)
            .await
            .map_err(|e| format!("exec 失败: {e}"))?;
        let (mut ch_read, ch_write) = channel.split();
        let ud = userdata as usize;
        loop {
            match ch_read.wait().await {
                Some(russh::ChannelMsg::Data { data }) => {
                    let (ptr, len) = (data.as_ptr(), data.len());
                    unsafe {
                        on_data(
                            ud as *mut std::ffi::c_void,
                            ptr as *const std::ffi::c_char,
                            len as i32,
                        )
                    };
                }
                Some(russh::ChannelMsg::ExitStatus { .. }) => {}
                Some(_) => {}
                None => break,
            }
        }
        let _ = ch_write.close().await;
        Ok(())
    }
}

/// 会话句柄的流式变体（阻塞入口；供调度层直接映射 termo_ssh_exec_*）。
pub fn scan_hostkey_blocking(
    host: &str,
    port: u16,
    real: &str,
    session: &str,
) -> Result<HostKeyScan, String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime().block_on(scan_hostkey(host, port, real, session))
    }))
    .unwrap_or_else(|_| Err("内部 panic（已被 FFI 边界拦截）".into()))
}
