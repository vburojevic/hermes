import HermesKit
import HermesMarkdown
import SwiftUI

/// Renders a Markdown string with Hermes' reading typography.
///
/// Equatable so SwiftUI only re-parses when the text actually changes, which
/// matters while a reply streams in a few characters at a time.
struct MarkdownView: View, Equatable {
    @Environment(\.selectsText) private var selectsText
    let text: String
    var tone: Tone = .primary
    /// Text that is still streaming changes with every token: parsed, not kept.
    var caches = true
    /// Listen (`docs/voice.md` §3): the sentence being read is ink, the rest of the reply lighter.
    var highlight: SpokenSentence?
    @Environment(\.references) private var references

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.tone == rhs.tone && lhs.caches == rhs.caches && lhs.highlight == rhs.highlight
    }

    enum Tone { case primary, secondary }

    var body: some View {
        MarkdownBlocksView(blocks: caches ? MarkdownCache.document(for: text).blocks : MarkdownCache.streamingBlocks(for: text), highlight: highlight)
            .foregroundStyle(tone == .primary ? Theme.primaryText : Theme.secondaryText)
            .modifier(SelectableText(isOn: selectsText))
            .environment(\.markdownCaches, caches)
            // A second lock behind the renderer's: whatever a reply links to, only the web and
            // mail open from it, and the gateway files the renderer found open in the Inspector.
            .environment(\.openURL, OpenURLAction { [references] url in
                if let path = GatewayFileLink.path(from: url) {
                    references.openInInspector(path)
                    return .handled
                }
                return WebLink.opensFromChat(url) ? .systemAction : .discarded
            })
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    /// The sentence being read aloud, by its top-level block.
    var highlight: SpokenSentence?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // Equatable: while a reply streams only the block still arriving redraws.
                MarkdownBlockView(block: block, sentence: highlight?.block == index ? highlight : nil)
                    .equatable()
                    .modifier(SpokenTone(isDimmed: highlight.map { $0.block != index } ?? false))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension EnvironmentValues {
    /// Body font for Markdown paragraphs, lists and tables; headings scale independently.
    @Entry var markdownBodyFont: Font = Theme.Typography.message
    /// Off while the text streams: its code changes with every token, and each version kept
    /// would push finished replies out of `MarkdownCache`.
    @Entry var markdownCaches = true
}

/// While a reply is read aloud, the blocks not being read are lighter.
private struct SpokenTone: ViewModifier {
    let isDimmed: Bool

    func body(content: Content) -> some View {
        if isDimmed {
            content.foregroundStyle(Theme.secondaryText)
        } else {
            content
        }
    }
}

private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    /// The sentence of this block being read aloud: in a paragraph, it's ink and the rest lighter.
    var sentence: SpokenSentence?
    @Environment(\.markdownBodyFont) private var bodyFont

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.block == rhs.block && lhs.sentence == rhs.sentence }

    /// `text` with only `sentence` in ink (the gateway gives no word timings: a sentence at a time).
    static func lit(_ text: AttributedString, sentence: SpokenSentence?) -> AttributedString {
        guard let sentence, case .words = sentence.kind else { return text }
        // Inline code is drawn padded with thin spaces the spoken text doesn't have: find the
        // sentence without them, then map back.
        var plain = ""
        var places: [AttributedString.Index] = []
        var index = text.characters.startIndex
        while index < text.characters.endIndex {
            let character = text.characters[index]
            if character != "\u{202F}" {
                plain.append(character)
                places.append(index)
            }
            index = text.characters.index(after: index)
        }
        guard let found = plain.range(of: sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return text }
        let first = plain.distance(from: plain.startIndex, to: found.lowerBound)
        let last = plain.distance(from: plain.startIndex, to: found.upperBound) - 1
        guard first <= last, last < places.count else { return text }
        var lit = text
        lit.foregroundColor = Theme.secondaryText
        lit[places[first]..<text.characters.index(after: places[last])].foregroundColor = Theme.primaryText
        return lit
    }

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            if let source = Self.standaloneImage(inlines) {
                MarkdownImage(source: source)
            } else if InlineRenderer.mayName(inlines) {
                // Only a paragraph that can name a Bot or a file reads what the chat can name:
                // the others don't redraw when that changes, as the roster and the commands
                // arrive while a chat opens (every reply's every block did).
                NamingParagraph(inlines: inlines, sentence: sentence)
            } else {
                Self.paragraph(InlineRenderer.attributed(inlines), font: bodyFont, sentence: sentence)
            }

        case .heading(let level, let inlines):
            let text = InlineRenderer.attributed(inlines)
            Text(text)
                .font(Theme.Typography.heading(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .modifier(StreamingReveal(length: text.characters.count))

        case .codeBlock(let language, let code):
            FencedCode(language: language, code: code)
                .modifier(StreamingAppear())

        case .blockQuote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(Theme.hairline)
                    .frame(width: 3)
                    .modifier(StreamingAppear())
                AnyView(MarkdownBlocksView(blocks: blocks))
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .list(let list):
            MarkdownListView(list: list)

        case .table(let table):
            MarkdownTableView(table: table)
                .modifier(StreamingAppear())

        case .thematicBreak:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 6)
                .modifier(StreamingAppear())

        case .html(let raw):
            Text(raw)
                .font(Theme.Typography.code)
                .foregroundStyle(Theme.secondaryText)
        }
    }

    @ViewBuilder
    static func paragraph(_ text: AttributedString, font: Font, sentence: SpokenSentence?, names: Bool = false) -> some View {
        if names, text.runs.contains(where: { $0[MessageReferenceAttribute.self] != nil }) {
            // Bots and files named in the reply are pills (`memberMessageMentions`).
            InlineFlow(attributed: text, font: font, size: font == Theme.Typography.message ? .message : .compact)
        } else {
            Text(lit(text, sentence: sentence))
                .font(font)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(StreamingReveal(length: text.characters.count))
        }
    }

    /// A paragraph with an `@` in its words, drawn with the chat's Bots and files as pills.
    private struct NamingParagraph: View {
        let inlines: [MarkdownInline]
        let sentence: SpokenSentence?
        @Environment(\.markdownBodyFont) private var bodyFont
        @Environment(\.references) private var references

        var body: some View {
            MarkdownBlockView.paragraph(InlineRenderer.attributed(inlines, vocabulary: references.vocabulary), font: bodyFont, sentence: sentence, names: true)
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

/// While a reply streams, its newest words fade in along the line, a little behind the stream,
/// instead of appearing a chunk at a time. Only the drawing changes: the text takes its full
/// room at once, so following the reply and the scroll position never wait on the fade.
private struct StreamingReveal: ViewModifier {
    let length: Int
    @Environment(\.markdownCaches) private var isSettled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double

    init(length: Int) {
        self.length = length
        // A paragraph appears with what has arrived of it: only its last words fade in, so a
        // burst doesn't leave a list's bullets waiting for their text (and a chat opened
        // mid-reply doesn't sweep in from the top).
        _shown = State(initialValue: Double(max(0, length - Self.freshTail)))
    }

    private static let freshTail = 24

    func body(content: Content) -> some View {
        // The swap from streaming to settled is instant: a reply settles inside an animated
        // hand-over, and with a fade its text faded out and back in as it finished.
        if isSettled || reduceMotion {
            content
                .transition(.identity)
        } else {
            content
                .textRenderer(RevealRenderer(shown: shown))
                .onAppear { reveal(from: max(0, length - Self.freshTail), to: length) }
                .onChange(of: length) { old, new in reveal(from: old, to: new) }
                .transition(.identity)
        }
    }

    private func reveal(from old: Int, to new: Int) {
        let target = RevealRenderer.target(new)
        guard target > shown else {
            shown = target // the text got shorter (a marker held back): no fade backwards
            return
        }
        // Keeps up with the stream: a few words ease in quickly, a burst sweeps in over at most
        // 0.4 s. Overlapping reveals add up into one steady movement.
        let added = Double(max(1, new - old))
        withAnimation(.linear(duration: min(0.4, max(0.2, added / 240)))) { shown = target }
    }
}

/// What isn't text in a streaming reply (a list's bullet, a code block, a table) fades in as it
/// arrives, with the words beside it, instead of popping in. Opacity only: nothing moves.
private struct StreamingAppear: ViewModifier {
    @Environment(\.markdownCaches) private var isSettled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown || isSettled || reduceMotion ? 1 : 0)
            .onAppear {
                guard !isSettled else { return }
                withAnimation(.easeOut(duration: 0.25)) { isShown = true }
            }
    }
}

