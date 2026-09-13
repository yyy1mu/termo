//! 端口转发：对标 libssh2 引擎 `termo_ssh_forward_*` 的语义——
//! -L 本地 / -R 远程 / -D 动态 SOCKS5（仅 CONNECT、无认证；域名交给远端解析）。
//! 每条规则一个监督任务；并发连接上限 128；direct-tcpip 打开 8s 超时；
//! SOCKS 协商 10s 超时；半关闭由 copy_bidirectional 保证；
//! 会话死亡经 on_state(ok=0) 上报（上层据此重连/标记失败）。

use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{copy_bidirectional, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, oneshot, Semaphore};
use tokio::task::JoinHandle;

use crate::runtime;
use crate::session::{RusshSession, SessionInner};

/// 每条转发隧道的并发连接上限（与 libssh2 版一致）。
const MAX_CONNS: usize = 128;
/// direct-tcpip 建立超时（与 libssh2 版一致）。
const CHANNEL_OPEN_TIMEOUT: Duration = Duration::from_secs(8);
/// SOCKS5 协商超时（与 libssh2 版一致）。
const SOCKS_TIMEOUT: Duration = Duration::from_secs(10);
/// 会话死亡轮询间隔。
const DEAD_POLL: Duration = Duration::from_millis(500);

/// 转发状态回调（监督任务线程调用）。ok=0 表示连接断开/致命错误。
pub type ForwardStateCallback = unsafe extern "C" fn(
    userdata: *mut std::ffi::c_void,
    ok: i32,
    message: *const std::ffi::c_char,
);

/// 转发类型（与 C ABI kind 同义：0/1/2）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ForwardKind {
    /// -L：本地监听 → 经服务器连 dest
    Local,
    /// -R：服务器监听 → 转回本机 dest
    Remote,
    /// -D：本地 SOCKS5
    Dynamic,
}

/// 转发参数组：模式 + 监听端 + 目标端。
#[derive(Debug, Clone)]
pub struct ForwardSpec {
    pub kind: ForwardKind,
    pub bind_addr: String,
    pub listen_port: u16,
    pub dest_host: String,
    pub dest_port: u16,
}

/// 转发句柄（对应 libssh2 侧 `TermoSSHForward*`）。
pub struct RusshForward {
    close_tx: Mutex<Option<oneshot::Sender<()>>>,
    join: Mutex<Option<JoinHandle<()>>>,
}

// ── SOCKS5（RFC 1928，仅 CONNECT / 无认证）──────────────────────────────────

/// SOCKS5 目标（ATYP 1=IPv4 3=域名 4=IPv6）。
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum SocksTarget {
    V4([u8; 4]),
    Domain(String),
    V6([u8; 16]),
}

/// 解析完整 SOCKS5 请求（VER CMD RSV ATYP ADDR PORT）；返回目标或应答错误码。
pub(crate) fn parse_socks_request(buf: &[u8]) -> Result<(SocksTarget, u16), u8> {
    if buf.len() < 4 {
        return Err(0x01); // general SOCKS server failure
    }
    let (ver, cmd, atyp) = (buf[0], buf[1], buf[3]);
    if ver != 5 {
        return Err(0x01);
    }
    if cmd != 1 {
        return Err(0x07); // command not supported（仅支持 CONNECT）
    }
    let mut pos = 4usize;
    let target = match atyp {
        1 => {
            if buf.len() < pos + 6 {
                return Err(0x01);
            }
            let t = SocksTarget::V4([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]);
            pos += 4;
            t
        }
        3 => {
            let len = buf[pos] as usize;
            pos += 1;
            if buf.len() < pos + len + 2 {
                return Err(0x01);
            }
            let Ok(domain) = std::str::from_utf8(&buf[pos..pos + len]) else {
                return Err(0x08); // address type not supported
            };
            pos += len;
            SocksTarget::Domain(domain.to_string())
        }
        4 => {
            if buf.len() < pos + 18 {
                return Err(0x01);
            }
            let mut t = [0u8; 16];
            t.copy_from_slice(&buf[pos..pos + 16]);
            pos += 16;
            SocksTarget::V6(t)
        }
        _ => return Err(0x08),
    };
    let port = u16::from_be_bytes([buf[pos], buf[pos + 1]]);
    Ok((target, port))
}

