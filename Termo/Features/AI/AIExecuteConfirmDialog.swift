import SwiftUI

/// AI 命令执行确认弹窗：显示完整命令与目标主机，**批准后才真正执行**。
/// 对齐 [[ConfirmDialog]] 的卡片风格；命令以等宽字体完整展示（可复制核对）。
struct AIExecuteConfirmDialog: View {
    let command: String
    /// nil=本地终端
    let host: Host?
    let onApprove: () -> Void
    let onDecline: () -> Void
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDecline)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(Pal.mauve)
                    Text("AI 请求在当前终端执行").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("批准后把完整命令输入当前终端并回车（多行命令逐行执行，末行自动回车）")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    HStack(spacing: 6) {
                        Image(systemName: host == nil ? "macbook" : "server.rack")
                            .font(.system(size: 10)).foregroundStyle(Pal.mauve)
                        Text(host.map { "\($0.name) · \($0.ipOrHost)" } ?? String(localized: "本地终端"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    }
                    Text(command)
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Pal.crust, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.border, lineWidth: 1))
                }

                Text("AI 生成命令可能有误，请核对后再批准。命令在当前终端可见执行，输出可一键回发给 AI。")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onDecline) {
                        Text("拒绝").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                    Button(action: onApprove) {
                        Text("批准并执行").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Pal.green, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
            }
            .padding(18)
            .frame(width: 440)
            .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Pal.border, lineWidth: 1))
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.2), radius: 24, y: 8)
        }
    }
}
