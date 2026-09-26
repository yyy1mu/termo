import SwiftUI
import TermoCore

/// 主机详情的实时监控区：卡片式网格（自适应列宽，iPhone 单列、iPad 多列）。
/// 信息结构参照 macOS MonitorPanel（CPU/内存/磁盘/网络/GPU），布局按 iOS 习惯重做。
struct IOSHostMonitorSection: View {
    @ObservedObject var monitor: IOSHostMonitor
    let host: IOSHost

    /// 自适应列：iPhone 竖屏一列、横屏/iPad 两列起步。
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        Section(String(localized: "实时监控")) {
            if !host.ssh.hasUsableCredentials {
                placeholder(
                    icon: "lock",
                    text: String(localized: "「每次询问」主机需先连接一次终端输入密码，监控才会开始采集。"))
            } else {
                switch monitor.phase {
                case .stopped:
                    placeholder(icon: "pause.circle", text: String(localized: "监控已停止"))
                case .connecting:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: "正在连接监控通道…"))
                            .font(.caption).foregroundStyle(IOSTheme.subtext)
                    }
                case .unsupported:
                    placeholder(icon: "questionmark.circle",
                                text: String(localized: "该主机不支持监控（远端无 /proc）。"))
                case .failed(let message):
                    placeholder(icon: "exclamationmark.triangle", text: message)
                case .live:
                    if let m = monitor.metrics { cards(m) }
                }
            }
        }
    }

    private func placeholder(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(IOSTheme.subtext)
            Text(text).font(.caption).foregroundStyle(IOSTheme.subtext)
        }
    }

    @ViewBuilder
    private func cards(_ m: HostMetrics) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            card(String(localized: "CPU"), systemImage: "cpu") {
                Text(percentText(m.cpuPercent))
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(String(localized: "负载 \(f(m.load1)) / \(f(m.load5)) / \(f(m.load15))"))
                    .font(.caption2).foregroundStyle(IOSTheme.subtext)
            }
            card(String(localized: "内存"), systemImage: "memorychip") {
                ProgressView(value: m.memPercent, total: 100).tint(IOSTheme.accent)
                Text("\(kbText(m.memUsedKB)) / \(kbText(m.memTotalKB))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(IOSTheme.subtext)
            }
            card(String(localized: "网络"), systemImage: "network") {
                Text("↓ \(rateText(m.netRxBytesPerSec))")
                    .font(.caption.monospacedDigit())
                Text("↑ \(rateText(m.netTxBytesPerSec))")
                    .font(.caption.monospacedDigit())
            }
            ForEach(m.disks.prefix(3)) { disk in
                card(disk.mount, systemImage: "internaldrive") {
                    ProgressView(value: disk.percent, total: 100).tint(IOSTheme.accent)
                    Text("\(kbText(disk.usedKB)) / \(kbText(disk.totalKB))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(IOSTheme.subtext)
                }
            }
            ForEach(m.gpus) { gpu in
                card(gpu.name, systemImage: "display") {
                    Text(gpu.utilPercent.map { String(format: "%.0f%%", $0) } ?? String(localized: "不可用"))
                        .font(.title3.monospacedDigit().weight(.semibold))
                    if let memPercent = gpu.memPercent {
                        ProgressView(value: memPercent, total: 100).tint(IOSTheme.accent)
                    }
                    if let temp = gpu.tempC {
                        Text("\(temp)℃").font(.caption2).foregroundStyle(IOSTheme.subtext)
                    }
                }
            }
        }
    }

    private func card<Content: View>(
        _ title: String, systemImage: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption).foregroundStyle(IOSTheme.subtext)
                .lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(IOSTheme.card, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 格式化

    private func percentText(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }

    private func f(_ value: Double) -> String { String(format: "%.2f", value) }

    private func kbText(_ kb: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .memory)
    }

    private func rateText(_ bytesPerSec: Double?) -> String {
        guard let bytesPerSec else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec), countStyle: .memory) + "/s"
    }
}
