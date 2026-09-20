import SwiftUI

/// 伴随面板统一骨架与空态组件——从代码层面杜绝各面板重复造头部/空态的同类 bug
/// （双头部×2、占位样式漂移）。约定：
/// 1. 标题/主机/关闭键一律由框架头部（CompanionPanel.header）承载，面板**不再自带标题**
/// 2. 面板根布局 = PanelScaffold：可选顶部动作条 + 内容
/// 3. 空态/无主机/未配置 = PanelEmptyState
struct PanelScaffold<Toolbar: View, Content: View>: View {
    @ViewBuilder var toolbar: Toolbar
    @ViewBuilder var content: Content

    init(@ViewBuilder toolbar: () -> Toolbar, @ViewBuilder content: () -> Content) {
        self.toolbar = toolbar()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PanelScaffold where Toolbar == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(toolbar: { EmptyView() }, content: content)
    }
}

/// 统一空态：图标 + 标题 + 说明（可选）+ 动作按钮（可选）。
struct PanelEmptyState: View {
    let symbol: String
    let title: String
    var detail: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var symbolColor: Color = Pal.overlay

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 26)).foregroundStyle(symbolColor)
            Text(title)
                .font(.system(size: 13)).foregroundStyle(Pal.subtext)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.mauve)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}
