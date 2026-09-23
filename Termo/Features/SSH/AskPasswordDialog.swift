import SwiftUI

/// 连接前补充密码。只有明确选择保存才改变主机认证方式并写入钥匙串。
struct AskPasswordDialog: View {
    let host: Host
    var errorText: String? = nil
    let onConfirm: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    private var target: String {
        guard let s = host.ssh else { return host.name }
        let address = s.host.contains(":") ? "[\(s.host)]" : s.host
        return "\(s.user)@\(address):\(s.port)"
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18)).foregroundStyle(Pal.mauve)
                            .frame(width: 38, height: 38)
                            .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("登录主机").font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                            Text("输入服务器的 SSH 登录密码")
                                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                        }
                        Spacer()
                    }
                    .padding(20)
                    Divider().overlay(Pal.border)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(host.name).font(.system(size: 14, weight: .medium)).foregroundStyle(Pal.text)
                                    Text(target).font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.subtext)
                                        .textSelection(.enabled)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 8))
                                ThemedSecureField(placeholder: "SSH 登录密码", text: $password)
                                    .accessibilityLabel("SSH 登录密码")
                                    .onSubmit { if !password.isEmpty { onConfirm(password, remember) } }
                                VStack(alignment: .leading, spacing: 7) {
                                    Toggle("保存密码，下次自动登录", isOn: $remember)
                                        .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Pal.text)
                                    Text(remember ? "保存在系统钥匙串，并随 WebDAV 加密备份同步。" : "仅本次会话使用，不写入钥匙串或同步备份。")
                                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let errorText {
                                    Label { Text(errorText).textSelection(.enabled) } icon: {
                                        Image(systemName: "exclamationmark.circle")
                                    }
                                    .font(.system(size: 12)).foregroundStyle(Pal.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id("password-error")
                                }
                            }
                            .padding(20)
                        }
                        .onChange(of: errorText, initial: true) {
                            if errorText != nil { proxy.scrollTo("password-error", anchor: .bottom) }
                        }
                    }
                    Divider().overlay(Pal.border)
                    HStack(spacing: 10) {
                        Spacer()
                        SecondaryButton(title: "取消", action: onCancel).keyboardShortcut(.cancelAction)
                        PrimaryButton(title: remember ? "保存并连接" : "仅本次连接", enabled: !password.isEmpty) {
                            onConfirm(password, remember)
                        }
                    }
                    .padding(16)
                }
                .frame(width: min(440, max(280, geometry.size.width - 32)), height: min(470, max(260, geometry.size.height - 32)))
                .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear { remember = host.ssh?.authMethod == .password }
    }
}
