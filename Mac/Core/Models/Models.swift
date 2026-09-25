import SwiftUI

enum Section: Hashable {
    case hosts, files, sshKeys, snippets, sync, settings
}

enum SettingsTab: String, CaseIterable, Hashable {
    case general = "通用"
    case ai = "AI 助手"
    case sshKeys = "密钥"
    case terminal = "终端"
    case transfer = "传输"
    case sync = "同步与备份"
    case monitor = "监控"
    case security = "安全"
    case keys = "快捷键"
    case about = "关于"

    var label: String {
        switch self {
        case .general: return String(localized: "通用")
        case .ai: return String(localized: "AI 助手")
        case .terminal: return String(localized: "终端")
        case .transfer: return String(localized: "传输")
        case .sync: return String(localized: "同步与备份")
        case .monitor: return String(localized: "资源告警")
        case .security: return String(localized: "安全")
        case .sshKeys: return String(localized: "密钥")
        case .keys: return String(localized: "快捷键")
        case .about: return String(localized: "关于")
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .terminal: return "terminal"
        case .transfer: return "arrow.up.arrow.down"
        case .sync: return "arrow.triangle.2.circlepath"
        case .monitor: return "speedometer"
        case .security: return "lock.shield"
        case .sshKeys: return "key"
        case .keys: return "command"
        case .about: return "info.circle"
        }
    }
}

enum TabKind {
    case overview, terminal, files
}

struct TabItem: Identifiable {
    let id: Int
    let kind: TabKind
    var title: String
    var hostId: String?
}

enum HostStatus: String, Codable {
    case online, offline, unknown
}

/// 一次主机会话/操作记录（终端、上传、端口转发），用于「最近会话」。
enum SessionKind: String, Codable {
    case terminal, files, upload, portForward

    /// 旧数据兼容：hosts/sessions 历史里可能残留 "rdp"，解码时归入 terminal（RDP 已移除）。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionKind(rawValue: raw) ?? .terminal
    }

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .upload: return "arrow.up.circle"
        case .portForward: return "arrow.left.arrow.right"
        }
    }
}

struct SessionEvent: Codable, Identifiable {
    var id = UUID()
    let hostId: String
    let kind: SessionKind
    let detail: String
    let timestamp: Date
}

/// 主机的 SSH 连接配置；认证由进程内引擎消费，密码独立存于 Keychain。
struct SSHConnection: Codable, Equatable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, keyId, encoding, hostKeyAlgos, ciphers, kexAlgos
        case proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath, monitoringEnabled
    }

    var user: String = "root"
    var host: String = ""
    var port: Int = 22
    var authMethod: AuthMethod = .password
    var password: String = ""
    var keyPath: String = ""
    var keyId: String = ""   // 关联密钥库的密钥 id；非空则用库密钥（连接时落 0600 工作文件），优先于 keyPath
    var encoding: String = ""
    var hostKeyAlgos: String = ""
    var ciphers: String = ""
    var kexAlgos: String = ""
    var proxyURL: String = ""
    var disableProxy: Bool = false
    var timeoutMs: Int = 10000
    var heartbeatMs: Int = 5000
    var initialCommand: String = ""
    var defaultPath: String = "~"
    /// 每台主机独立保存并同步；缺失/null 表示默认开启，仅显式 false 停止采集。
    var monitoringEnabled: Bool? = nil

    /// 当前是否已具备自动连接所需凭证：「每次询问」需已输入本会话密码；其它方式恒为 true。
    /// 用于门控后台监控/规格探测——无凭证时跳过（UI 显示占位、不反复弹密码框），有凭证后正常采集。
    var hasUsableCredentials: Bool {
        authMethod == .ask ? !password.isEmpty : true
    }


}

/// SSH 探测得到的主机规格（真实数据，连接成功后填充）。
struct HostSpecs: Codable {
    enum CodingKeys: String, CodingKey { case os, cores, memory, disk, vram, gpu, probedAt }

    var os: String = ""
    var cores: String = ""
    var memory: String = ""
    var disk: String = ""
    var vram: String = ""   // 显存（检测到 NVIDIA 显卡时填充；空=无独显或无法检测）
    var gpu: String = ""    // 显卡型号（可选）
    var probedAt: Date? = nil   // 上次成功探测时间，用于 TTL 缓存：系统信息变化慢，无需每次打开概览都重探

    var isEmpty: Bool {
        os.isEmpty && cores.isEmpty && memory.isEmpty && disk.isEmpty && vram.isEmpty && gpu.isEmpty
    }
}

extension HostSpecs {
    // 容错解码：旧 hosts.json 缺少 vram/gpu（乃至其它）键时按空串处理，
    // 否则合成解码器会抛 keyNotFound，导致整台主机加载失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        cores = try c.decodeIfPresent(String.self, forKey: .cores) ?? ""
        memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? ""
        disk = try c.decodeIfPresent(String.self, forKey: .disk) ?? ""
        vram = try c.decodeIfPresent(String.self, forKey: .vram) ?? ""
        gpu = try c.decodeIfPresent(String.self, forKey: .gpu) ?? ""
        probedAt = try c.decodeIfPresent(Date.self, forKey: .probedAt)
    }
}

