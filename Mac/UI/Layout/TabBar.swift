import SwiftUI

/// 顶栏只显示当前工作区，会话导航统一放在左栏。
struct WorkbenchHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tabs: TabsModel
    @ObservedObject var layout: LayoutModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Color.clear.frame(width: 72)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 25, height: 25)
                    .background(Pal.mauve.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
                Text("TERMO")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(Pal.textBright)
                Spacer(minLength: 0)
                headerButton("sidebar.left", help: String(localized: "切换侧栏", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) {
                    layout.sidebarWidth = layout.sidebarWidth < 10 ? 252 : 0
                }
            }
            .padding(.trailing, 8)
            .frame(width: max(layout.sidebarWidth, 220))

            Rectangle().fill(Pal.border).frame(width: 1, height: 24)
            if let active = tabs.tabs.first(where: { $0.id == tabs.activeTabId }) {
                Label(active.title, systemImage: active.kind == .terminal ? "terminal" : active.kind == .files ? "folder" : "server.rack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Pal.subtext)
                    .lineLimit(1).truncationMode(.middle)
                    .privacyBlur(model.privacyMode && active.hostId != nil)
                    .padding(.horizontal, 16)
            }
            Spacer(minLength: 12)

            HStack(spacing: 3) {
                if let active = tabs.tabs.first(where: { $0.id == tabs.activeTabId }),
                   let host = model.host(active.hostId) {
                    Button { model.beginEditHost(host) } label: {
                        Label("主机设置", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Pal.text)
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain).pointerCursor()
                    .help("编辑当前主机")
                }
                headerButton("plus", help: String(localized: "添加主机", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { model.showAddHost = true }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 52)
        .background(Pal.crust)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Pal.subtext)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}
