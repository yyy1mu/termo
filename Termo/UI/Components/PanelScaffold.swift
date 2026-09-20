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

private struct FitToHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 高度自适应容器：量出内容自然高度，超过可用高度时整体等比缩小（scaleEffect），
/// 保证一页展示、**永不滚动**（用户要求：监控面板任何机器都必须一页）。
/// 布局始终在容器宽度下进行（换行/网格按真实宽度计算），缩放只做视觉变换、不触发重排，
/// 故无测量-缩放反馈环；放不下时右侧留少量空白（内容左上对齐）。
struct FitToHeight<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let scale = naturalHeight > 0 ? min(1, geo.size.height / naturalHeight) : 1
            content()
                .fixedSize(horizontal: false, vertical: true)   // 按容器宽度量自然高度
                .background(
                    GeometryReader { inner in
                        Color.clear.preference(key: FitToHeightKey.self, value: inner.size.height)
                    }
                )
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .onPreferenceChange(FitToHeightKey.self) { naturalHeight = $0 }
    }
}
