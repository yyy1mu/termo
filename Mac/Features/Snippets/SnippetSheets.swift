import SwiftUI

/// 新建 / 编辑代码片段弹窗。editing 非 nil 为编辑模式（底部多出删除）。
struct SnippetEditView: View {
    @ObservedObject var model: AppModel
    var editing: Snippet? = nil
    @ObservedObject private var theme = ThemeManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var content = ""
    @State private var group = ""
    @State private var didLoad = false
    @State private var confirmDelete = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? String(localized: "新建片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "编辑片段", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.overlay)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().help("关闭片段编辑").accessibilityLabel("关闭片段编辑")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(Pal.fill(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("名称") { ThemedTextField(placeholder: "例如：查看磁盘占用", text: $name) }
                    labeled("命令正文") {
                        VStack(alignment: .leading, spacing: 6) {
                            ThemedTextEditor(placeholder: "df -h\n支持多行；用 {{变量}} 占位，运行时填值", text: $content, height: 180)
                            Text("用 {{变量名}} 写占位符，运行时会先弹出填值框。")
                                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                    }
                    labeled("分组") {
                        VStack(alignment: .leading, spacing: 6) {
                            SearchableSelect(options: model.snippetGroupNames, text: $group,
                                             placeholder: String(localized: "搜索或新建分组…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                            Text("在片段库中按分组归类，留空时放入「未分组」。")
                                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        }
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Pal.fill(0.06))
            HStack {
                if editing != nil {
                    Button { confirmDelete = true } label: {
                        Text("删除").font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.red)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Pal.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }
                Spacer()
                SecondaryButton(title: "取消") { dismiss() }
                PrimaryButton(title: editing == nil ? "创建" : "保存", enabled: canSave) { save() }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 520, height: 580)
        .background(Pal.solidBase)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear(perform: loadOnce)
        .alert("删除片段？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                if let editing { model.deleteSnippet(editing) }
                dismiss()
            }
        } message: { Text("此片段将从片段库移除。") }
    }

    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true
        if let ed = editing {
            name = ed.name
            content = ed.content
            group = ed.group
        }
    }

    private func save() {
        let nm = name.trimmingCharacters(in: .whitespaces)
        let grp = group.trimmingCharacters(in: .whitespaces)
        if let ed = editing {
            model.updateSnippet(ed.id, name: nm, content: content, group: grp)
        } else {
            model.addSnippet(name: nm, content: content, group: grp)
        }
        dismiss()
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            content()
        }
    }
}
