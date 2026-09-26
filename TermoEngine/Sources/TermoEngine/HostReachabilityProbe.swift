import Darwin
import Foundation

public enum HostReachabilityProbe {
    /// 连接 SSH 端口后以协议首包测量真实链路延迟，避免只测到本地代理的 TCP 延迟。
    public static func measure(host: String, port: Int) -> (reachable: Bool, latencyMs: Int?) {
        var reachable = false
        var smallSample: Int?
        for _ in 0..<3 {
            let (connected, latency) = probeOnce(host: host, port: port, timeout: 5)
            if connected { reachable = true }
            if let latency {
                if latency >= 3 { return (true, latency) }
                smallSample = latency
            }
        }
        return (reachable, reachable ? smallSample : nil)
    }

    private static func probeOnce(host: String, port: Int, timeout: Double) -> (Bool, Int?) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0,
            let info = result,
            let address = info.pointee.ai_addr
        else { return (false, nil) }
        defer { freeaddrinfo(result) }

        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard descriptor >= 0 else { return (false, nil) }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        if connect(descriptor, address, info.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS, wait(descriptor, event: POLLOUT, timeout: timeout) else {
                return (false, nil)
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else { return (false, nil) }
        }

        var buffer = [UInt8](repeating: 0, count: 512)
        guard wait(descriptor, event: POLLIN, timeout: timeout),
            recv(descriptor, &buffer, buffer.count, 0) > 0
        else { return (true, nil) }

        let version = "SSH-2.0-termo\r\n"
        _ = version.withCString { send(descriptor, $0, strlen($0), 0) }
        let startedAt = DispatchTime.now()
        guard wait(descriptor, event: POLLIN, timeout: timeout),
            recv(descriptor, &buffer, buffer.count, 0) > 0
        else { return (true, nil) }

        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds
        return (true, Int(Double(elapsed) / 1_000_000))
    }

    private static func wait(_ descriptor: Int32, event: Int32, timeout: Double) -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(event), revents: 0)
        return poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0
    }
}
