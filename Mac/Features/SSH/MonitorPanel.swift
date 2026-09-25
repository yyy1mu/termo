import SwiftUI

/// 右侧监控按资源分类，分类导航固定，指标与进程在同一采样中更新。
struct MonitorPanel: View {
    @ObservedObject var monitor: HostMonitor
    var onVerifyHost: (() -> Void)? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showsPerCore = false
    @State private var selectedInterface = ""  // 空值为全部网卡

    @State private var category: MonitorCategory = .cpu

    private enum MonitorCategory: String, CaseIterable, Identifiable {
        case cpu, memory, gpu, network, storage
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "内存"
            case .gpu: return "GPU"
            case .network: return "网络"
            case .storage: return "存储"
            }
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    monitorStatus
                    Spacer(minLength: 6)
                    if let m = monitor.metrics { uptime(m) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    monitorStatus
                    if let m = monitor.metrics { uptime(m) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            HStack(spacing: 2) {
                ForEach(MonitorCategory.allCases) { item in
                    Button { category = item } label: {
                        Text(item.title)
                            .font(.system(size: 11, weight: category == item ? .semibold : .medium))
                            .foregroundStyle(category == item ? Pal.textBright : Pal.subtext)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(category == item ? Pal.card : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }
            .padding(3).background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if monitor.monitoringAllowed, let message = monitor.errorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(message, systemImage: monitor.trustBlocked ? "exclamationmark.shield" : "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(Pal.yellow)
                                .fixedSize(horizontal: false, vertical: true)
                            if monitor.trustBlocked, let onVerifyHost {
                                Button("核对主机指纹", action: onVerifyHost)
                                    .buttonStyle(.bordered).tint(Pal.mauve)
                            }
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pal.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if let m = monitor.metrics {
                        if monitor.phase != .live {
                            Label("显示上次采样，数据尚未更新。", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 11)).foregroundStyle(Pal.yellow)
                        }
                        categoryContent(m)
                    } else if !monitor.monitoringAllowed || monitor.errorMessage == nil {
                        emptyState
                    }
                    if monitor.phase == .live, let fingerprint = monitor.verifiedFingerprint {
                        DisclosureGroup {
                            Text(fingerprint).font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } label: {
                            Label("主机指纹已核对", systemImage: "checkmark.shield")
                        }
                        .font(.system(size: 10)).foregroundStyle(Pal.subtext)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            .id(category)
        }
        .padding(.top, 8)
        .onChange(of: ObjectIdentifier(monitor)) { _, _ in
            selectedInterface = ""
            showsPerCore = false
        }
        .onChange(of: monitor.metrics?.interfaces.map(\.name) ?? []) { _, names in
            if !selectedInterface.isEmpty && !names.contains(selectedInterface) { selectedInterface = "" }
        }
    }

    @ViewBuilder
    private func categoryContent(_ m: HostMetrics) -> some View {
        switch category {
        case .cpu:
            cpuCard(m)
            processSection(m, memory: false)
        case .memory:
            memoryCard(m)
            processSection(m, memory: true)
        case .gpu:
            gpuSection(m)
            gpuProcessSection(m)
        case .network:
            networkSection(m)
            networkProcessSection(m)
        case .storage:
            diskSection(m.disks)
        }
    }

    private var monitorStatus: some View {
        HStack(spacing: 7) {
            Circle().fill(monitor.phase == .live ? Pal.green : monitor.phase == .stopped ? Pal.overlay : Pal.yellow).frame(width: 5, height: 5)
            Text(statusText).font(.system(size: 11)).foregroundStyle(Pal.subtext)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statusText: String {
        switch monitor.phase {
        case .stopped: return String(localized: "监控未运行")
        case .live: return String(localized: "实时采集中")
        case .connecting:
            return monitor.metrics == nil ? String(localized: "连接中") : String(localized: "重连中 · 上次数据")
        case .error:
            return monitor.trustBlocked ? String(localized: "主机验证未通过") : String(localized: "连接中断")
        case .unsupported: return String(localized: "暂不支持")
        }
    }

    private func uptime(_ m: HostMetrics) -> some View {
        Label(uptimeText(m.uptimeSecs), systemImage: "clock")
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Pal.subtext)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var emptyState: some View {
        card {
            HStack(spacing: 10) {
                if monitor.phase == .stopped {
                    Image(systemName: "pause.circle").foregroundStyle(Pal.overlay)
                } else if monitor.phase == .unsupported {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(Pal.overlay)
                } else if monitor.phase == .error {
                    Image(systemName: "wifi.slash").foregroundStyle(Pal.yellow)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(
                    !monitor.monitoringAllowed
                        ? "此主机的监控已关闭，可在编辑主机 → 终端设置中开启。"
                        : monitor.phase == .stopped
                        ? "连接此主机后自动开始监控。"
                        : monitor.phase == .unsupported
                        ? "该系统暂不支持实时监控"
                        : monitor.phase == .error
                            ? "暂时无法获取监控数据，网络恢复后会自动重试。"
                            : "正在获取 CPU、内存与网络数据…"
                )
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    private func coreGrid(_ cores: [Double]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 43), spacing: 6)], spacing: 6) {
            ForEach(cores.indices, id: \.self) { core in
                VStack(spacing: 3) {
                    Text("\(Int(cores[core]))%")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(Pal.text)
                    Text("#\(core + 1)").font(.system(size: 10)).foregroundStyle(Pal.subtext)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background((cores[core] >= 90 ? Pal.red : Pal.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "核心 \(core + 1)：\(Int(cores[core]))%"))
            }
        }
    }

    private func loadValues(_ m: HostMetrics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                loadValue(m.load1, period: "1 分钟")
                loadValue(m.load5, period: "5 分钟")
                loadValue(m.load15, period: "15 分钟")
            }
            VStack(spacing: 8) {
                loadLine(m.load1, period: "1 分钟")
                loadLine(m.load5, period: "5 分钟")
                loadLine(m.load15, period: "15 分钟")
            }
        }
    }

    private func loadLine(_ value: Double, period: LocalizedStringKey) -> some View {
        HStack {
            Text(period).font(.system(size: 11)).foregroundStyle(Pal.subtext)
            Spacer(minLength: 8)
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(Pal.textBright)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func cpuCard(_ m: HostMetrics) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("cpu", "CPU", detail: m.perCore.isEmpty ? "" : String(localized: "\(m.perCore.count) 核"))
                HStack(spacing: 14) {
                    ring(m.cpuPercent, color: Pal.green, size: 72).fixedSize()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("系统负载").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        loadValues(m)
                    }
                }
                if !m.perCore.isEmpty {
                    DisclosureGroup("每核使用率", isExpanded: $showsPerCore) {
                        coreGrid(m.perCore).padding(.top, 8)
                    }
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                } else {
                    detailText(String(localized: "CPU 使用率需要两次采样，正在等待。"))
                }
            }
        }
    }

    private func memoryCard(_ m: HostMetrics) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("memorychip", "内存")
                ring(m.memTotalKB > 0 ? m.memPercent : nil, color: Pal.mauve, size: 72)
                detailText(
                    m.memTotalKB > 0
                        ? String(localized: "已用 \(human(m.memUsedKB)) / \(human(m.memTotalKB))") : "—")
                if m.hasSwap {
                    detailText(
                        String(
                            localized:
                                "交换 \(Int(m.swapPercent))% · \(human(m.swapUsedKB)) / \(human(m.swapTotalKB))"
                        ))
                }
            }
        }
    }