fn socks_success() -> [u8; 10] {
    [5, 0, 0, 1, 0, 0, 0, 0, 0, 0] // BND.ADDR 0.0.0.0:0
}

fn socks_failure(code: u8) -> [u8; 10] {
    [5, code, 0, 1, 0, 0, 0, 0, 0, 0]
}

fn target_string(target: &SocksTarget) -> String {
    match target {
        SocksTarget::V4(a) => Ipv4Addr::from(*a).to_string(),
        SocksTarget::V6(a) => Ipv6Addr::from(*a).to_string(),
        SocksTarget::Domain(d) => d.clone(),
    }
}

// ── 状态上报 ────────────────────────────────────────────────────────────────

/// on_state(ok=0) 去重上报器（监督/连接任务共享）。
#[derive(Clone)]
struct StateReporter {
    on_state: ForwardStateCallback,
    ud: usize,
    reported: Arc<AtomicBool>,
}

impl StateReporter {
    fn new(on_state: ForwardStateCallback, userdata: *mut std::ffi::c_void) -> Self {
        Self {
            on_state,
            ud: userdata as usize,
            reported: Arc::new(AtomicBool::new(false)),
        }
    }

    fn report_dead(&self) {
        if !self
            .reported
            .swap(true, std::sync::atomic::Ordering::SeqCst)
        {
            let message = b"connection lost\0";
            unsafe {
                (self.on_state)(
                    self.ud as *mut std::ffi::c_void,
                    0,
                    message.as_ptr() as *const std::ffi::c_char,
                );
            }
        }
    }
}

// ── 连接泵 ──────────────────────────────────────────────────────────────────

/// 单条 -L 连接：direct-tcpip(dest) + 双向泵。
async fn pump_local(
    inner: Arc<SessionInner>,
    tcp: TcpStream,
    dest_host: String,
    dest_port: u16,
    peer: std::net::SocketAddr,
) {
    let opened = tokio::time::timeout(
        CHANNEL_OPEN_TIMEOUT,
        inner.handle.channel_open_direct_tcpip(
            dest_host,
            u32::from(dest_port),
            peer.ip().to_string(),
            u32::from(peer.port()),
        ),
    )
    .await;
    let Ok(Ok(channel)) = opened else {
        return; // 打开失败：直接断开本地连接（与 libssh2 版一致）
    };
    let (mut tcp, mut stream) = (tcp, channel.into_stream());
    let _ = copy_bidirectional(&mut tcp, &mut stream).await;
}

