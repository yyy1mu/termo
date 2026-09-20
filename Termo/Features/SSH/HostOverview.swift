import SwiftUI

struct HostOverview: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("主机工作台")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(Pal.mauve)
                        HStack(spacing: 12) {
                            Text(liveHost.name)
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundStyle(Pal.textBright)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            statusBadge
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "network")
                            Text("\(liveHost.ipOrHost):\(liveHost.ssh?.port ?? 22)")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .privacyBlur(model.privacyMode)
                            if liveHost.status == .online, let ms = liveHost.latencyMs {
                                Text("·")
                                Text("\(ms) ms").foregroundStyle(LatencyLevel(ms: ms).color)
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Pal.subtext)
                    }
                    Spacer(minLength: 0)
                    overviewLogo
                }
                .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading("快速操作", detail: "连接、传输与维护")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                        actionTile("terminal", "终端", detail: "打开交互会话", primary: true) {
                            model.openHostTerminal(liveHost)
                        }
                        .contextMenu { Button("新建终端") { model.openHostTerminal(liveHost, forceNew: true) } }
                        actionTile("folder", "文件", detail: "浏览 SFTP",
                                   loading: model.openingFilesHostId == host.id) {
                            model.openHostFiles(liveHost)
                        }
                        actionTile("arrow.left.arrow.right", "端口转发", detail: "管理隧道",
                                   badge: model.hasRunningForward(hostId: host.id)) {
                            model.openForwardPanel(liveHost)
                        }
                        actionTile("square.and.pencil", "编辑", detail: "修改连接配置") {
                            model.beginEditHost(liveHost)
                        }
                    }
                }

                if let s = liveHost.specs, !s.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeading("设备信息", detail: "从远端主机读取")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                            if !s.os.isEmpty { specCell("desktopcomputer", String(localized: "系统"), s.os) }
                            if !s.cores.isEmpty { specCell("cpu", String(localized: "核心"), "\(s.cores) 核") }
                            if !s.memory.isEmpty { specCell("memorychip", String(localized: "内存"), s.memory) }
                            if !s.disk.isEmpty { specCell("internaldrive", String(localized: "磁盘"), s.disk) }
                            if !s.vram.isEmpty { specCell("bolt", String(localized: "显存"), s.vram) }
                            if !s.gpu.isEmpty { specCell("display", String(localized: "显卡"), s.gpu) }
                        }
                    }
                } else if model.probingHosts.contains(liveHost.id) {
                    infoCard {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在获取系统信息…").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                        }
                    }
                }

                if !liveHost.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeading("主机备注", detail: nil)
                        infoCard {
                            Text(liveHost.notes)
                                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if liveHost.ssh != nil {
                    if needsAuth {
                        monitorAuthPlaceholder
                    } else {
                        MonitorPanel(monitor: model.hostMonitor(for: liveHost))
                    }
                }
            }
            .padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 监控只在概览可见时跑：切到此 tab 开始采集，切走（视图移出）几秒后自动停流，保持轻量。
        .onAppear {
            model.probeHostIfNeeded(liveHost)
            model.overviewAppeared(liveHost)
        }
        // 「每次询问」主机：取得本会话密码后（needsAuth 由 true→false），开始采集。
        .onChange(of: needsAuth) { stillNeeds in
            if !stillNeeds {
                model.probeHostIfNeeded(liveHost)
                model.overviewAppeared(liveHost)
            }
        }
        .onDisappear { model.overviewDisappeared(host.id) }
    }

    /// 概览头部大号发行版 Logo（46pt，品牌色底 + 白字形；未识别回退服务器符号）。
    private var overviewLogo: some View {
        let osStr = liveHost.specs?.os ?? liveHost.os
        return ZStack {
            if let name = OSLogo.fontName, let logo = OSLogo.info(for: osStr) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(logo.color)
                    .overlay(Text(logo.glyph).font(.custom(name, size: 26)).foregroundStyle(.white))
            } else {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Pal.mauve.opacity(0.14))
                    .overlay(Image(systemName: "server.rack")
                        .font(.system(size: 22)).foregroundStyle(Pal.mauve))
            }
        }
        .frame(width: 58, height: 58)
    }

    private func sectionHeading(_ title: LocalizedStringKey, detail: LocalizedStringKey?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Pal.textBright)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Pal.overlay)
            }
            Spacer(minLength: 0)
        }
    }

    /// 信息卡片容器：统一卡片底/描边/圆角/内边距（设计系统基准件）。
    private func infoCard(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.border, lineWidth: 1))
    }

    /// 系统规格单元格：小图标 + 标签 + 值。
    private func specCell(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13)).foregroundStyle(Pal.mauve)
                .frame(width: 32, height: 32)
                .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(.system(size: 11)).foregroundStyle(Pal.overlay)
                Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.border, lineWidth: 1))
    }

    /// 实时主机：host 是 Workspace 传入的快照，输密码等变化要从 model 取最新值（HostOverview 已 @ObservedObject model）。
    private var liveHost: Host { model.host(host.id) ?? host }

    /// 「每次询问」且本会话尚未输入密码：监控无法采集，显示占位而非无限「正在建立监控…」。
    private var needsAuth: Bool {
        liveHost.ssh?.authMethod == .ask && (liveHost.ssh?.password ?? "").isEmpty
    }

    private var monitorAuthPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("监控").font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Circle().fill(Pal.overlay).frame(width: 6, height: 6)
            }
            HStack(spacing: 12) {
                Image(systemName: "lock.circle").font(.system(size: 24)).foregroundStyle(Pal.overlay)
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接后开始监控").font(.system(size: 13)).foregroundStyle(Pal.subtext)
                    Text("该主机为「每次询问」，输入密码连接成功后，将在本次运行内采集监控数据。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { model.verifyConnect(host) } label: {
                    Text("连接").font(.system(size: 12)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var statusBadge: some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch liveHost.status {
            case .online: return (String(localized: "在线"), Pal.green, Pal.green.opacity(0.15))
            case .offline: return (String(localized: "离线"), Pal.overlay, Pal.overlay.opacity(0.15))
            case .unknown: return (String(localized: "未知"), Pal.yellow, Pal.yellow.opacity(0.15))
            }
        }()
        return Text(label).font(.system(size: 11)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
    }


    /// 操作区采用同等大小的入口，终端是明确的主操作，其他功能保持可扫描。
    private func actionTile(_ symbol: String, _ label: LocalizedStringKey, detail: LocalizedStringKey,
                            primary: Bool = false, loading: Bool = false, badge: Bool = false,
                            _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 17, weight: .medium))
                    }
                    Spacer()
                    if badge {
                        Circle().fill(Pal.green).frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(0.65)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).opacity(0.78)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(primary ? Color.white : Pal.text)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 94)
            .background(
                primary ? Pal.mauve : Pal.card,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(primary ? Color.clear : Pal.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loading)
        .pointerCursor()
    }


}
