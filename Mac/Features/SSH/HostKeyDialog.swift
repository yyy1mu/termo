import AppKit
import SwiftUI

/// 首次连接与主机密钥变化时，核对目标和指纹后再选择信任范围。
struct HostKeyDialog: View {
    let pending: PendingHostKey
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showsMD5 = false
    @State private var copiedFingerprint: String?
    @State private var copyResetTask: Task<Void, Never>?

    private var info: HostKeyInfo { pending.info }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider().overlay(Pal.border)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if info.changed {
                                Label {
                                    Text("此前记录的主机密钥与当前不一致。若你未重装服务器或更换密钥，请取消连接并核实，可能存在中间人攻击。")
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "exclamationmark.shield")
                                }
                                .font(.system(size: 12)).foregroundStyle(Pal.red)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Pal.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("连接目标").fontWeight(.medium)
                                    Spacer()
                                    Text("端口 \(String(info.port))").monospacedDigit()
                                }
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                Text(info.host)
                                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Pal.textBright)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            fingerprint("SHA256", value: info.sha256)
                            Text("请与服务器管理面板或管理员提供的指纹核对。保存信任后，下次连接将核对这条记录。")
                                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                            if !info.md5.isEmpty {
                                Button {
                                    showsMD5.toggle()
                                } label: {
                                    HStack {
                                        Text("其他指纹（MD5）")
                                        Spacer()
                                        Image(systemName: showsMD5 ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                                    .padding(.vertical, 5).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).pointerCursor()
                                if showsMD5 { fingerprint("MD5", value: info.md5) }
                            }
                        }
                        .padding(20)
                    }
                    Divider().overlay(Pal.border)
                    VStack(alignment: .leading, spacing: 12) {
                        Button("仅本次继续，不保存信任") { pending.respond(.once) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Pal.mauve)
                            .pointerCursor()
                        HStack(spacing: 10) {
                            Button { pending.respond(.cancel) } label: {
                                Text("取消连接").font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Pal.text)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).keyboardShortcut(.cancelAction).pointerCursor()
                            Spacer(minLength: 0)
                            Button { pending.respond(.save) } label: {
                                Text("信任并保存").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(height: 34)
                                    .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).pointerCursor()
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                }
                .frame(width: max(0, min(560, geometry.size.width - 32)),
                       height: max(0, min(info.changed ? 530 : (showsMD5 ? 500 : 410), geometry.size.height - 32)))
                .background(Pal.solidMantle, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.border, lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.15), radius: 24, y: 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onChange(of: pending.id) {
            showsMD5 = false
            copiedFingerprint = nil
            copyResetTask?.cancel()
        }
        .onDisappear { copyResetTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.changed ? "exclamationmark.shield.fill" : "shield")
                .font(.system(size: 20)).foregroundStyle(info.changed ? Pal.red : Pal.mauve)
                .frame(width: 38, height: 38)
                .background((info.changed ? Pal.red : Pal.mauve).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(info.changed ? "主机密钥已变更" : "核对主机指纹")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.textBright)
                Text(info.changed ? "请重新确认服务器身份" : "首次连接，需要确认服务器身份")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    private func fingerprint(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Pal.subtext)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(value, forType: .string) else { return }
                    copiedFingerprint = title
                    copyResetTask?.cancel()
                    copyResetTask = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                        guard !Task.isCancelled else { return }
                        copiedFingerprint = nil
                    }
                } label: {
                    Label(copiedFingerprint == title ? "已复制" : "复制", systemImage: copiedFingerprint == title ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().disabled(value.isEmpty)
                .accessibilityLabel(String(localized: "复制 \(title) 指纹"))
            }
            Text(value.isEmpty ? String(localized: "暂无指纹信息") : value)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Pal.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}