    private func loadValue(_ value: Double, period: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(Pal.textBright)
                .fixedSize(horizontal: true, vertical: false)
            Text(period).font(.system(size: 10)).foregroundStyle(Pal.subtext)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diskSection(_ disks: [DiskUsage]) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("internaldrive", "磁盘", detail: String(localized: "\(disks.count) 个挂载点"))
                if disks.isEmpty {
                    detailText(String(localized: "未检测到可监控的存储卷"))
                }
                ForEach(disks) { disk in
                    HStack(spacing: 10) {
                        ring(disk.percent, color: Pal.mauve, size: 44).fixedSize()
                        VStack(alignment: .leading, spacing: 5) {
                            Text(disk.mount).font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Pal.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !disk.device.isEmpty {
                                Text(disk.device).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                                    .lineLimit(1).truncationMode(.middle).help(disk.device)
                            }
                            detailText(String(localized: "\(human(disk.usedKB)) / \(human(disk.totalKB))"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func gpuSection(_ m: HostMetrics) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("display", "GPU", detail: m.gpus.isEmpty ? String(localized: "未取得指标") : String(localized: "\(m.gpus.count) 张"))
                if m.gpus.isEmpty {
                    Label(gpuStatusText(m.gpuStatus), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if m.gpuStatus != .available {
                        detailText(gpuStatusText(m.gpuStatus))
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                        ForEach(m.gpus) { gpu in gpuMetrics(gpu) }
                    }
                }
            }
        }
    }

    private func gpuMetrics(_ gpu: GPUInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(gpu.vendor) \(gpu.index) · \(gpu.name)")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Pal.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 3) {
                    ring(gpu.utilPercent, color: Pal.mauve, size: 62)
                    detailText(String(localized: "GPU 使用率"))
                }
                VStack(spacing: 3) {
                    ring(gpu.memPercent, color: Pal.yellow, size: 62)
                    detailText(String(localized: "显存占用"))
                }
            }
            detailText(gpuMemoryText(gpu))
            if gpu.utilPercent == nil {
                detailText(gpu.vendor == "Intel"
                    ? String(localized: "此驱动未提供可读取的 GPU 使用率")
                    : String(localized: "驱动未返回 GPU 使用率"))
            }
            HStack(spacing: 8) {
                if let temp = gpu.tempC { detailText(String(localized: "温度 \(temp) °C")) }
                if !gpu.source.isEmpty { detailText(gpu.source) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Pal.fill(0.035), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private func gpuStatusText(_ status: GPUCollectionStatus) -> String {
        switch status {
        case .available: return String(localized: "已连接 GPU 指标源")
        case .noDevice: return String(localized: "远端未检测到可读取的 GPU；请检查驱动和设备是否对 SSH 用户可见。")
        case .toolMissing: return String(localized: "检测到 NVIDIA 设备，但远端未找到 nvidia-smi。请检查驱动工具安装。")
        case .queryFailed: return String(localized: "GPU 查询失败；请在该主机终端运行 nvidia-smi 检查驱动状态和权限。")
        case .deviceUnavailable: return String(localized: "远端没有可读取的 DRM 设备目录；容器或权限设置可能隐藏了 GPU。")
        }
    }

    private func gpuMemoryText(_ gpu: GPUInfo) -> String {
        if let used = gpu.memUsedMB, let total = gpu.memTotalMB, total > 0 {
            return String(localized: "显存 \(human(used * 1024)) / \(human(total * 1024))")
        }
        return gpu.vendor == "Intel" ? String(localized: "共享显存指标不可用") : String(localized: "显存指标不可用")
    }

    private func networkSection(_ m: HostMetrics) -> some View {
        let selected = m.interfaces.first { $0.name == selectedInterface }
        let rx = selected == nil ? m.netRxBytesPerSec : selected?.rxBytesPerSec
        let tx = selected == nil ? m.netTxBytesPerSec : selected?.txBytesPerSec
        let history = selected.map { monitor.netHistoryByInterface[$0.name] ?? [] } ?? monitor.netHistory
        return card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle("network", "网络吞吐", detail: String(localized: "\(m.interfaces.count) 张网卡"))
                if m.interfaces.count > 1 {
                    ThemedDropdown(
                        options: [(value: "", verbatim: String(localized: "全部网卡"))]
                            + m.interfaces.map { (value: $0.name, verbatim: $0.name) },
                        selection: $selectedInterface
                    )
                    .accessibilityLabel("查看网卡速率")
                    if selected == nil {
                        detailText(String(localized: "各网卡速率相加；如有桥接或虚拟网卡，流量可能重复。"))
                    }
                } else if let only = m.interfaces.first {
                    detailText(only.name)
                } else {
                    detailText(String(localized: "未检测到可读取的非回环网卡"))
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        networkRate("接收", symbol: "arrow.down", value: rx, color: Pal.green)
                        networkRate("发送", symbol: "arrow.up", value: tx, color: Pal.yellow)
                    }
                    VStack(spacing: 10) {
                        networkRateLine("接收", symbol: "arrow.down", value: rx, color: Pal.green)
                        networkRateLine("发送", symbol: "arrow.up", value: tx, color: Pal.yellow)
                    }
                }
                VStack(spacing: 5) {
                    if history.count > 1 {
                        HStack {
                            Text(rate(history.suffix(40).flatMap { [$0.rx, $0.tx] }.max()))
                            Spacer()
                        }
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Pal.overlay)
                    }
                    NetSparkline(samples: history, down: Pal.green, up: Pal.yellow)
                        .frame(height: 64)
                    if history.count > 1 {
                        HStack {
                            Text("最近 \(Int(Double(min(history.count, 40) - 1) * monitor.sampleInterval)) 秒")
                            Spacer()
                            Text(monitor.phase == .live ? "现在" : "最后采样")
                        }
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("网络收发速率历史")
            }
        }
    }

    private func networkRate(
        _ label: LocalizedStringKey, symbol: String, value: Double?, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol).font(.system(size: 10)).foregroundStyle(color)
            Text(rate(value)).font(.system(size: 17, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(Pal.textBright)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkRateLine(
        _ label: LocalizedStringKey, symbol: String, value: Double?, color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: symbol).font(.system(size: 11)).foregroundStyle(color)
            Spacer(minLength: 4)
            Text(rate(value)).font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit().foregroundStyle(Pal.textBright)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func processSection(_ m: HostMetrics, memory: Bool) -> some View {
        let processes = Array(m.processes.sorted {
            let lhs = memory ? Double($0.memoryKB) : ($0.cpuPercent ?? -1)
            let rhs = memory ? Double($1.memoryKB) : ($1.cpuPercent ?? -1)
            return lhs == rhs ? $0.pid < $1.pid : lhs > rhs
        }.prefix(12))
        return card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("list.bullet", "进程占用", detail: String(localized: "前 12 项"))
                detailText(memory ? String(localized: "按实际驻留内存排序")
                           : String(localized: "按实时 CPU 排序 · 单核为 100%"))
                if processes.isEmpty {
                    detailText(m.processesAvailable ? String(localized: "暂无可见进程")
                               : String(localized: "当前用户无法读取进程指标"))
                }
                ForEach(processes) { process in
                    processRow(name: process.name, pid: process.pid,
                               value: memory ? human(process.memoryKB)
                                   : process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                               detail: memory && m.memTotalKB > 0
                                   ? String(format: "%.1f%%", Double(process.memoryKB) / Double(m.memTotalKB) * 100) : nil,
                               color: memory ? Pal.mauve : Pal.green)
                }
            }
        }
    }

    private func gpuProcessSection(_ m: HostMetrics) -> some View {
        let processes = m.gpuProcesses.sorted {
            ($0.memoryMB ?? -1) == ($1.memoryMB ?? -1) ? $0.id < $1.id : ($0.memoryMB ?? -1) > ($1.memoryMB ?? -1)
        }
        return card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("list.bullet", "GPU 计算进程")
                if processes.isEmpty {
                    detailText(m.gpuProcessesAvailable ? String(localized: "未发现 GPU 计算进程")
                               : String(localized: "当前驱动未提供进程显存数据"))
                } else {
                    detailText(String(localized: "按显存占用排序，显示各 GPU 上的计算进程。"))
                    ForEach(processes) { process in
                        let gpu = m.gpus.first { $0.uuid == process.gpuUUID }
                        processRow(name: process.name, pid: process.pid,
                                   value: process.memoryMB.map { human($0 * 1024) } ?? "—",
                                   detail: gpu.map { "GPU \($0.index)" } ?? String(localized: "GPU 设备"),
                                   color: Pal.yellow)
                    }
                }
            }
        }
    }

    private func networkProcessSection(_ m: HostMetrics) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                cardTitle("list.bullet", "进程网络连接")
                detailText(String(localized: "仅显示当前用户可见的 TCP / UDP 连接；连接数不代表流量。"))
                if m.networkProcesses.isEmpty {
                    detailText(m.networkProcessesAvailable ? String(localized: "没有可见的进程连接")
                               : String(localized: "远端未提供进程连接信息"))
                }
                ForEach(m.networkProcesses.prefix(12)) { process in
                    processRow(name: process.name, pid: process.pid,
                               value: String(localized: "\(process.connections) 个连接"), detail: nil, color: Pal.green)
                }
            }
        }
    }

    private func processRow(name: String, pid: Int, value: String, detail: String?, color: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(1).truncationMode(.middle).help(name)
                Text("PID \(String(pid))").font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(color).monospacedDigit()
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(Pal.subtext).lineLimit(1)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func cardTitle(_ icon: String, _ title: LocalizedStringKey, detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(
                Pal.subtext)
            Spacer(minLength: 4)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
        }
    }

    private func ring(_ value: Double?, color: Color, size: CGFloat) -> some View {
        let tint = (value ?? 0) >= 90 ? Pal.red : color
        return ZStack {
            Circle().stroke(Pal.fill(0.09), lineWidth: size > 70 ? 7 : 5)
            if let value {
                Circle().trim(from: 0, to: min(100, max(0, value)) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: size > 70 ? 7 : 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: size * 0.29, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(Pal.textBright)
                if value != nil {
                    Text("%").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
            }
        }
        .frame(width: size, height: size).padding(4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { String(localized: "使用率 \(Int($0))%") } ?? String(localized: "暂无数据"))
    }

    private func meter(_ value: Double?, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Pal.fill(0.09))
                Capsule().fill((value ?? 0) >= 90 ? Pal.red : color)
                    .frame(width: geo.size.width * CGFloat(min(100, max(0, value ?? 0))) / 100)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func detailText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).monospacedDigit().foregroundStyle(Pal.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.border, lineWidth: 1))
    }

    private func human(_ kb: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .decimal
        return f.string(fromByteCount: kb * 1024)
    }

    private func rate(_ bps: Double?) -> String {
        guard let bps, bps.isFinite else { return "—" }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var value = max(0, bps)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return value.formatted(.number.precision(.fractionLength(0...1))) + " " + units[unit]
    }

    private func uptimeText(_ secs: Double) -> String {
        let s = Int(max(0, secs))
        let days = s / 86400, hours = (s % 86400) / 3600, minutes = (s % 3600) / 60
        if days > 0 { return String(localized: "已运行 \(days) 天 \(hours) 小时") }
        return String(localized: "已运行 \(hours) 小时 \(minutes) 分钟")
    }
}

/// 按实际收到的样本绘图，不用首值补满历史；采样更新才重绘，不持续刷新静止曲线。
private struct NetSparkline: View {
    let samples: [NetSample]
    let down: Color
    let up: Color

    var body: some View {
        let visible = Array(samples.suffix(40))
        let ceiling = max(1, visible.flatMap { [$0.rx, $0.tx] }.max() ?? 1)
        ZStack {
            VStack {
                Rectangle().fill(Pal.border).frame(height: 1)
                Spacer()
                Rectangle().fill(Pal.border).frame(height: 1)
                Spacer()
                Rectangle().fill(Pal.border).frame(height: 1)
            }
            if visible.count > 1 {
                NetCurve(values: visible.map { $0.rx / ceiling }).stroke(down, lineWidth: 1.5)
                NetCurve(values: visible.map { $0.tx / ceiling }).stroke(up, lineWidth: 1.5)
            } else {
                Text("等待网络采样…").font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
        }
        .clipped()
    }
}

private struct NetCurve: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: rect.width * CGFloat(index) / CGFloat(values.count - 1),
                y: rect.height * (1 - CGFloat(min(1, max(0, value)))))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