/// Draws glyphs up to `shown` and fades the ones after it in over `fade` glyphs.
private nonisolated struct RevealRenderer: TextRenderer, Animatable {
    var shown: Double
    static let fade = 14.0

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    /// Everything fully drawn.
    static func target(_ length: Int) -> Double { Double(length) + fade }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                let count = Double(run.count)
                defer { index += count }
                if index + count + Self.fade <= shown {
                    context.draw(run)
                } else if index < shown {
                    for (offset, slice) in run.enumerated() {
                        let opacity = (shown - index - Double(offset)) / Self.fade
                        guard opacity > 0 else { break }
                        var glyph = context
                        glyph.opacity = min(1, opacity)
                        glyph.draw(slice)
                    }
                }
            }
        }
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
                        .modifier(StreamingAppear())
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
            TableLayout(columns: table.columnCount) {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    cell(table.header[safe: column] ?? [], column: column)
                        .font(bodyFont.weight(.semibold))
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(row[safe: column] ?? [], column: column)
                            .font(bodyFont)
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
            .frame(minWidth: 60, maxWidth: TableLayout.widest, alignment: alignment)
    }
}

/// A Markdown table's cells: the header row, then each row's rule and cells. Every cell is
/// measured once for its width (a column is as wide as its widest cell, 60 to 320 points) and
/// once at its column's width for its row's height. `Grid` measured every cell again and again to
/// share out its flexible columns: a reply's tables were a third of laying out a chat as it opened.
private nonisolated struct TableLayout: Layout {
    /// The widest a cell gets; wider text wraps.
    static let widest: CGFloat = 320
    let columns: Int

    struct Cache {
        var widths: [CGFloat] = []
        var heights: [CGFloat] = []
        var rule: CGFloat = 0
    }

    /// Each row's rule (none for the header) and its cells, as subview indices.
    private func rows(in subviews: Subviews) -> [(rule: Int?, cells: Range<Int>)] {
        guard columns > 0, subviews.count >= columns else { return [] }
        var rows: [(Int?, Range<Int>)] = [(nil, 0..<columns)]
        var index = columns
        while index + 1 + columns <= subviews.count {
            rows.append((index, (index + 1)..<(index + 1 + columns)))
            index += 1 + columns
        }
        return rows
    }

    func makeCache(subviews: Subviews) -> Cache {
        let rows = rows(in: subviews)
        var widths = [CGFloat](repeating: 0, count: columns)
        var ideal = [CGSize](repeating: .zero, count: subviews.count)
        for row in rows {
            for (column, index) in row.cells.enumerated() {
                ideal[index] = subviews[index].sizeThatFits(.unspecified)
                widths[column] = max(widths[column], ideal[index].width)
            }
        }
        // A cell narrower than the widest a cell gets didn't wrap: its height is known. Only one at
        // the limit is measured again, wrapped.
        let heights = rows.map { row in
            row.cells.enumerated().map { column, index in
                ideal[index].width < Self.widest ? ideal[index].height
                    : subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
            }.max() ?? 0
        }
        let total = widths.reduce(0, +)
        let rule = rows.dropFirst().first?.rule.map { subviews[$0].sizeThatFits(ProposedViewSize(width: total, height: nil)).height } ?? 0
        return Cache(widths: widths, heights: heights, rule: rule)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rules = cache.rule * CGFloat(max(0, cache.heights.count - 1))
        return CGSize(width: cache.widths.reduce(0, +), height: cache.heights.reduce(0, +) + rules)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let total = cache.widths.reduce(0, +)
        var y = bounds.minY
        for (row, layout) in rows(in: subviews).enumerated() where row < cache.heights.count {
            if let rule = layout.rule {
                subviews[rule].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: total, height: cache.rule))
                y += cache.rule
            }
            var x = bounds.minX
            for (column, index) in layout.cells.enumerated() {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: cache.widths[column], height: cache.heights[row]))
                x += cache.widths[column]
            }
            y += cache.heights[row]
        }
    }

    // A table's edges are its own: the default answer measured every cell again.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? {
        nil
    }
}