/// 单个挂载点的磁盘用量（1K 块）。
struct DiskUsage: Identifiable {
    var id: String { mount }
    let mount: String
    let usedKB: Int64
    let totalKB: Int64
    var device: String = ""
    var percent: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0 }
}

/// 单块 GPU 的实时状态。NVIDIA 使用 nvidia-smi；AMD 使用内核 DRM sysfs；
/// Intel 可识别设备，但没有统一可读的占用率来源时保留 nil。显存以 MiB 计。
struct GPUInfo: Identifiable {
    var id: String { "\(vendor):\(index)" }
    let index: Int
    let vendor: String
    let name: String
    let utilPercent: Double?
    let memUsedMB: Int64?
    let memTotalMB: Int64?
    let tempC: Int?
    /// 指标来源；仅用于说明哪些值由驱动工具或内核提供。
    var source: String = ""
    var uuid: String = ""
    /// 显存占用比；任一值不可用（[N/A]）时为 nil，调用方据此跳过进度条。
    var memPercent: Double? {
        guard let used = memUsedMB, let total = memTotalMB, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

enum GPUCollectionStatus: String {
    case available = "OK"
    case noDevice = "NONE"
    case toolMissing = "TOOL_MISSING"
    case queryFailed = "QUERY_FAILED"
    case deviceUnavailable = "DEVICE_UNAVAILABLE"
}

/// 单张网卡的速率。计数器首次出现、重置或回退时速率为 nil，避免瞬时尖峰。
struct NetworkInterfaceUsage: Identifiable {
    var id: String { name }
    let name: String
    let rxBytesPerSec: Double?
    let txBytesPerSec: Double?
}

/// 一帧网速采样（字节/秒），用于网络波动折线图。
struct NetSample {
    let rx: Double
    let tx: Double
}

/// CPU 使用率以一个逻辑核心为 100%，通过相邻采样差值计算。
struct MonitorProcess: Identifiable {
    var id: String { "\(pid):\(startTicks)" }
    let pid: Int
    let startTicks: UInt64
    let name: String
    let cpuPercent: Double?
    let memoryKB: Int64
}

struct GPUProcessUsage: Identifiable {
    var id: String { "\(gpuUUID):\(pid)" }
    let gpuUUID: String
    let pid: Int
    let name: String
    let memoryMB: Int64?
}

struct NetworkProcessUsage: Identifiable {
    var id: Int { pid }
    let pid: Int
    let name: String
    let connections: Int
}

/// 主机实时监控的一帧采样（由 HostMonitor 流式解析 Linux /proc、DRM sysfs 与 nvidia-smi 得到，不持久化）。
/// 速率与占用类字段需相邻两帧差值，首帧为 nil；内存以 kB（1K 块）计。
struct HostMetrics {
    var cpuPercent: Double? = nil      // 整机 CPU 占用，0–100
    var perCore: [Double] = []          // 每核 CPU 占用，0–100，按核序号排列
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var memUsedKB: Int64 = 0
    var memTotalKB: Int64 = 0
    var swapUsedKB: Int64 = 0
    var swapTotalKB: Int64 = 0
    var disks: [DiskUsage] = []
    var gpus: [GPUInfo] = []
    var gpuStatus: GPUCollectionStatus = .noDevice
    var processes: [MonitorProcess] = []
    var processesAvailable = false
    var gpuProcesses: [GPUProcessUsage] = []
    var gpuProcessesAvailable = false
    var networkProcesses: [NetworkProcessUsage] = []
    var networkProcessesAvailable = false
    var interfaces: [NetworkInterfaceUsage] = []
    var netRxBytesPerSec: Double? = nil
    var netTxBytesPerSec: Double? = nil
    var uptimeSecs: Double = 0

    var memPercent: Double { memTotalKB > 0 ? Double(memUsedKB) / Double(memTotalKB) * 100 : 0 }
    var hasSwap: Bool { swapTotalKB > 0 }
    var swapPercent: Double { swapTotalKB > 0 ? Double(swapUsedKB) / Double(swapTotalKB) * 100 : 0 }
}

struct Host: Identifiable, Codable {
    // latencyMs 是运行时探测结果，不写入 JSON
    enum CodingKeys: String, CodingKey {
        case id, name, addr, group, status, os, port, ssh, notes, specs
    }

    let id: String
    let name: String
    let addr: String
    let group: String
    var status: HostStatus
    let os: String
    var port: Int = 22
    var ssh: SSHConnection? = nil
    var notes: String = ""
    var specs: HostSpecs? = nil
    var latencyMs: Int? = nil
    /// 仅主机名/IP（不含登录用户）。
    var ipOrHost: String {
        if let h = ssh?.host, !h.isEmpty { return h }
        return addr.contains("@") ? String(addr.split(separator: "@").last ?? "") : addr
    }
}
