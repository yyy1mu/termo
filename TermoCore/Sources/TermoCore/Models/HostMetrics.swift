import Foundation

/// 主机监控的采样模型（纯 Foundation，三端共享）。由 TermoEngine 的 HostMetricsParser 产出，
/// 各端 UI 自行渲染；不持久化。

/// 单个挂载点的磁盘用量（1K 块）。
public struct DiskUsage: Identifiable, Sendable {
    public var id: String { mount }
    public let mount: String
    public let usedKB: Int64
    public let totalKB: Int64
    public var device: String = ""
    public var percent: Double { totalKB > 0 ? Double(usedKB) / Double(totalKB) * 100 : 0 }

    public init(mount: String, usedKB: Int64, totalKB: Int64, device: String = "") {
        self.mount = mount
        self.usedKB = usedKB
        self.totalKB = totalKB
        self.device = device
    }
}

/// 单块 GPU 的实时状态。NVIDIA 使用 nvidia-smi；AMD 使用内核 DRM sysfs；
/// Intel 可识别设备，但没有统一可读的占用率来源时保留 nil。显存以 MiB 计。
public struct GPUInfo: Identifiable, Sendable {
    public var id: String { "\(vendor):\(index)" }
    public let index: Int
    public let vendor: String
    public let name: String
    public let utilPercent: Double?
    public let memUsedMB: Int64?
    public let memTotalMB: Int64?
    public let tempC: Int?
    /// 指标来源；仅用于说明哪些值由驱动工具或内核提供。
    public var source: String = ""
    public var uuid: String = ""
    /// 显存占用比；任一值不可用（[N/A]）时为 nil，调用方据此跳过进度条。
    public var memPercent: Double? {
        guard let used = memUsedMB, let total = memTotalMB, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }

    public init(index: Int, vendor: String, name: String,
                utilPercent: Double?, memUsedMB: Int64?, memTotalMB: Int64?, tempC: Int?,
                source: String = "", uuid: String = "") {
        self.index = index
        self.vendor = vendor
        self.name = name
        self.utilPercent = utilPercent
        self.memUsedMB = memUsedMB
        self.memTotalMB = memTotalMB
        self.tempC = tempC
        self.source = source
        self.uuid = uuid
    }
}

public enum GPUCollectionStatus: String, Sendable {
    case available = "OK"
    case noDevice = "NONE"
    case toolMissing = "TOOL_MISSING"
    case queryFailed = "QUERY_FAILED"
    case deviceUnavailable = "DEVICE_UNAVAILABLE"
}

/// 单张网卡的速率。计数器首次出现、重置或回退时速率为 nil，避免瞬时尖峰。
public struct NetworkInterfaceUsage: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let rxBytesPerSec: Double?
    public let txBytesPerSec: Double?

    public init(name: String, rxBytesPerSec: Double?, txBytesPerSec: Double?) {
        self.name = name
        self.rxBytesPerSec = rxBytesPerSec
        self.txBytesPerSec = txBytesPerSec
    }
}

/// 一帧网速采样（字节/秒），用于网络波动折线图。
public struct NetSample: Sendable {
    public let rx: Double
    public let tx: Double

    public init(rx: Double, tx: Double) {
        self.rx = rx
        self.tx = tx
    }
}

/// CPU 使用率以一个逻辑核心为 100%，通过相邻采样差值计算。
public struct MonitorProcess: Identifiable, Sendable {
    public var id: String { "\(pid):\(startTicks)" }
    public let pid: Int
    public let startTicks: UInt64
    public let name: String
    public let cpuPercent: Double?
    public let memoryKB: Int64

    public init(pid: Int, startTicks: UInt64, name: String, cpuPercent: Double?, memoryKB: Int64) {
        self.pid = pid
        self.startTicks = startTicks
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryKB = memoryKB
    }
}

public struct GPUProcessUsage: Identifiable, Sendable {
    public var id: String { "\(gpuUUID):\(pid)" }
    public let gpuUUID: String
    public let pid: Int
    public let name: String
    public let memoryMB: Int64?

