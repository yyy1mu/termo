//! 交互式 PTY shell：对标 libssh2 引擎 `termo_ssh_shell_*` 的语义——
//! PTY(xterm-256color) + shell、线程安全写入队列与 resize、增量输出回调、
//! 关闭时 join 泵任务后不再有回调；远端退出码回传，掉线映射 255。

use std::sync::Mutex;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use crate::runtime;
use crate::session::{RusshSession, SessionInner};

/// PTY 设置阶段的整体超时（对标 libssh2 会话操作 15s 口径）。
const OPEN_TIMEOUT: Duration = Duration::from_secs(15);

/// 增量输出回调（泵任务线程调用）。bytes 仅在回调期间有效。
pub type ShellDataCallback =
    unsafe extern "C" fn(userdata: *mut std::ffi::c_void, bytes: *const std::ffi::c_char, len: i32);
/// 结束回调（泵结束后调用一次）。exit_code：远端退出码；掉线=255。
pub type ShellClosedCallback =
    unsafe extern "C" fn(userdata: *mut std::ffi::c_void, exit_code: i32);

/// userdata 指针以 usize 承载跨线程：edition 2021 闭包按路径精确捕获，
/// 直接捕获 `wrapper.0` 会绕过包装体的 Send 实现。
#[inline]
fn as_userdata(p: *mut std::ffi::c_void) -> usize {
    p as usize
}

/// 非法尺寸默认 80×24（与 libssh2 版一致）。
pub(crate) fn clamp_dims(cols: i32, rows: i32) -> (u32, u32) {
    let c = if cols > 0 { cols as u32 } else { 80 };
    let r = if rows > 0 { rows as u32 } else { 24 };
    (c, r)
}

/// 交互式 shell 句柄（对应 libssh2 侧 `TermoSSHShell*`）。
pub struct RusshShell {
    write_tx: mpsc::UnboundedSender<Vec<u8>>,
    resize_tx: mpsc::UnboundedSender<(u32, u32)>,
    close_tx: Mutex<Option<oneshot::Sender<()>>>,
    join: Mutex<Option<JoinHandle<()>>>,
}

impl RusshSession {
    /// 在已认证会话上开 PTY + shell 并启动泵任务。
    /// 注：shell 存续期间会话须保持打开（与 libssh2 版一致：shell_close 不关会话）。
    pub async fn shell_open(
        &self,
        cols: i32,
        rows: i32,
        command: Option<String>,
        on_data: ShellDataCallback,
        on_closed: ShellClosedCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<RusshShell, String> {
        let (cols, rows) = clamp_dims(cols, rows);
        let channel = SessionInner::channel_open(self)
            .await
            .map_err(|e| format!("通道打开失败: {e}"))?;
        let setup = async {
            channel
                .request_pty(true, "xterm-256color", cols, rows, 0, 0, &[])
                .await
                .map_err(|e| format!("PTY 请求失败: {e}"))?;
            // command 为空 → 交互 shell；非空 → PTY + exec（如 tmux attach，
            // 不经登录 shell：无 history 污染、不触碰已有标签的会话）。
            match command {
                Some(cmd) => channel
                    .exec(true, cmd.into_bytes())
                    .await
                    .map_err(|e| format!("exec 请求失败: {e}"))?,
                None => channel
                    .request_shell(true)
                    .await
                    .map_err(|e| format!("shell 请求失败: {e}"))?,
            }
            Ok::<(), String>(())
        };
        match tokio::time::timeout(OPEN_TIMEOUT, setup).await {
            Ok(Ok(())) => {}
            Ok(Err(message)) => return Err(message),
            Err(_) => return Err("PTY 设置超时".into()),
        }

        let (mut ch_read, ch_write) = channel.split();
        let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let (resize_tx, mut resize_rx) = mpsc::unbounded_channel::<(u32, u32)>();
        let (close_tx, close_rx) = oneshot::channel::<()>();
        let mut close_rx = close_rx;
        let ud_ptr = as_userdata(userdata);

        let join: JoinHandle<()> = runtime().spawn(async move {
            let mut exit_code: Option<i32> = None;
            loop {
                tokio::select! {
                    msg = ch_read.wait() => match msg {
                        Some(russh::ChannelMsg::Data { data }) => {
                            let (ptr, len) = (data.as_ptr(), data.len());
                            unsafe { on_data(ud_ptr as *mut std::ffi::c_void, ptr as *const std::ffi::c_char, len as i32) };
                        }
                        // PTY 下 stderr 通常并入 stdout；ext=1 单独到达时同样喂给终端。
                        Some(russh::ChannelMsg::ExtendedData { ext: 1, data }) => {
                            let (ptr, len) = (data.as_ptr(), data.len());
                            unsafe { on_data(ud_ptr as *mut std::ffi::c_void, ptr as *const std::ffi::c_char, len as i32) };
                        }
                        Some(russh::ChannelMsg::ExitStatus { exit_status }) => {
                            exit_code = Some(exit_status as i32);
                        }
                        Some(russh::ChannelMsg::Eof) => {}
                        Some(_) => {}
                        None => break,                     // 通道已关闭（掉线/远端退出）
                    },
                    chunk = write_rx.recv() => {
                        if let Some(bytes) = chunk {
                            if ch_write.data_bytes(bytes).await.is_err() {
                                break;                     // 写失败视作传输断开
                            }
                        }
                    },
                    dims = resize_rx.recv() => {
                        if let Some((c, r)) = dims {
                            let _ = ch_write.window_change(c, r, 0, 0).await;
                        }
                    },
                    _ = &mut close_rx => break,            // 本地主动关闭
                }
            }
            let _ = ch_write.close().await;
            let code = exit_code.unwrap_or(255); // 无退出码 = 掉线，与 ssh 对齐
            unsafe { on_closed(ud_ptr as *mut std::ffi::c_void, code) };
        });

        Ok(RusshShell {
            write_tx,
            resize_tx,
            close_tx: Mutex::new(Some(close_tx)),
            join: Mutex::new(Some(join)),
        })
    }
}

impl RusshShell {
    /// 写入远端 PTY（线程安全，立即返回）。返回入队字节数或 -1（泵已退出）。
    pub fn write(&self, buf: &[u8]) -> i64 {
        if buf.is_empty() {
            return 0;
        }
        match self.write_tx.send(buf.to_vec()) {
            Ok(()) => buf.len() as i64,
            Err(_) => -1,
        }
    }

    /// 通知 PTY 尺寸变化（线程安全）。
    pub fn resize(&self, cols: i32, rows: i32) -> i32 {
        let (c, r) = clamp_dims(cols, rows);
        match self.resize_tx.send((c, r)) {
            Ok(()) => 0,
            Err(_) => -1,
        }
    }

    /// 停泵 + 回收句柄。返回后不再有任何回调。
    /// 若从回调线程调用（如 on_closed 内），join 转入后台，不阻塞 runtime worker。
    pub fn close(&self) {
        if let Some(tx) = self.close_tx.lock().expect("close slot").take() {
            let _ = tx.send(());
        }
        if let Some(join) = self.join.lock().expect("join slot").take() {
            if tokio::runtime::Handle::try_current().is_ok() {
                tokio::spawn(async move {
                    let _ = join.await;
                });
            } else {
                let _ = runtime().block_on(join);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::clamp_dims;

    #[test]
    fn dims_default_to_80x24_when_invalid() {
        assert_eq!(clamp_dims(0, 0), (80, 24));
        assert_eq!(clamp_dims(-1, -5), (80, 24));
        assert_eq!(clamp_dims(120, 40), (120, 40));
    }
}