/// A fenced block: its code, or, when the whole block is a copy of a widget this device holds (a
/// Bot repeating a routine's brief, whose widget fence the plugin turned into json), that widget.
/// The block's own JSON is never read into the store (`ReplySplitter.echoedWidget`).
private struct FencedCode: View {
    let language: String?
    let code: String

    @Environment(\.widgetHost) private var host

    var body: some View {
        if code.allSatisfy(\.isWhitespace) {
            // A fence with nothing in it draws nothing, never an empty frame.
            EmptyView()
        } else if let echo = ReplySplitter.echoedWidget(language: language, code: code),
                  let result = host?.store.result(echo.id), result.rev >= echo.rev {
            WidgetSlot(directive: WidgetDirective(id: echo.id))
        } else {
            CodeBlockView(language: language, code: code)
        }
    }
}

/// Images embedded in replies: inline `data:` URLs (generated images) or remote URLs. Inline
/// images are decoded and downsampled off the main thread, once, then fade in.
private struct MarkdownImage: View {
    let source: String

    @Environment(\.gatewayHosts) private var gatewayHosts
    @State private var decoded: PlatformImage?
    @State private var failed = false
    /// The person asked for a picture from somewhere other than the gateway (`WebLink.isOnGateway`).
    @State private var fetches = false

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
            } else if let url = URL(string: source), WebLink.isWeb(url), !fetches, !WebLink.isOnGateway(url, gatewayHosts: gatewayHosts) {
                Button {
                    fetches = true
                } label: {
                    Label(String(localized: "Show Image from \(url.host() ?? "")"), systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .cardButton()
            } else if let url = URL(string: source), WebLink.loadsByItself(url) || (fetches && WebLink.isWeb(url)) {
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

    /// Whether the words can name a Bot or a file (`@handle`, `@file:`): an `@` in a plain run,
    /// where `attributed(_:vocabulary:)` looks for them.
    static func mayName(_ inlines: [MarkdownInline]) -> Bool {
        inlines.contains { inline in
            switch inline {
            case .text(let text): text.containsBytes("@")
            case .emphasis(let children), .strong(let children), .strikethrough(let children): mayName(children)
            default: false
            }
        }
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
            // A whole path to a file on the gateway opens in the Inspector (`GatewayFileLink`),
            // underlined under the path only, not its padding.
            if let path = GatewayFileLink.path(fromCode: code), let url = GatewayFileLink.url(for: path) {
                run.link = url
                if let first = run.characters.indices.first, let last = run.characters.indices.last, first < last {
                    run[run.characters.index(after: first)..<last].underlineStyle = .single
                }
            }
            return run
        case .link(let destination, let children):
            var run = children.reduce(into: AttributedString()) { $0 += render($1, intent: intent, vocabulary: nil) }
            // The web and mail, and files on the gateway, read-only in the Inspector: a link
            // Hermes wrote may come from a page or email it read, so it never pairs a gateway,
            // installs a plugin, or opens a local file or another app.
            if let destination, let path = GatewayFileLink.path(fromLink: destination), let url = GatewayFileLink.url(for: path) {
                run.link = url
                run.underlineStyle = .single
            } else if let destination, let url = URL(string: destination), WebLink.opensFromChat(url) {
                run.link = url
                run.underlineStyle = .single
            }
            return run
        case .image(let source, let alt):
            var run = AttributedString(alt.isEmpty ? "Image" : alt)
            if let source, let url = URL(string: source), WebLink.isWeb(url) {
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

extension InlineRenderer {
    /// Plain text (not Markdown) with its web addresses as links (`AutoLink`), the ones
    /// `allowing` lets open (`WebLink`'s, unless the place is stricter).
    static func linked(_ text: String, allowing: (URL) -> Bool = WebLink.isWeb) -> AttributedString {
        var result = AttributedString(text)
        for match in AutoLink.matches(in: text) {
            guard let url = URL(string: match.destination), WebLink.isWeb(url), allowing(url) else { continue }
            let start = result.index(result.startIndex, offsetByCharacters: text.distance(from: text.startIndex, to: match.range.lowerBound))
            let end = result.index(start, offsetByCharacters: text.distance(from: match.range.lowerBound, to: match.range.upperBound))
            result[start..<end].link = url
            result[start..<end].underlineStyle = .single
        }
        return result
    }
}

extension Text {
    /// Plain text whose web addresses can be tapped (`InlineRenderer.linked`): a Bot's message
    /// in another chat, a widget's words. Where they open is up to the `openURL` around it.
    init(linking text: String) {
        self.init(linking: text, allowing: WebLink.isWeb)
    }

    /// A widget's words: only `https:` addresses, like a widget's own links
    /// (`docs/widgets.md` §3). A tap asks first (`WidgetCard`).
    init(widgetLinking text: String) {
        self.init(linking: text) { $0.scheme?.lowercased() == "https" }
    }

    private init(linking text: String, allowing: (URL) -> Bool) {
        if AutoLink.matches(in: text).isEmpty {
            self.init(verbatim: text)
        } else {
            self.init(InlineRenderer.linked(text, allowing: allowing))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Text that can be selected in place, where `selectsText` allows.
private struct SelectableText: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Markdown's words can be selected in place (off in the iPhone and iPad transcript, where a
    /// reply's menu has Select Text).
    @Entry var selectsText = true
    /// The gateway's own hosts (`BotConfiguration.hosts`): pictures from there show by themselves,
    /// any other waits for a tap (`WebLink.isOnGateway`). Empty where no gateway is known, so
    /// every picture waits.
    @Entry var gatewayHosts: Set<String> = []
}
