import SwiftUI

/// 设置中的全局同步与备份页面；连接配置与单向覆盖按需展开。
struct SyncPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared
    @State private var showConfiguration = false
    @State private var showAdvanced = false
    @State private var confirmOverwrite = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                overview
                masterSection
                actionsSection
                statusSection
                disclosure(title: "WebDAV 连接", symbol: "externaldrive.connected.to.line.below",
                           expanded: showConfiguration) {
                    showConfiguration.toggle()
                }
                if showConfiguration { webdavSection }
                disclosure(title: "备份与高级操作", symbol: "archivebox",
                           expanded: showAdvanced) {
                    showAdvanced.toggle()
                    if !showAdvanced { confirmOverwrite = false }
                }
                if showAdvanced { advancedSection }
            }
            .padding(16)
        }
        .onAppear {
            if !sync.config.isComplete { showConfiguration = true }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 36, height: 36)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("加密同步")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.textBright)
                    Text(sync.config.isComplete ? "WebDAV 已配置" : "先配置 WebDAV 连接")
                        .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(sync.config.isComplete ? Pal.mauve : Pal.yellow)
                    .frame(width: 7, height: 7)
            }
            Text("在设备间合并主机与设置。远端备份始终使用主密码加密。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            if let last = sync.lastSyncAt {
                Text("上次同步：\(Self.formatter.string(from: last))")
                    .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Pal.border, lineWidth: 1))
    }

    private var masterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("本次使用的主密码")
            ThemedSecureField(placeholder: "主密码（至少 8 位）", text: $sync.masterPassword)
            Text("只保留在本次运行的内存中；所有设备必须使用同一个主密码。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(sync.busy)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                Task { await sync.mergeSync(model: model) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("合并同步").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 11))
                }
                .font(.system(size: 12)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).pointerCursor().disabled(sync.busy)
            Text("双向合并；遇到冲突时由你逐项选择。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
            actionRow("下载并合并到本机", symbol: "arrow.down.to.line",
                      detail: "保留本机独有项，不回传远端") {
                Task { await sync.importFromWebDAV(model: model) }
            }
            Text("合并不会同步删除。某项若只在另一台设备上存在，会重新带回本机。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if sync.busy || !sync.statusText.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if sync.busy {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在处理…").font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    }
                }
                if !sync.statusText.isEmpty {
                    Text(sync.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(sync.statusIsError ? Pal.red : Pal.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var webdavSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            field("服务器地址") {
                ThemedTextField(verbatim: "https://dav.example.com/remote.php/dav/files/me",
                                text: $sync.baseURL)
            }
            field("用户名") { ThemedTextField(placeholder: "用户名", text: $sync.username) }
            field("应用密码") { ThemedSecureField(placeholder: "WebDAV 密码", text: $sync.password) }
            field("远程文件路径") {
                ThemedTextField(verbatim: SyncConfigStore.defaultRemotePath, text: $sync.remotePath)
            }
            Text("建议使用 HTTPS。Seafile 请先创建资料库；密码保存到系统钥匙串。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecondaryButton(title: "测试连接") { Task { await sync.testConnection() } }
                SecondaryButton(title: "保存配置") {
                    sync.saveConfig()
                    sync.statusText = String(localized: "配置已保存")
                    sync.statusIsError = false
                }
            }
            .disabled(sync.busy)
        }
        .padding(12)
        .background(Pal.card, in: RoundedRectangle(cornerRadius: 9))
        .disabled(sync.busy)
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionRow("导出加密备份…", symbol: "square.and.arrow.up", detail: "存入本地文件") {
                sync.exportToFile(model: model)
            }
            actionRow("从文件导入…", symbol: "square.and.arrow.down", detail: "读取本地加密备份") {
                sync.importFromFile(model: model)
            }
            Rectangle().fill(Pal.border).frame(height: 1).padding(.vertical, 4)
            if confirmOverwrite {
                VStack(alignment: .leading, spacing: 9) {
                    Text("这会用本机数据替换远端备份，无法从远端恢复被替换的内容。")
                        .font(.system(size: 11)).foregroundStyle(Pal.text)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecondaryButton(title: "取消") { confirmOverwrite = false }
                        Button("确认覆盖") {
                            confirmOverwrite = false
                            Task { await sync.uploadLocal(model: model) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Pal.red)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(Pal.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Pal.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            } else {
                actionRow("用本机数据覆盖远端", symbol: "exclamationmark.arrow.triangle.2.circlepath",
                          detail: "替换远端备份；不会合并") {
                    confirmOverwrite = true
                }
            }
            Text("语言等设置同步后需重启生效。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(sync.busy)
    }

    private func disclosure(title: LocalizedStringKey, symbol: String, expanded: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 17)
                Text(title).fontWeight(.medium)
                Spacer()
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
            }
            .font(.system(size: 11)).foregroundStyle(Pal.subtext)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func field<Content: View>(_ title: LocalizedStringKey,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(title)
            content()
        }
    }

    private func actionRow(_ title: LocalizedStringKey, symbol: String,
                           detail: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13))
                    .foregroundStyle(Pal.mauve).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                    Text(detail).font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Pal.overlay)
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Pal.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.border, lineWidth: 1))
        }
        .buttonStyle(.plain).pointerCursor().disabled(sync.busy)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.subtext)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}

