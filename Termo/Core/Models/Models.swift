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
        case .monitor: return String(localized: "监控")
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
    var filePath: String? = nil
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

/// 一台主机的 SSH 连接配置，用于构建真实的 ssh 命令。
struct SSHConnection: Codable, Equatable {
    // 密码不进 JSON（存 Keychain），其余字段全部持久化
    enum CodingKeys: String, CodingKey {
        case user, host, port, authMethod, keyPath, keyId, encoding, hostKeyAlgos, ciphers, kexAlgos
        case proxyURL, disableProxy, timeoutMs, heartbeatMs, initialCommand, defaultPath
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

    var usesPassword: Bool {
        authMethod == .password && !password.isEmpty
    }

    /// 是否需要 askpass 自动喂密码：密码登录喂密码、密钥登录喂私钥 passphrase、每次询问喂弹窗输入的一次性密码。
    var needsAskpass: Bool {
        !password.isEmpty && (authMethod == .password || authMethod == .key || authMethod == .ask)
    }

    /// 当前是否已具备自动连接所需凭证：「每次询问」需已输入本会话密码；其它方式恒为 true。
    /// 用于门控后台监控/规格探测——无凭证时跳过（UI 显示占位、不反复弹密码框），有凭证后正常采集。
    var hasUsableCredentials: Bool {
        authMethod == .ask ? !password.isEmpty : true
    }

    /// 把「终端显示编码」映射为远端 locale，经 SetEnv 转发（best-effort，依赖服务器有该 locale）。
    private var remoteLocale: String? {
        switch encoding {
        case "", "UTF-8": return encoding == "UTF-8" ? "en_US.UTF-8" : nil
        case "GBK": return "zh_CN.GBK"
        case "GB2312": return "zh_CN.GB2312"
        case "GB18030": return "zh_CN.GB18030"
        case "Big5": return "zh_TW.Big5"
        case "Shift_JIS": return "ja_JP.SJIS"
        case "EUC-JP": return "ja_JP.eucJP"
        case "EUC-KR": return "ko_KR.eucKR"
        case "KOI8-R": return "ru_RU.KOI8-R"
        case "ISO-8859-1": return "en_US.ISO8859-1"
        case "ISO-8859-15": return "en_US.ISO8859-15"
        case "Windows-1251": return "ru_RU.CP1251"
        case "Windows-1252": return "en_US.CP1252"
        case "ASCII": return "C"
        default: return nil
        }
    }

    /// 构建传给 ssh 的参数（不含 ssh 本身）。verbose 用于测试连接以解析流程。
    func sshArguments(verbose: Bool = false, multiplex: Bool = false, ephemeralKnownHosts: Bool = false) -> [String] {
        var a: [String] = []
        if verbose { a.append("-v") }
        // 连接复用：文件浏览等高频操作共享一条主连接，认证只触发一次（%C 是定长哈希，避免 socket 路径过长）
        if multiplex {
            a += ["-o", "ControlMaster=auto",
                  "-o", "ControlPath=\(NSHomeDirectory())/.termo/cm/%C",
                  "-o", "ControlPersist=120"]
        }
        // 主机密钥校验：未知主机由 App 的指纹验证弹窗预先写入 known_hosts，这里用 yes 严格校验。
        // 测试连接用临时 known_hosts（accept-new + /dev/null），不静默写入用户的 known_hosts。
        if ephemeralKnownHosts {
            a += ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/dev/null"]
        } else {
            a += ["-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(HostKeyVerifier.userKnownHostsArg())"]
        }
        // 每次询问：密码经 askpass 一次性喂入，故只走 password 认证、限 1 次。
        a += ["-o", "NumberOfPasswordPrompts=1"]
        if authMethod == .ask { a += ["-o", "PreferredAuthentications=password"] }
        a += ["-p", String(port)]
        if timeoutMs > 0 { a += ["-o", "ConnectTimeout=\(max(1, timeoutMs / 1000))"] }
        if heartbeatMs > 0 { a += ["-o", "ServerAliveInterval=\(max(1, heartbeatMs / 1000))"] }
        // 密钥登录：指定私钥文件，只用它（不尝试 agent/默认 key）。
        // 关联了密钥库的密钥（keyId）时，把库私钥落成 0600 工作文件再用，优先于手填的 keyPath。
        if authMethod == .key {
            let path = keyId.isEmpty ? keyPath : (KeyMaterializer.path(forKeyId: keyId) ?? keyPath)
            if !path.isEmpty { a += ["-i", path, "-o", "IdentitiesOnly=yes"] }
        }
        // 终端显示编码：把对应 locale 转发给远端（依赖服务器 AcceptEnv LC_*）
        if let loc = remoteLocale { a += ["-o", "SetEnv=LC_ALL=\(loc)"] }
        if !ciphers.isEmpty { a += ["-c", ciphers] }
        if !kexAlgos.isEmpty { a += ["-o", "KexAlgorithms=\(kexAlgos)"] }
        if !hostKeyAlgos.isEmpty { a += ["-o", "HostKeyAlgorithms=\(hostKeyAlgos)"] }
        if !disableProxy, !proxyURL.isEmpty, let pc = proxyCommand() {
            a += ["-o", "ProxyCommand=\(pc)"]
        }
        a += ["\(user)@\(host)"]
        return a
    }

    /// 把 socks/http 代理 URL 转换为 ssh ProxyCommand（基于 nc）。
    /// 注意：返回值会被 ssh 经 /bin/sh -c 执行，必须严格校验 host/port，
    /// 否则形如 `socks5://h$(touch /tmp/x):1080` 的代理 URL 会导致本地命令注入。
    private func proxyCommand() -> String? {
        guard let comps = URLComponents(string: proxyURL),
              let scheme = comps.scheme?.lowercased(),
              let phost = comps.host, let pport = comps.port else { return nil }
        // 代理主机只允许主机名/IPv4 字符；端口必须在合法范围内。任何 shell 元字符一律拒绝。
        let hostOK = phost.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        guard hostOK, (1...65535).contains(pport) else { return nil }
        switch scheme {
        case "socks5", "socks5h": return "nc -X 5 -x \(phost):\(pport) %h %p"
        case "socks4": return "nc -X 4 -x \(phost):\(pport) %h %p"
        case "http", "https": return "nc -X connect -x \(phost):\(pport) %h %p"
        default: return nil
        }
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
