import SwiftUI

struct HostOverview: View {
    let host: Host
    @ObservedObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showDetails = false
    @State private var showMasterSetup = false
    @ObservedObject private var lock = AppLockManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                deviceDetails
                if !liveHost.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("主机备注", systemImage: "text.alignleft")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
                        Text(liveHost.notes).font(.system(size: 12)).foregroundStyle(Pal.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showMasterSetup) { AppLockSetupSheet() }
        .onAppear {
            model.probeHostIfNeeded(liveHost)
        }
        .onChange(of: needsAuth) { _, stillNeeds in
            if !stillNeeds {
                model.probeHostIfNeeded(liveHost)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            overviewLogo
            VStack(alignment: .leading, spacing: 7) {
                Text("主机工作台").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.mauve)
                Text(liveHost.name)
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(Pal.textBright)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(connectionLabel)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Pal.subtext)
                    .textSelection(.enabled).privacyBlur(model.privacyMode)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        statusBadge; systemLabel
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        statusBadge; systemLabel
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if lock.hasPin { lock.setEnabled(true); lock.lock() } else { showMasterSetup = true }
            } label: {
                Image(systemName: "lock").font(.system(size: 14))
                    .foregroundStyle(Pal.subtext).frame(width: 32, height: 32)
                    .background(Pal.card, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).pointerCursor()
            .help(String(localized: "锁定工作台 · 主密码与同步共用"))
            .accessibilityLabel("锁定工作台")
        }
    }

    private var connectionLabel: String {
        let user = liveHost.ssh?.user ?? ""
        let address = liveHost.ipOrHost.contains(":") ? "[\(liveHost.ipOrHost)]" : liveHost.ipOrHost
        return "\(user.isEmpty ? "" : user + "@")\(address):\(liveHost.ssh?.port ?? liveHost.port)"
    }

    private var systemLabel: some View {
        let detectedOS = liveHost.specs?.os ?? ""
        return Text(detectedOS.isEmpty ? liveHost.os : detectedOS)
            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons }
                .frame(minWidth: 480, maxWidth: 680)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        action("terminal", "打开终端", primary: true) { model.openHostTerminal(liveHost) }
            .contextMenu { Button("新建终端") { model.openHostTerminal(liveHost, forceNew: true) } }
        action("folder", "浏览文件") { model.openCompanionFiles() }
        action("arrow.left.arrow.right", "端口转发", badge: model.hasRunningForward(hostId: host.id)) {
            model.openForwardPanel(liveHost)
        }
        action("slider.horizontal.3", "编辑主机") { model.beginEditHost(liveHost) }
    }

    private func action(
        _ icon: String, _ title: LocalizedStringKey, primary: Bool = false,
        badge: Bool = false, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: .medium))
                if badge { Circle().fill(Pal.green).frame(width: 5, height: 5) }
            }
            .foregroundStyle(primary ? Color.white : Pal.text)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(primary ? Pal.mauve : Pal.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : Pal.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    @ViewBuilder
    private var deviceDetails: some View {
        if let specs = liveHost.specs, !specs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(Pal.border).frame(height: 1)
                DisclosureGroup(isExpanded: $showDetails) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210), spacing: 16)],
                        alignment: .leading, spacing: 12
                    ) {
                        if !specs.os.isEmpty { specPair("系统", specs.os) }
                        if !specs.cores.isEmpty { specPair("处理器", String(localized: "\(specs.cores) 核")) }
                        if !specs.memory.isEmpty { specPair("总内存", specs.memory) }
                        if !specs.disk.isEmpty { specPair("磁盘快照", specs.disk) }
                        if !specs.gpu.isEmpty { specPair("显卡", specs.gpu) }
                        if !specs.vram.isEmpty { specPair("显存", specs.vram) }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("设备详情").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.subtext)
                }
                .tint(Pal.overlay)
            }
        } else if model.probingHosts.contains(liveHost.id) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在获取设备信息…").font(.system(size: 11)).foregroundStyle(Pal.subtext)
            }
        }
    }

    private func specPair(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(Pal.overlay)
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overviewLogo: some View {
        let os = liveHost.specs?.os ?? liveHost.os
        return ZStack {
            if let font = OSLogo.fontName, let logo = OSLogo.info(for: os) {
                RoundedRectangle(cornerRadius: 12).fill(logo.color)
                    .overlay(Text(logo.glyph).font(.custom(font, size: 24)).foregroundStyle(.white))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Pal.mauve.opacity(0.12))
                    .overlay(
                        Image(systemName: "server.rack").font(.system(size: 22)).foregroundStyle(Pal.mauve))
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var liveHost: Host { model.host(host.id) ?? host }
    private var needsAuth: Bool { liveHost.ssh?.authMethod == .ask && (liveHost.ssh?.password ?? "").isEmpty }

    private var statusBadge: some View {
        let color: Color =
            liveHost.status == .online ? Pal.green : (liveHost.status == .offline ? Pal.red : Pal.overlay)
        let title: String =
            switch liveHost.status {
            case .online: String(localized: "主机可达")
            case .offline: String(localized: "主机不可达")
            case .unknown: String(localized: "尚未检测")
            }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title)
            if liveHost.status == .online, let ms = liveHost.latencyMs {
                Text("· \(ms) ms").monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(String(localized: "网络连通性检测，不代表 SSH 已认证连接"))
    }
}
