//! Cancellation and socket ownership for connection attempts, before a session exists.
use std::future::Future;
use std::net::Shutdown;

/// One-shot, thread-safe cancellation. A late subscriber still observes cancellation.
pub struct ConnectionCancellation(tokio::sync::watch::Sender<bool>);

impl ConnectionCancellation {
    pub fn new() -> Self {
        Self(tokio::sync::watch::channel(false).0)
    }

    pub fn cancel(&self) {
        self.0.send_replace(true);
    }

    pub fn is_cancelled(&self) -> bool {
        *self.0.borrow()
    }

    pub async fn run<T>(&self, work: impl Future<Output = T>) -> Option<T> {
        let mut signal = self.0.subscribe();
        tokio::select! {
            biased;
            _ = signal.wait_for(|cancelled| *cancelled) => None,
            result = work => Some(result),
        }
    }
}

/// russh spawns its transport task during key exchange. Dropping its connect future
/// alone does not own that task; shutdown the duplicated socket on every aborted path.
pub(crate) struct ConnectionSocket(Option<std::net::TcpStream>);

impl ConnectionSocket {
    pub async fn connect(
        host: &str,
        port: u16,
        completed: &impl Fn(i32),
        proxy: Option<&crate::options::Proxy>,
    ) -> Result<(tokio::net::TcpStream, Self), String> {
        let (endpoint, endpoint_port) = proxy
            .map(|p| (p.host.as_str(), p.port))
            .unwrap_or((host, port));
        let addresses: Vec<_> = tokio::net::lookup_host((endpoint, endpoint_port))
            .await
            .map_err(|e| format!("无法解析主机 {host}: {e}"))?
            .collect();
        if addresses.is_empty() {
            return Err(format!("无法解析主机 {host}"));
        }
        completed(1);
        let socket = tokio::net::TcpStream::connect(addresses.as_slice())
            .await
            .map_err(|e| format!("无法建立 TCP 连接 {host}:{port}: {e}"))?;
        let socket = socket.into_std().map_err(|e| e.to_string())?;
        let guard = Self(Some(socket.try_clone().map_err(|e| e.to_string())?));
        let mut socket = tokio::net::TcpStream::from_std(socket).map_err(|e| e.to_string())?;
        if let Some(proxy) = proxy {
            crate::proxy::tunnel(&mut socket, proxy, host, port).await?;
        }
        completed(2);
        Ok((socket, guard))
    }

    /// The authenticated session has accepted ownership of the transport.
    pub fn disarm(mut self) {
        self.0.take();
    }
}

impl Drop for ConnectionSocket {
    fn drop(&mut self) {
        if let Some(socket) = &self.0 {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}