/// 单条 -D 连接：SOCKS5 协商 → direct-tcpip(target) → 双向泵。
async fn pump_socks(inner: Arc<SessionInner>, mut tcp: TcpStream, peer: std::net::SocketAddr) {
    // 协商阶段整体 10s 超时；任何一步失败即断开（协商完成前无法回复 SOCKS 错误码）。
    let negotiation = async {
        let mut greeting = [0u8; 2];
        tcp.read_exact(&mut greeting).await.map_err(|_| ())?;
        if greeting[0] != 5 {
            return Err(());
        }
        let mut methods = vec![0u8; greeting[1] as usize];
        tcp.read_exact(&mut methods).await.map_err(|_| ())?;
        if !methods.contains(&0x00) {
            let _ = tcp.write_all(&socks_failure(0xFF)).await; // no acceptable methods
            return Err(());
        }
        tcp.write_all(&[5, 0]).await.map_err(|_| ())?;

        let mut head = [0u8; 4];
        tcp.read_exact(&mut head).await.map_err(|_| ())?;
        // rest = 地址字段 + 端口；域名场景首字节为长度（与解析器约定一致）
        let rest_len = match head[3] {
            1 => 4 + 2,
            3 => {
                let mut len = [0u8; 1];
                tcp.read_exact(&mut len).await.map_err(|_| ())?;
                1 + len[0] as usize + 2
            }
            4 => 16 + 2,
            _ => return Err(()),
        };
        let mut rest = vec![0u8; rest_len];
        tcp.read_exact(&mut rest).await.map_err(|_| ())?;
        let mut request = head.to_vec();
        request.extend_from_slice(&rest);
        let (target, port) = parse_socks_request(&request).map_err(|_| ())?;

        let opened = tokio::time::timeout(
            CHANNEL_OPEN_TIMEOUT,
            inner.handle.channel_open_direct_tcpip(
                target_string(&target),
                u32::from(port),
                peer.ip().to_string(),
                u32::from(peer.port()),
            ),
        )
        .await;
        let Ok(Ok(channel)) = opened else {
            let _ = tcp.write_all(&socks_failure(0x05)).await; // connection refused
            return Err(());
        };
        tcp.write_all(&socks_success()).await.map_err(|_| ())?;
        Ok::<_, ()>(channel.into_stream())
    };
    match tokio::time::timeout(SOCKS_TIMEOUT, negotiation).await {
        Ok(Ok(mut stream)) => {
            let _ = copy_bidirectional(&mut tcp, &mut stream).await;
        }
        _ => {
            let _ = tcp.shutdown().await;
        }
    }
}

// ── 监督任务 ────────────────────────────────────────────────────────────────

impl RusshSession {
    /// 开启转发。kind 决定模式；监听/服务器端请求失败立即返回 Err。
    pub async fn forward_open(
        &self,
        spec: ForwardSpec,
        on_state: ForwardStateCallback,
        userdata: *mut std::ffi::c_void,
    ) -> Result<RusshForward, String> {
        let ForwardSpec {
            kind,
            bind_addr,
            listen_port,
            dest_host,
            dest_port,
        } = spec;
        let bind: std::borrow::Cow<'_, str> = if bind_addr.is_empty() {
            "0.0.0.0".into()
        } else {
            bind_addr.into()
        };
        let reporter = StateReporter::new(on_state, userdata);
        let semaphore = Arc::new(Semaphore::new(MAX_CONNS));
        let (close_tx, close_rx) = oneshot::channel::<()>();
        let mut close_rx = close_rx;