    public init(gpuUUID: String, pid: Int, name: String, memoryMB: Int64?) {
        self.gpuUUID = gpuUUID
        self.pid = pid
        self.name = name
        self.memoryMB = memoryMB
    }
}

public struct NetworkProcessUsage: Identifiable, Sendable {
    public var id: Int { pid }
    public let pid: Int
    public let name: String
    public let connections: Int

    public init(pid: Int, name: String, connections: Int) {
        self.pid = pid
        self.name = name
        self.connections = connections
    }
}

/// 主机实时监控的一帧采样（由 /proc、DRM sysfs 与 nvidia-smi 流式解析得到，不持久化）。
/// 速率与占用类字段需相邻两帧差值，首帧为 nil；内存以 kB（1K 块）计。
public struct HostMetrics: Sendable {
    public var cpuPercent: Double? = nil      // 整机 CPU 占用，0–100
    public var perCore: [Double] = []          // 每核 CPU 占用，0–100，按核序号排列
    public var load1: Double = 0
    public var load5: Double = 0
    public var load15: Double = 0
    public var memUsedKB: Int64 = 0
    public var memTotalKB: Int64 = 0
    public var swapUsedKB: Int64 = 0
    public var swapTotalKB: Int64 = 0
    public var disks: [DiskUsage] = []
    public var gpus: [GPUInfo] = []
    public var gpuStatus: GPUCollectionStatus = .noDevice
    public var processes: [MonitorProcess] = []
    public var processesAvailable = false
    public var gpuProcesses: [GPUProcessUsage] = []
    public var gpuProcessesAvailable = false
    public var networkProcesses: [NetworkProcessUsage] = []
    public var networkProcessesAvailable = false
    public var interfaces: [NetworkInterfaceUsage] = []
    public var netRxBytesPerSec: Double? = nil
    public var netTxBytesPerSec: Double? = nil
    public var uptimeSecs: Double = 0

    public init(
        cpuPercent: Double? = nil,
        perCore: [Double] = [],
        load1: Double = 0,
        load5: Double = 0,
        load15: Double = 0,
        memUsedKB: Int64 = 0,
        memTotalKB: Int64 = 0,
        swapUsedKB: Int64 = 0,
        swapTotalKB: Int64 = 0,
        disks: [DiskUsage] = [],
        gpus: [GPUInfo] = [],
        gpuStatus: GPUCollectionStatus = .noDevice,
        processes: [MonitorProcess] = [],
        processesAvailable: Bool = false,
        gpuProcesses: [GPUProcessUsage] = [],
        gpuProcessesAvailable: Bool = false,
        networkProcesses: [NetworkProcessUsage] = [],
        networkProcessesAvailable: Bool = false,
        interfaces: [NetworkInterfaceUsage] = [],
        netRxBytesPerSec: Double? = nil,
        netTxBytesPerSec: Double? = nil,
        uptimeSecs: Double = 0
    ) {
        self.cpuPercent = cpuPercent
        self.perCore = perCore
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.memUsedKB = memUsedKB
        self.memTotalKB = memTotalKB
        self.swapUsedKB = swapUsedKB
        self.swapTotalKB = swapTotalKB
        self.disks = disks
        self.gpus = gpus
        self.gpuStatus = gpuStatus
        self.processes = processes
        self.processesAvailable = processesAvailable
        self.gpuProcesses = gpuProcesses
        self.gpuProcessesAvailable = gpuProcessesAvailable
        self.networkProcesses = networkProcesses
        self.networkProcessesAvailable = networkProcessesAvailable
        self.interfaces = interfaces
        self.netRxBytesPerSec = netRxBytesPerSec
        self.netTxBytesPerSec = netTxBytesPerSec
        self.uptimeSecs = uptimeSecs
    }

    public var memPercent: Double { memTotalKB > 0 ? Double(memUsedKB) / Double(memTotalKB) * 100 : 0 }
    public var hasSwap: Bool { swapTotalKB > 0 }
    public var swapPercent: Double { swapTotalKB > 0 ? Double(swapUsedKB) / Double(swapTotalKB) * 100 : 0 }
}
