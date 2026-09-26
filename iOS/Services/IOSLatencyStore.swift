import Foundation
import TermoEngine

/// 主机列表的延迟探测：经 SSH 端口协议首包测真实链路延迟（HostReachabilityProbe 在 TermoEngine，
/// 与 macOS 同一实现）。进入列表与列表变化时后台刷新。
@MainActor
final class IOSLatencyStore: ObservableObject {
    /// hostID → 延迟毫秒；nil = 不可达/超时。未探测的主机不在字典里。
    @Published private(set) var latency: [String: Int?] = [:]

    private var generation = UUID()

    func probe(_ hosts: [IOSHost]) {
        generation = UUID()
        let gen = generation
        let targets = hosts.map { (id: $0.id, host: $0.ssh.host, port: $0.ssh.port) }
            .filter { !$0.host.isEmpty }
        Task.detached { [weak self] in
            for target in targets {
                let result = HostReachabilityProbe.measure(host: target.host, port: target.port)
                let ms = result.reachable ? result.latencyMs : nil
                await MainActor.run { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.latency[target.id] = ms
                }
            }
        }
    }
}
