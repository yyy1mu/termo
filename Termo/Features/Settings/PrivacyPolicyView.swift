import AppKit
import SwiftUI

/// 应用内隐私说明。与当前实现保持一致：本地保存、可选 WebDAV 加密备份和 AI 服务。
struct PrivacyPolicyView: View {
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private var isEnglish: Bool {
        locale.identifier.hasPrefix("en")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Pal.fill(0.06))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(effectiveDate)
                        .font(.system(size: 11))
                        .foregroundStyle(Pal.overlay)
                    ForEach(sections.indices, id: \.self) { i in
                        section(sections[i].0, sections[i].1)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 620)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack {
            Text(isEnglish ? "Privacy Policy" : "隐私政策")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Pal.text)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.overlay)
                    .frame(width: 24, height: 24)
                    .background(Pal.fill(0.05), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Pal.text)
            Text(body)
                .font(.system(size: 12))
                .foregroundStyle(Pal.subtext)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectiveDate: String {
        isEnglish ? "Updated: September 23, 2026" : "更新日期：2026 年 9 月 23 日"
    }

    private var sections: [(String, String)] {
        isEnglish ? Self.english : Self.chinese
    }

    private static let chinese: [(String, String)] = [
        ("概述",
         "Termo 不要求开发者账号，也未内置分析、广告或行为追踪。以下说明区分保存在本机的数据，以及你启用外部连接后主动发送的数据。"),
        ("本机数据",
         "主机资料、会话、片段和设置保存在 Mac 本地；已保存的 SSH 密码、私钥及服务登录凭证由系统钥匙串管理。应用锁限制界面访问，并不加密所有本地配置文件。"),
        ("远程连接",
         "你发起 SSH、SFTP 或端口转发时，Termo 会连接你指定的主机。连接信息和执行内容会传给该主机；Termo 不通过开发者服务器转发这些连接。"),
        ("WebDAV 同步与备份",
         "只有你使用同步或上传时，Termo 才会把备份发送到你配置的 WebDAV 服务。备份可包含主机资料、已保存的 SSH 密码、私钥、片段、转发规则和部分设置；上传前使用应用主密码加密。WebDAV 服务商仍可看到连接请求与加密后的文件。"),
        ("AI 助手",
         "启用 AI 并发送消息时，问题、对话内容以及你允许附带的主机和终端上下文会发送到你配置的模型服务地址。Agent 模式的命令结果也可作为后续消息发送。服务商如何处理这些内容取决于其政策，请核对服务地址和上下文开关。"),
        ("联系我们",
         "如对隐私有疑问，可在项目仓库提交 issue：github.com/icloudza/termo"),
    ]

    private static let english: [(String, String)] = [
        ("Overview",
         "Termo does not require a developer account and has no built-in analytics, ads, or behavior tracking. This notice distinguishes data stored on your Mac from data you choose to send through external connections."),
        ("On your Mac",
         "Host details, sessions, snippets, and settings are stored locally. Saved SSH passwords, private keys, and service credentials are managed by the system Keychain. The app lock restricts access to the interface; it does not encrypt every local configuration file."),
        ("Remote connections",
         "When you start SSH, SFTP, or port forwarding, Termo connects to the host you specify. Connection details and commands are sent to that host. Termo does not route these connections through a developer server."),
        ("WebDAV sync and backups",
         "When you use sync or upload, Termo sends a backup to your configured WebDAV service. It may contain host details, saved SSH passwords, private keys, snippets, forwarding rules, and some settings. The backup is encrypted with your app master password before upload. The WebDAV provider can still see connection requests and the encrypted file."),
        ("AI assistant",
         "When you enable AI and send a message, your prompt, conversation, and any host or terminal context you allow are sent to the model service you configure. Agent mode may also send command results in follow-up messages. Check that provider's data policy, service address, and the context switch."),
        ("Contact",
         "For privacy questions, open an issue in the project repository: github.com/icloudza/termo"),
    ]
}