        match kind {
            ForwardKind::Local | ForwardKind::Dynamic => {
                let listener = TcpListener::bind((bind.as_ref(), listen_port))
                    .await
                    .map_err(|e| {
                        if e.kind() == std::io::ErrorKind::AddrInUse {
                            format!("本地端口已被占用: {bind}:{listen_port}")
                        } else {
                            format!("本地监听失败: {e}")
                        }
                    })?;
                let inner = Arc::clone(self.inner());
                let dynamic = kind == ForwardKind::Dynamic;
                let join = runtime().spawn(async move {
                    loop {
                        tokio::select! {
                            accepted = listener.accept() => match accepted {
                                Ok((tcp, peer)) => {
                                    let inner = Arc::clone(&inner);
                                    let semaphore = Arc::clone(&semaphore);
                                    let dest_host = dest_host.clone();
                                    let dest_port = dest_port;
                                    tokio::spawn(async move {
                                        let Ok(permit) = semaphore.acquire_owned().await else { return };
                                        if dynamic {
                                            pump_socks(inner, tcp, peer).await;
                                        } else {
                                            pump_local(inner, tcp, dest_host, dest_port, peer).await;
                                        }
                                        drop(permit);
                                    });
                                }
                                Err(_) => break,
                            },
                            _ = &mut close_rx => break,
                            _ = tokio::time::sleep(DEAD_POLL) => {
                                if inner.is_dead() {
                                    reporter.report_dead();
                                    break;
                                }
                            }
                        }
                    }
                });
                Ok(RusshForward {
                    close_tx: Mutex::new(Some(close_tx)),
                    join: Mutex::new(Some(join)),
                })
            }
            ForwardKind::Remote => {
                let assigned = self
                    .inner()
                    .handle
                    .tcpip_forward(bind.as_ref(), u32::from(listen_port))
                    .await
                    .map_err(|e| format!("转发请求被拒绝: {e}"))?;
                let _ = assigned; // listen_port==0 时为服务器分配端口（本端暂不支持随机端口语义）

                let (slot_tx, mut slot_rx) = mpsc::unbounded_channel();
                *self.inner().forward_slot.lock().expect("forward slot") = Some(slot_tx);

                let inner = Arc::clone(self.inner());
                let bind_owned = bind.to_string();
                let port = u32::from(listen_port);
                let join = runtime().spawn(async move {
                    loop {
                        tokio::select! {
                            channel = slot_rx.recv() => match channel {
                                Some(channel) => {
                                    let dest_host = dest_host.clone();
                                    let dest_port = dest_port;
                                    tokio::spawn(async move {
                                        // 服务器侧新连接：转回本机 dest_host:dest_port
                                        let opened = tokio::time::timeout(
                                            CHANNEL_OPEN_TIMEOUT,
                                            TcpStream::connect((dest_host.as_str(), dest_port)),
                                        )
                                        .await;
                                        let Ok(Ok(mut tcp)) = opened else { return };
                                        let mut stream = channel.into_stream();
                                        let _ = copy_bidirectional(&mut tcp, &mut stream).await;
                                    });
                                }
                                None => break,
                            },
                            _ = &mut close_rx => break,
                            _ = tokio::time::sleep(DEAD_POLL) => {
                                if inner.is_dead() {
                                    reporter.report_dead();
                                    break;
                                }
                            }
                        }
                    }
                    // 收尾：摘除路由槽 + 释放服务器端监听（尽力而为）
                    *inner.forward_slot.lock().expect("forward slot") = None;
                    let _ = inner.handle.cancel_tcpip_forward(&bind_owned, port).await;
                });
                Ok(RusshForward {
                    close_tx: Mutex::new(Some(close_tx)),
                    join: Mutex::new(Some(join)),
                })
            }
        }
    }
}

impl RusshForward {
    /// 停止转发并回收监督任务。返回后不再有 on_state 回调。
    /// 若从回调线程调用（如 on_state 内），join 转入后台，不阻塞 runtime worker。
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
    use super::{parse_socks_request, SocksTarget};

    #[test]
    fn parses_ipv4_connect() {
        let req = [5u8, 1, 0, 1, 10, 0, 0, 1, 0x1F, 0x90];
        let r = parse_socks_request(&req);
        assert_eq!(r, Ok((SocksTarget::V4([10, 0, 0, 1]), 8080)));
    }

    #[test]
    fn parses_domain_connect() {
        let mut req = vec![5u8, 1, 0, 3, 9];
        req.extend_from_slice(b"localhost");
        req.extend_from_slice(&22u16.to_be_bytes());
        assert_eq!(
            parse_socks_request(&req),
            Ok((SocksTarget::Domain("localhost".into()), 22))
        );
    }

    #[test]
    fn rejects_non_connect_and_bad_version() {
        assert_eq!(
            parse_socks_request(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 80]),
            Err(0x07)
        );
        assert_eq!(
            parse_socks_request(&[4, 1, 0, 1, 0, 0, 0, 0, 0, 80]),
            Err(0x01)
        );
        assert_eq!(parse_socks_request(&[5, 1, 0]), Err(0x01));
    }

    #[test]
    fn rejects_truncated_domain() {
        let req = [5u8, 1, 0, 3, 9, b'l', b'o'];
        assert_eq!(parse_socks_request(&req), Err(0x01));
    }
}