/// 同步冲突裁决弹窗。覆盖整个设置窗口，避免被页面滚动区域裁切。
struct SyncDialogs: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject private var sync = SyncModel.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let pending = sync.pendingMerge {
                SyncConflictDialog(result: pending.result) { choices in
                    Task { await sync.resolvePending(choices: choices, model: model) }
                } onCancel: {
                    sync.cancelPending()
                }
            }
        }
    }
}

private struct SyncConflictDialog: View {
    let result: SyncMergeResult
    let onConfirm: ([String: Bool]) -> Void
    let onCancel: () -> Void
    @State private var choices: [String: Bool] = [:]
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("解决同步冲突")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Pal.text)
                    Text("以下 \(result.conflicts.count) 项在本机与远端不同，请逐项选择保留哪边。")
                        .font(.system(size: 12))
                        .foregroundStyle(Pal.subtext)
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "全部保留本机") {
                        for conflict in result.conflicts { choices[conflict.id] = true }
                    }
                    SecondaryButton(title: "全部使用远端") {
                        for conflict in result.conflicts { choices[conflict.id] = false }
                    }
                    Spacer()
                }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(result.conflicts) { conflict in
                            row(conflict)
                            if conflict.id != result.conflicts.last?.id {
                                Divider().overlay(Pal.fill(0.06))
                            }
                        }
                    }
                    .background(Pal.fill(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.fill(0.06), lineWidth: 1))
                }
                .frame(maxHeight: 300)

                HStack(spacing: 10) {
                    Spacer()
                    SecondaryButton(title: "取消", action: onCancel)
                    PrimaryButton(title: "应用") { onConfirm(choices) }
                }
            }
            .padding(20)
            .frame(width: 560)
            .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.fill(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        }
    }

    private func row(_ conflict: SyncConflict) -> some View {
        let keepLocal = Binding(
            get: { choices[conflict.id] ?? true },
            set: { choices[conflict.id] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text(conflict.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.text)
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Text("字段")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(width: 64, alignment: .leading)
                    Text("本机")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("远端")
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(conflict.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .top, spacing: 8) {
                        Text(field.label)
                            .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                            .frame(width: 64, alignment: .leading)
                        Text(field.local.isEmpty ? "—" : field.local)
                            .font(.system(size: 11))
                            .foregroundStyle(field.isDifferent ? Pal.yellow : Pal.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2).truncationMode(.middle)
                            .tooltip(field.local)
                        Text(field.remote.isEmpty ? "—" : field.remote)
                            .font(.system(size: 11))
                            .foregroundStyle(field.isDifferent ? Pal.yellow : Pal.subtext)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2).truncationMode(.middle)
                            .tooltip(field.remote)
                    }
                }
            }
            SegmentedControl(
                options: [(value: true, label: "保留本机"), (value: false, label: "使用远端")],
                selection: keepLocal
            )
            .frame(width: 220)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
