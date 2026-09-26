import AppKit
import SwiftUI

/// 「关于」内容卡片——设置页的「关于」与菜单打开的独立「关于」窗口共用同一份。
struct AboutContent: View {
    @ObservedObject private var theme = ThemeManager.shared
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 28))
                    .foregroundStyle(Pal.mauve)
                    .frame(width: 52, height: 52)
                    .background(Pal.mauve.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Termo").font(.system(size: 18, weight: .semibold)).foregroundStyle(Pal.text)
                    Text(AppInfo.versionLine)
                    Text(String(localized: "构建于 \(AppInfo.buildDate)", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale))
                        .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                }
                Spacer()
            }
            Divider().background(Pal.fill(0.06)).padding(.vertical, 6)
            linkLine("GitHub", "github.com/icloudza/termo", url: "https://github.com/icloudza/termo")
            infoLine(String(localized: "终端引擎", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), value: "SwiftTerm 1.13")
            infoLine(String(localized: "渲染", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), value: "CoreText / AppKit")
            infoLine(String(localized: "平台", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), value: "macOS 27+")
            infoLine(String(localized: "架构", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), value: "Apple Silicon")
            privacyLine
        }
        .padding(20)
        .background(Pal.fill(0.03), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showPrivacy) { PrivacyPolicyView() }
    }

    private var privacyLine: some View {
        Button { showPrivacy = true } label: {
            HStack {
                Text(String(localized: "隐私政策", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)).font(.system(size: 12)).foregroundStyle(Pal.overlay)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Pal.subtext)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func infoLine(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(Pal.subtext)
        }
    }

    @ViewBuilder
    private func linkLine(_ label: String, _ text: String, url: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Pal.overlay)
            Spacer()
            if let u = URL(string: url) {
                Link(text, destination: u)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0x89b4fa))
                    .pointerCursor()
            } else {
                Text(text).font(.system(size: 12)).foregroundStyle(Pal.subtext)
            }
        }
    }
}

/// 独立「关于」窗口的根视图（菜单「关于 termo」打开）。
struct AboutWindow: View {
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        AboutContent()
            .padding(24)
            .frame(width: 460)
            .background(Pal.solidBase)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .environment(\.locale, settings.effectiveLocale)
    }
}
