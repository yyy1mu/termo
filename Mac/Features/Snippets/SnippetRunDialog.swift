import SwiftUI

/// 变量与命令预览可以滚动，发送操作始终留在底部。
struct SnippetRunDialog: View {
    let request: SnippetRunRequest
    var targetTitle: String? = nil
    let onConfirm: ([String: String]) -> Void
    let onCancel: () -> Void
    @State private var values: [String: String] = [:]
    @ObservedObject private var theme = ThemeManager.shared

    private var allFilled: Bool {
        request.variables.allSatisfy { !(values[$0] ?? "").isEmpty }
    }

    private var preview: String {
        Snippet.substitute(request.snippet.content, values: values.filter { !$0.value.isEmpty })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(request.run ? "运行片段" : "插入片段", systemImage: "curlybraces")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                        Text(request.snippet.name).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                            .lineLimit(2)
                        if let targetTitle {
                            Label(targetTitle, systemImage: "terminal")
                                .font(.system(size: 11)).foregroundStyle(Pal.mauve).lineLimit(2)
                        }
                    }
                    .padding(20)
                    Divider().overlay(Pal.border)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(request.variables, id: \.self) { variable in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(variable).font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Pal.text)
                                    ThemedTextField(verbatim: variable, text: Binding(
                                        get: { values[variable] ?? "" }, set: { values[variable] = $0 }
                                    ))
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("命令预览").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                                Text(preview).font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Pal.subtext).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(20)
                    }
                    Divider().overlay(Pal.border)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(request.run ? "确认后立即在终端执行。" : "仅输入到终端，由你回车执行。")
                            .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        HStack(spacing: 10) {
                            Text("\(values.values.filter { !$0.isEmpty }.count) / \(request.variables.count) 已填写")
                                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                            Spacer(minLength: 0)
                            SecondaryButton(title: "取消", action: onCancel)
                            PrimaryButton(title: request.run ? "运行" : "插入", enabled: allFilled) { onConfirm(values) }
                        }
                    }
                    .padding(16)
                }
                .frame(width: min(480, max(0, geometry.size.width - 32)),
                       height: min(580, max(0, geometry.size.height - 32)))
                .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.border, lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
            }
        }
    }
}

/// 先看清命令和目的终端，再选择插入或执行。
struct SnippetActionDialog: View {
    let snippet: Snippet
    var targetTitle: String? = nil
    let onChoose: (_ run: Bool, _ remember: Bool) -> Void
    let onCancel: () -> Void
    @State private var remember = false
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onCancel)
                VStack(alignment: .leading, spacing: 16) {
                    Label("使用片段", systemImage: "terminal")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Pal.text)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snippet.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Pal.text)
                        if let targetTitle {
                            Text("发送到：\(targetTitle)").font(.system(size: 11)).foregroundStyle(Pal.mauve)
                        }
                    }
                    ScrollView {
                        Text(snippet.content).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Pal.subtext).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(height: min(140, max(60, geometry.size.height - 300)))
                    .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text("仅插入：在终端核对后回车。直接运行：立即发送并执行。")
                        .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("记住选择，可在设置中修改", isOn: $remember)
                        .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    HStack(spacing: 10) {
                        SecondaryButton(title: "取消", action: onCancel)
                        Spacer(minLength: 0)
                        SecondaryButton(title: "直接运行") { onChoose(true, remember) }
                        PrimaryButton(title: "仅插入") { onChoose(false, remember) }
                    }
                }
                .padding(20).frame(width: min(480, max(0, geometry.size.width - 32)))
                .background(Pal.solidBase, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Pal.border, lineWidth: 1))
                .shadow(color: .black.opacity(theme.isDark ? 0.4 : 0.16), radius: 20, y: 8)
            }
        }
    }
}
