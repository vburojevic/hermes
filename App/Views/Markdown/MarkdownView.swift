import HermesKit
import HermesMarkdown
import SwiftUI

/// Renders a Markdown string with Hermes' reading typography.
///
/// Equatable so SwiftUI only re-parses when the text actually changes, which
/// matters while a reply streams in a few characters at a time.
struct MarkdownView: View, Equatable {
    let text: String
    var tone: Tone = .primary

    enum Tone { case primary, secondary }

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownDocument(parsing: text).blocks)
            .foregroundStyle(tone == .primary ? Theme.primaryText : Theme.secondaryText)
            .textSelection(.enabled)
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// Body font for Markdown paragraphs, lists and tables; headings scale independently.
    @Entry var markdownBodyFont: Font = Theme.Typography.message
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    @Environment(\.markdownBodyFont) private var bodyFont
    @Environment(\.references) private var references

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            if let source = Self.standaloneImage(inlines) {
                MarkdownImage(source: source)
            } else {
                let text = InlineRenderer.attributed(inlines, vocabulary: references.vocabulary)
                if text.runs.contains(where: { $0[MessageReferenceAttribute.self] != nil }) {
                    // Bots and files named in the reply are pills (`memberMessageMentions`).
                    InlineFlow(attributed: text, font: bodyFont, size: bodyFont == Theme.Typography.message ? .message : .compact)
                } else {
                    Text(text)
                        .font(bodyFont)
                        .lineSpacing(Theme.Typography.messageLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

        case .heading(let level, let inlines):
            Text(InlineRenderer.attributed(inlines))
                .font(Theme.Typography.heading(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)

        case .blockQuote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(width: 3)
                AnyView(MarkdownBlocksView(blocks: blocks))
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let list):
            MarkdownListView(list: list)

        case .table(let table):
            MarkdownTableView(table: table)

        case .thematicBreak:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)

        case .html(let raw):
            Text(raw)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// A paragraph that is nothing but one image renders the image itself.
    static func standaloneImage(_ inlines: [MarkdownInline]) -> String? {
        let meaningful = inlines.filter {
            switch $0 {
            case .softBreak, .lineBreak: false
            case .text(let text): !text.trimmingCharacters(in: .whitespaces).isEmpty
            default: true
            }
        }
        guard meaningful.count == 1, case .image(let source?, _) = meaningful[0] else { return nil }
        return source
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    @Environment(\.markdownBodyFont) private var bodyFont

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(index: index, item: item)
                    AnyView(MarkdownBlocksView(blocks: item.blocks))
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let checked = item.isChecked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(bodyFont)
                .foregroundStyle(checked ? Theme.primaryText : Theme.tertiaryText)
                .accessibilityLabel(checked ? Text("Done") : Text("Not done"))
        } else if list.isOrdered {
            Text("\(list.startIndex + index).")
                .font(bodyFont.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(minWidth: 18, alignment: .trailing)
        } else {
            Text("•")
                .font(bodyFont.weight(.bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 12)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    @Environment(\.markdownBodyFont) private var bodyFont

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[safe: column] ?? [], column: column)
                            .font(bodyFont.weight(.semibold))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(row[safe: column] ?? [], column: column)
                                .font(bodyFont)
                        }
                    }
                }
            }
            .surface(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func cell(_ inlines: [MarkdownInline], column: Int) -> some View {
        let alignment: Alignment = switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        return Text(InlineRenderer.attributed(inlines))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 60, maxWidth: 320, alignment: alignment)
            .gridColumnAlignment(alignment.horizontal)
    }
}

/// Images embedded in replies: inline `data:` URLs (generated images) or remote URLs. Inline
/// images are decoded and downsampled off the main thread, once, then fade in.
private struct MarkdownImage: View {
    let source: String

    @State private var decoded: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if source.hasPrefix("data:image") {
                if let image = decoded {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else if failed {
                    Label("Image unavailable", systemImage: "photo").foregroundStyle(Theme.tertiaryText)
                } else {
                    Theme.surface.frame(height: 160)
                }
            } else if let url = URL(string: source), url.scheme == "https" || url.scheme == "http" {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.3))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit().transition(.opacity)
                    case .failure: Label("Image unavailable", systemImage: "photo").foregroundStyle(Theme.tertiaryText)
                    default: Theme.surface.frame(height: 160)
                    }
                }
            } else {
                Label("Image", systemImage: "photo").foregroundStyle(Theme.tertiaryText)
            }
        }
        .frame(maxWidth: 480, maxHeight: 480, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task(id: source) {
            guard source.hasPrefix("data:image"), decoded == nil else { return }
            let image = await FaceImageCache.prepare(dataURL: source, key: "markdown:\(source.hashValue)", maxPixelSize: 1440)
            withAnimation(.smooth(duration: 0.3)) {
                decoded = image
                failed = image == nil
            }
        }
    }
}

// MARK: - Inline rendering

enum InlineRenderer {
    /// Builds an attributed string using presentation intents, so bold, italic and code
    /// adapt to whatever font the surrounding `Text` uses (body, heading, table cell). With a
    /// vocabulary, known `@handles` and `@file:` paths in plain runs carry
    /// ``MessageReferenceAttribute`` so the paragraph can draw them as pills.
    static func attributed(_ inlines: [MarkdownInline], vocabulary: ReferenceVocabulary? = nil) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            result += render(inline, intent: [], vocabulary: vocabulary)
        }
        return result
    }

    private static func render(_ inline: MarkdownInline, intent: InlinePresentationIntent, vocabulary: ReferenceVocabulary?) -> AttributedString {
        switch inline {
        case .text(let text):
            var run = AttributedString(text)
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            // References in plain runs only: never inside code or links.
            if let vocabulary {
                for reference in vocabulary.references(in: text) {
                    let lower = text.utf16.index(text.utf16.startIndex, offsetBy: reference.location)
                    let upper = text.utf16.index(lower, offsetBy: reference.length)
                    let start = run.index(run.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: lower))
                    let end = run.index(start, offsetByCharacters: text.distance(from: lower, to: upper))
                    run[start..<end][MessageReferenceAttribute.self] = reference
                }
            }
            return run
        case .emphasis(let children):
            return children.reduce(into: AttributedString()) { $0 += render($1, intent: intent.union(.emphasized), vocabulary: vocabulary) }
        case .strong(let children):
            return children.reduce(into: AttributedString()) { $0 += render($1, intent: intent.union(.stronglyEmphasized), vocabulary: vocabulary) }
        case .strikethrough(let children):
            return children.reduce(into: AttributedString()) { $0 += render($1, intent: intent.union(.strikethrough), vocabulary: vocabulary) }
        case .code(let code):
            // Narrow no-break spaces pad the tinted run without ever wrapping away from it.
            var run = AttributedString("\u{202F}\(code)\u{202F}")
            run.font = Theme.Typography.inlineCode
            run.backgroundColor = Theme.surfaceRaised
            if intent.contains(.stronglyEmphasized) { run.font = Theme.Typography.inlineCode.bold() }
            return run
        case .link(let destination, let children):
            var run = children.reduce(into: AttributedString()) { $0 += render($1, intent: intent, vocabulary: nil) }
            if let destination, let url = URL(string: destination) {
                run.link = url
                run.underlineStyle = .single
            }
            return run
        case .image(let source, let alt):
            var run = AttributedString(alt.isEmpty ? "Image" : alt)
            if let source, let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                run.link = url
                run.underlineStyle = .single
            }
            return run
        case .softBreak:
            return AttributedString(" ")
        case .lineBreak:
            return AttributedString("\n")
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
