import MarkdownUI
import SwiftUI

/// A full Markdown document preserves nested lists/quotes across code fences.
/// Equality isolates settled replies from input edits and other messages' streaming updates.
struct AIMessageMarkdown: View, Equatable {
    let text: String
    var approvalCommand: String? = nil
    @ObservedObject private var theme = ThemeManager.shared

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.approvalCommand == rhs.approvalCommand
    }

    var body: some View {
        Markdown(text)
            .markdownBlockStyle(\.codeBlock) { configuration in
                if !Self.isApprovalCode(configuration.content, language: configuration.language,
                                        command: approvalCommand) {
                    codeBlock(configuration)
                }
            }
            .markdownTheme(Self.messageTheme)
            .markdownImageProvider(MessageImageProvider())
            .markdownInlineImageProvider(MessageInlineImageProvider())
            .environment(\.openURL, OpenURLAction { url in
                Self.canOpenLink(url) ? .systemAction : .discarded
            })
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func isApprovalCode(_ content: String, language: String?, command: String?) -> Bool {
        guard let command, let language,
              ["bash", "sh", "shell", "zsh"].contains(language.lowercased()) else { return false }
        return AICommandProposal(content).command == command
    }

    static func canOpenLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "mailto": return !url.path.isEmpty
        default: return false
        }
    }

    private func codeBlock(_ configuration: CodeBlockConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(configuration.language?.uppercased() ?? String(localized: "代码"))
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Pal.overlay)
                    .lineLimit(1)
                Spacer(minLength: 4)
                AICopyButton(text: configuration.content).disabled(configuration.content.isEmpty)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider().overlay(Pal.border)
            ScrollView(.horizontal) {
                Text(configuration.content.trimmingCharacters(in: .newlines))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Pal.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(9)
            }
            .scrollIndicators(.automatic)
        }
        .background(Pal.crust, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Pal.border))
        .markdownMargin(top: 4, bottom: 8)
    }

    private static var messageTheme: MarkdownUI.Theme {
        MarkdownUI.Theme()
            .text { FontSize(12); ForegroundColor(Pal.text) }
            .strong { FontWeight(.semibold) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(11)
                ForegroundColor(Pal.mauve)
                BackgroundColor(Pal.fill(0.08))
            }
            .link { ForegroundColor(Pal.mauve) }
            .heading1 { heading($0, size: 18) }
            .heading2 { heading($0, size: 16) }
            .heading3 { heading($0, size: 14) }
            .heading4 { heading($0, size: 13) }
            .heading5 { heading($0, size: 12) }
            .heading6 { heading($0, size: 12) }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.22))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label.markdownMargin(top: 2, bottom: 2)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle { ForegroundColor(Pal.subtext) }
                    .padding(.leading, 11).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(Pal.mauve.opacity(0.5)).frame(width: 3)
                    }
                    .markdownMargin(top: 4, bottom: 8)
            }
            .taskListMarker { configuration in
                Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isCompleted ? Pal.green : Pal.overlay)
                    .font(.system(size: 11))
            }
            .table { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTableBorderStyle(.init(color: Pal.border))
                        .markdownTableBackgroundStyle(.alternatingRows(Pal.fill(0.02), Pal.fill(0.06)))
                }
                .scrollIndicators(.automatic)
                .markdownMargin(top: 4, bottom: 8)
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontSize(11)
                        if configuration.row == 0 { FontWeight(.semibold) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 6)
            }
            .thematicBreak {
                Divider().overlay(Pal.border).markdownMargin(top: 8, bottom: 8)
            }
    }

    private static func heading(_ configuration: BlockConfiguration, size: CGFloat) -> some View {
        configuration.label
            .markdownTextStyle { FontSize(size); FontWeight(.semibold); ForegroundColor(Pal.textBright) }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 12, bottom: 6)
    }
}

/// Model-generated remote URLs are opened only after a click, never fetched while rendering a reply.
private struct MessageImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            Link(destination: url) {
                Label("查看图片 · \(url.host ?? "")", systemImage: "photo")
                    .font(.system(size: 11)).foregroundStyle(Pal.mauve)
                    .padding(8).background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .help(url.absoluteString)
        } else {
            Label("图片链接不可用", systemImage: "photo")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
        }
    }
}

private struct MessageInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        Image(systemName: "photo")
    }
}
