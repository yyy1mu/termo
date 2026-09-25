//! Bounded proxy handshakes. The enclosing connection deadline and cancellation own the socket.
use crate::options::Proxy;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

pub async fn tunnel(
    stream: &mut TcpStream,
    proxy: &Proxy,
    host: &str,
    port: u16,
) -> Result<(), String> {
    if host.is_empty() || host.bytes().any(|b| b <= 32 || b == 127) {
        return Err("目标主机地址无效".into());
    }
    let result = if proxy.kind == 1 {
        socks5(stream, host, port).await
    } else {
        http(stream, host, port).await
    };
    result.map_err(|e| format!("代理连接失败: {e}"))
}

async fn socks5(s: &mut TcpStream, host: &str, port: u16) -> Result<(), std::io::Error> {
    s.write_all(&[5, 1, 0]).await?;
    let mut reply = [0; 2];
    s.read_exact(&mut reply).await?;
    if reply != [5, 0] {
        return Err(invalid("SOCKS5 代理要求当前未配置的认证方式"));
    }
    let mut request = vec![5, 1, 0];
    match host.parse::<std::net::IpAddr>() {
        Ok(std::net::IpAddr::V4(ip)) => {
            request.push(1);
            request.extend(ip.octets());
        }
        Ok(std::net::IpAddr::V6(ip)) => {
            request.push(4);
            request.extend(ip.octets());
        }
        Err(_) => {
            if host.len() > 255 {
                return Err(invalid("目标域名过长"));
            }
            request.extend([3, host.len() as u8]);
            request.extend(host.as_bytes());
        }
    }
    request.extend(port.to_be_bytes());
    s.write_all(&request).await?;
    let mut header = [0; 4];
    s.read_exact(&mut header).await?;
    if header[..3] != [5, 0, 0] {
        return Err(invalid("SOCKS5 拒绝连接目标主机"));
    }
    let count = match header[3] {
        1 => 4,
        4 => 16,
        3 => s.read_u8().await? as usize,
        _ => return Err(invalid("SOCKS5 响应无效")),
    };
    let mut rest = vec![0; count + 2];
    s.read_exact(&mut rest).await?;
    Ok(())
}

async fn http(s: &mut TcpStream, host: &str, port: u16) -> Result<(), std::io::Error> {
    let target = if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    s.write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n").as_bytes())
        .await?;
    // Read exactly through the header terminator so an immediately following SSH banner is retained.
    let mut response = Vec::new();
    loop {
        if response.len() >= 16384 {
            return Err(invalid("HTTP 代理响应头过长"));
        }
        response.push(s.read_u8().await?);
        if response.ends_with(b"\r\n\r\n") {
            break;
        }
    }
    let status = response.split(|b| *b == b'\n').next().unwrap_or_default();
    let text = String::from_utf8_lossy(status);
    let mut fields = text.split_whitespace();
    if !matches!(fields.next(), Some("HTTP/1.0" | "HTTP/1.1")) || fields.next() != Some("200") {
        return Err(invalid("HTTP CONNECT 未获批准，请检查代理地址和认证信息"));
    }
    Ok(())
}
fn invalid(message: &str) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidData, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socks5_uses_remote_dns_and_consumes_the_full_reply() {
        crate::runtime().block_on(async {
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut greeting = [0; 3];
                stream.read_exact(&mut greeting).await.unwrap();
                assert_eq!(greeting, [5, 1, 0]);
                stream.write_all(&[5, 0]).await.unwrap();
                let mut header = [0; 5];
                stream.read_exact(&mut header).await.unwrap();
                assert_eq!(&header[..4], &[5, 1, 0, 3]);
                let mut rest = vec![0; header[4] as usize + 2];
                stream.read_exact(&mut rest).await.unwrap();
                assert_eq!(&rest[..rest.len() - 2], b"target.invalid");
                stream
                    .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 22])
                    .await
                    .unwrap();
            });
            let mut stream = TcpStream::connect(address).await.unwrap();
            let proxy = Proxy {
                kind: 1,
                host: address.ip().to_string(),
                port: address.port(),
            };
            tunnel(&mut stream, &proxy, "target.invalid", 22)
                .await
                .unwrap();
            server.await.unwrap();
        });
    }

    #[test]
    fn http_connect_does_not_consume_the_ssh_banner() {
        crate::runtime().block_on(async {
            let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0))
                .await
                .unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                loop {
                    request.push(stream.read_u8().await.unwrap());
                    if request.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                assert!(String::from_utf8(request)
                    .unwrap()
                    .starts_with("CONNECT target.invalid:22 HTTP/1.1"));
                stream
                    .write_all(b"HTTP/1.1 200 Connection established\r\n\r\nSSH-2.0-test\r\n")
                    .await
                    .unwrap();
            });
            let mut stream = TcpStream::connect(address).await.unwrap();
            let proxy = Proxy {
                kind: 2,
                host: address.ip().to_string(),
                port: address.port(),
            };
            tunnel(&mut stream, &proxy, "target.invalid", 22)
                .await
                .unwrap();
            let mut banner = [0; 14];
            stream.read_exact(&mut banner).await.unwrap();
            assert_eq!(&banner, b"SSH-2.0-test\r\n");
            server.await.unwrap();
        });
    }
}
