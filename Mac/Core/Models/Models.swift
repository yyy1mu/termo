import SwiftUI
import TermoCore

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

    var label: LocalizedStringKey {
        switch self {
        case .general: return "通用"
        case .ai: return "AI 助手"
        case .terminal: return "终端"
        case .transfer: return "传输"
        case .sync: return "同步与备份"
        case .monitor: return "资源告警"
        case .security: return "安全"
        case .sshKeys: return "密钥"
        case .keys: return "快捷键"
        case .about: return "关于"
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

/// 主机的 SSH 连接配置（SSHConnection）与认证方式（AuthMethod）已下沉至 TermoCore，供三端共用。

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

// 主机监控采样模型（HostMetrics、DiskUsage、GPUInfo、NetSample、MonitorProcess 等）
// 已下沉至 TermoCore/Sources/TermoCore/Models/HostMetrics.swift，供 macOS/iOS 共用。

struct Host: Identifiable, Codable {
    // latencyMs 是运行时探测结果，不写入 JSON
    enum CodingKeys: String, CodingKey {
        case id, name, addr, group, status, os, port, ssh, notes, specs
    }

    let id: String
    let name: String
    let addr: String
    var group: String
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
