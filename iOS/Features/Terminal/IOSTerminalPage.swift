import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm 的 UIKit 承载：TerminalView 自带 TerminalAccessory 键盘条（Esc/Tab/Ctrl/方向键）。
private struct IOSTerminalSurface: UIViewRepresentable {
    let viewModel: IOSTerminalViewModel

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero, font: IOSTerminalTheme.font)
        IOSTerminalTheme.apply(to: tv)
        tv.accessibilityIdentifier = "terminalView"
        tv.terminalDelegate = viewModel
        viewModel.attach(tv)
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}
}

/// 单个 SSH 终端页：全屏终端 + 连接中/指纹确认/密码/掉线重连覆盖层。
/// 每个页面一个 IOSTerminalViewModel，导航栈可同时保留多个会话。
struct IOSTerminalPage: View {
    @StateObject private var viewModel: IOSTerminalViewModel
    @State private var passwordInput = ""

    init(host: IOSHost) {
        _viewModel = StateObject(wrappedValue: IOSTerminalViewModel(host: host))
    }

    var body: some View {
        ZStack {
            IOSTheme.base.ignoresSafeArea()
            IOSTerminalSurface(viewModel: viewModel)
            overlay
        }
        .navigationTitle(viewModel.terminalTitle.isEmpty ? viewModel.host.name : viewModel.terminalTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(IOSTheme.base, for: .navigationBar)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.close() }
        .alert(String(localized: "输入密码"), isPresented: passwordPromptBinding) {
            SecureField(String(localized: "密码"), text: $passwordInput)
            Button(String(localized: "连接")) { viewModel.submitPassword(passwordInput) }
            Button(String(localized: "取消"), role: .cancel) { viewModel.cancelPasswordPrompt() }
        } message: {
            Text("\(viewModel.host.ssh.user)@\(viewModel.host.ssh.host)")
        }
        .alert(hostKeyAlertTitle, isPresented: hostKeyPromptBinding) {
            Button(String(localized: "信任并连接")) { viewModel.trustHostKey() }
            Button(String(localized: "取消"), role: .cancel) { viewModel.cancelHostKey() }
        } message: {
            if let info = viewModel.pendingHostKey {
                Text(hostKeyAlertMessage(info))
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch viewModel.phase {
        case .live:
            EmptyView()
        case .connecting:
            overlayCard {
                ProgressView()
                Text(String(localized: "正在连接…"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("terminalConnectingOverlay")
        case .dropped:
            overlayCard {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2).foregroundStyle(.yellow)
                Text(String(localized: "连接已断开"))
                    .font(.subheadline.weight(.semibold))
                Text(viewModel.reconnecting
                     ? String(localized: "正在重连…")
                     : String(localized: "即将自动重连"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(String(localized: "立即重连")) { viewModel.reconnectNow() }
                    .buttonStyle(.borderedProminent).tint(IOSTheme.accent)
            }
            .accessibilityIdentifier("terminalDroppedOverlay")
        case .failed(let message):
            overlayCard {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2).foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "重新连接")) { viewModel.reconnectNow() }
                    .buttonStyle(.borderedProminent).tint(IOSTheme.accent)
            }
            .accessibilityIdentifier("terminalFailedOverlay")
        }
    }

    private func overlayCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(32)
    }

    private var passwordPromptBinding: Binding<Bool> {
        Binding(
            get: { viewModel.showPasswordPrompt },
            set: { if !$0 { viewModel.cancelPasswordPrompt() } })
    }

    private var hostKeyPromptBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingHostKey != nil },
            set: { if !$0 { viewModel.cancelHostKey() } })
    }

    private var hostKeyAlertTitle: String {
        viewModel.pendingHostKey?.changed == true
            ? String(localized: "主机密钥已变更")
            : String(localized: "首次连接该主机")
    }

    private func hostKeyAlertMessage(_ info: IOSHostKeyInfo) -> String {
        let warning = info.changed
            ? String(localized: "该主机的密钥与已保存记录不一致，可能存在中间人攻击风险。")
            : String(localized: "请核对主机指纹：")
        return """
        \(warning)
        \(info.host):\(info.port)
        SHA256: \(info.sha256)
        """
    }
}
