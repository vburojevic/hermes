#if os(macOS)
import AppKit
#else
import UIKit
#endif
import HermesKit
import HermesMarkdown
import os
import SwiftUI

#if os(macOS)
typealias ReplyFont = NSFont
typealias ReplyColor = NSColor
typealias ReplyImage = NSImage
#else
typealias ReplyFont = UIFont
typealias ReplyColor = UIColor
typealias ReplyImage = UIImage
#endif

#if os(macOS)
/// A finished reply on the Mac as one text (`docs/chat.md` §3 Selection): one drag selects
/// across its paragraphs, lists and quotes, Cmd-A selects the whole reply, and Copy, Speech and
/// Services read the selection as plain text (`ReplyPlainText`). It draws what `MarkdownBlocksView`
/// draws, line for line: the same fonts, line heights, spacing, indents and colors. What only the
/// SwiftUI views draw (code blocks, tables, rules, lone images, checkboxes, pills) is those same
/// views, hosted inside the text.
struct ReplyTextView: NSViewRepresentable {
    let reply: ReplyText
    /// The sentence Listen is reading (`docs/voice.md` §3).
    var highlight: SpokenSentence?

    func makeNSView(context: Context) -> ReplyNSTextView {
        ReplyNSTextView(reply: reply)
    }

    func updateNSView(_ view: ReplyNSTextView, context: Context) {
        view.environment.values = context.environment
        view.show(reply)
        view.light(highlight)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ReplyNSTextView, context: Context) -> CGSize? {
        if let width = proposal.width, width.isFinite, width > 0 {
            return CGSize(width: width, height: view.height(for: width))
        }
        // Asked for its own size: as wide as its longest line, like a `Text`.
        let width = view.idealWidth()
        return CGSize(width: width, height: view.height(for: width))
    }
}
#endif

// MARK: - The text

/// A reply's paragraphs as one attributed string, built once and kept (`MarkdownCache.reply`), off
/// the main thread when a chat's replies are prewarmed. Each paragraph is one
/// `ReplyPlainText.Unit`. What only the SwiftUI views draw (a code block, table, rule or lone
/// image, an empty list item, html in an item, a tab in the words, a line that opens several
/// items, a paragraph that names a Bot or a file) is one attachment character that
/// `ReplyNSTextView` fills with the block's own view; a checklist item's box is drawn the same
/// way beside its words.
nonisolated final class ReplyText: @unchecked Sendable {
    nonisolated struct Paragraph: Sendable {
        let unit: ReplyPlainText.Unit
        /// Its characters in `storage`, without the line break that ends it.
        let range: NSRange
        /// Where its own words start, after a list item's marker.
        let content: Int
        /// Where its words start on the line, or where its view starts.
        let indent: CGFloat
        /// Space a heading keeps above itself.
        let topPad: CGFloat
        let lineSpacing: CGFloat
        let isQuoted: Bool
        /// The block its own view draws in its place; nil when the text draws it.
        let hosted: MarkdownBlock?
        /// A checklist item's box, beside the words.
        let checkbox: Checkbox?
    }

    /// A checklist item's box: the list's own view, from the list's leading edge.
    nonisolated struct Checkbox: Sendable {
        let x: CGFloat
        let isChecked: Bool
    }

    /// A block quote's bar, beside the paragraphs it holds.
    nonisolated struct QuoteBar: Sendable {
        let x: CGFloat
        let paragraphs: ClosedRange<Int>
    }

    /// Never changed once built, so it is shared across threads.
    let storage: NSAttributedString
    let paragraphs: [Paragraph]
    let bars: [QuoteBar]
    let compact: Bool
    /// Space above the first paragraph and below the last, kept by empty fences there.
    let top: CGFloat
    let bottom: CGFloat
    /// The paragraphs as `ReplyPlainText` reads a selection.
    let placed: [ReplyPlainText.Placed]
    /// Characters drawn and never copied: the thin spaces around inline code.
    let hidden: IndexSet
    /// It holds a code block or a table, which scroll sideways: a sideways drag there is theirs,
    /// and the reply has no swipe to reply (`AssistantTurnView.scrollsSideways`).
    let scrollsSideways: Bool
    /// Its heights as a view measured them, shared by every view of it: a chat opened again
    /// doesn't lay its replies out again just to size them (`docs/chat.md` §3 Selection).
    let heights = MeasuredHeights()

    private init(
        storage: NSAttributedString, paragraphs: [Paragraph], bars: [QuoteBar], compact: Bool, top: CGFloat, bottom: CGFloat
    ) {
        self.storage = storage
        self.paragraphs = paragraphs
        self.bars = bars
        self.compact = compact
        self.top = top
        self.bottom = bottom
        placed = paragraphs.map {
            ReplyPlainText.Placed(unit: $0.unit, range: $0.range, content: $0.content, isWhole: $0.hosted != nil)
        }
        var hidden = IndexSet()
        storage.enumerateAttribute(.replyPadding, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { hidden.insert(integersIn: range.location..<NSMaxRange(range)) }
        }
        self.hidden = hidden
        scrollsSideways = paragraphs.contains { $0.hosted.map(ReplyPlainText.scrollsSideways) ?? false }
    }

    var units: [ReplyPlainText.Unit] { paragraphs.map(\.unit) }

    /// Whether TextKit adds a font's leading below its lines. On iPhone and iPad the line spacing
    /// carries it, as SwiftUI places it (`Metrics.lineSpacing(_:font:)`).
    #if os(macOS)
    static let drawsLeading = true
    #else
    static let drawsLeading = false
    #endif

    var bodyFont: Font { compact ? Theme.Typography.compactMessage : Theme.Typography.message }

    /// The reply's text, for a screen of `scale` pixels per point, at a text size (iPhone and iPad
    /// follow Dynamic Type and Bold Text; the Mac's sizes are fixed). `named` are the paragraphs
    /// whose words name a Bot or a file the chat knows (`InlineRenderer.mayName`): they are drawn
    /// as pills by their own view.
    static func build(
        _ blocks: [MarkdownBlock], compact: Bool, scale: CGFloat, named: Set<Int> = [],
        typeSize: DynamicTypeSize = .large, legibility: LegibilityWeight? = nil
    ) -> ReplyText? {
        let units = ReplyPlainText.units(blocks)
        guard !units.isEmpty else { return nil }
        let fonts = Fonts(compact: compact, typeSize: typeSize, legibility: legibility)
        let hosts = units.indices.map { ReplyPlainText.hosted(units[$0], names: named.contains($0)) }
        let unitFonts = units.indices.map { fonts.font(for: units[$0], hosted: hosts[$0] != nil) }
        let lineSpacings = units.indices.map { hosts[$0] == nil ? Metrics.lineSpacing(units[$0], font: unitFonts[$0]) : 0 }
        let topPads = units.indices.map { hosts[$0] == nil ? Metrics.topPad(units[$0]) : 0 }
        let storage = NSMutableAttributedString()
        var paragraphs: [Paragraph] = []
        var quotes: [Int: (x: CGFloat, first: Int, last: Int)] = [:]

        for (index, unit) in units.enumerated() {
            // Where its words start, where each list it is in starts, and where its marker goes.
            var x: CGFloat = 0
            var lists: [Int: CGFloat] = [:]
            var marker: (level: Int, x: CGFloat, width: CGFloat, marker: ReplyPlainText.Unit.Marker)?
            for (level, kind) in unit.levels.enumerated() {
                switch kind {
                case .quote(let quote):
                    let start = quotes[quote]?.first ?? index
                    quotes[quote] = (x, start, index)
                    x += Metrics.quoteIndent
                case .item(let itemMarker):
                    lists[level] = x
                    let markerX = x + Metrics.listLeading
                    let width = Metrics.markerWidth(itemMarker, fonts: fonts, scale: scale)
                    if unit.markers.contains(level) { marker = (level, markerX, width, itemMarker) }
                    x = markerX + width + Metrics.markerSpacing
                }
            }
            let isQuoted = unit.levels.contains { if case .quote = $0 { true } else { false } }
            let color = isQuoted ? Palette.secondary : Palette.primary
            let host = hosts[index]
            // A block that opens list items is that list, drawn from the outer one's edge.
            let indent = host == nil ? x : unit.markers.first.flatMap { lists[$0] } ?? x

            let font = unitFonts[index]
            let text = NSMutableAttributedString()
            switch (host, unit.content) {
            case (nil, .paragraph(let inlines)), (nil, .heading(_, let inlines)):
                text.append(Inlines(fonts: fonts, base: font, color: color).attributed(inlines))
            case (nil, .html(let raw)):
                text.append(NSAttributedString(string: raw.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: [
                    .font: font, .foregroundColor: Palette.secondary,
                ]))
            default:
                text.append(NSAttributedString(string: "\u{FFFC}", attributes: [
                    .font: font, .replyBlock: index, .foregroundColor: color,
                ]))
            }

            var content = 0
            var tabs: [NSTextTab] = []
            var checkbox: Checkbox?
            if host == nil, let marker {
                switch marker.marker {
                case .checkbox(let checked):
                    // The box is a symbol image: its view draws it beside the words.
                    checkbox = Checkbox(x: lists[marker.level] ?? 0, isChecked: checked)
                case .bullet, .number:
                    // The marker sits in a column of its own, on the line's first baseline, like the
                    // list's `HStack(alignment: .firstTextBaseline)`. SwiftUI sizes the marker's Text
                    // to whole pixels and places it on a whole pixel: a number at the column's
                    // trailing edge, a bullet in the column's middle.
                    let (markerText, markerFont): (String, ReplyFont) = if case .number(let number) = marker.marker {
                        ("\(number).", fonts.number)
                    } else {
                        ("•", fonts.bullet)
                    }
                    let markerWidth = Metrics.pixels(Metrics.advance(markerText, font: markerFont), scale: scale, rule: .up)
                    let offset = if case .number = marker.marker {
                        marker.width - markerWidth
                    } else {
                        Metrics.pixels((marker.width - markerWidth) / 2, scale: scale, rule: .toNearestOrAwayFromZero)
                    }
                    let start = marker.x + offset
                    let markerAttributes: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: Palette.secondary]
                    let prefix: NSMutableAttributedString
                    #if os(iOS)
                    // A tab never moves back, and one at the pen is passed by. A bullet wider than
                    // its column (the largest text sizes) would want a stop at or before the line's
                    // start, and TextKit would push it to the words' stop and lay out nothing after
                    // it: it starts at the line's start with no tab, and the words never start
                    // before it ends. The Mac lays its markers out as it always has.
                    let words = NSTextTab(textAlignment: .left, location: max(x, max(0, start) + markerWidth))
                    if start > 0 {
                        prefix = NSMutableAttributedString(string: "\t\(markerText)\t", attributes: markerAttributes)
                        prefix.addAttribute(.font, value: font, range: NSRange(location: 0, length: 1))
                        tabs = [NSTextTab(textAlignment: .left, location: start), words]
                    } else {
                        prefix = NSMutableAttributedString(string: "\(markerText)\t", attributes: markerAttributes)
                        tabs = [words]
                    }
                    #else
                    prefix = NSMutableAttributedString(string: "\t\(markerText)\t", attributes: markerAttributes)
                    prefix.addAttribute(.font, value: font, range: NSRange(location: 0, length: 1))
                    tabs = [NSTextTab(textAlignment: .left, location: start), NSTextTab(textAlignment: .left, location: x)]
                    #endif
                    prefix.addAttribute(.font, value: font, range: NSRange(location: prefix.length - 1, length: 1))
                    text.insert(prefix, at: 0)
                    content = prefix.length
                }
            }

            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = tabs.isEmpty ? indent : 0
            style.headIndent = indent
            style.tabStops = tabs
            style.defaultTabInterval = 0
            style.lineSpacing = lineSpacings[index]
            style.lineBreakMode = .byWordWrapping
            style.lineBreakStrategy = .standard
            if host == nil {
                let line = Metrics.line(for: font)
                #if os(macOS)
                style.minimumLineHeight = line.height
                style.maximumLineHeight = line.height
                // TextKit sets the baseline lower in the line than SwiftUI does. A baseline offset
                // would move the line with it, so the paragraph's glyphs are raised as they draw.
                let raise = Metrics.raise(for: font)
                if raise != 0 { text.addAttribute(.replyRaise, value: raise, range: NSRange(location: 0, length: text.length)) }
                #else
                // On iPhone and iPad each line is as tall as its own fonts, as SwiftUI's are: a line
                // of nothing but inline code is shorter than one with words in the body font.
                #endif
                // SwiftUI draws glyphs on a whole point but places underlines from the baseline it
                // computed: the line's bottom less the font's descent.
                let drop = line.height + font.descender - line.ascent
                text.addAttribute(.replyDrop, value: drop, range: NSRange(location: 0, length: text.length))
            }
            if index + 1 < units.count {
                let spacing: CGFloat = switch units[index + 1].gap {
                case .none: 0
                case .item: Metrics.itemSpacing
                case .block: Metrics.blockSpacing
                }
                let gap = spacing + CGFloat(units[index + 1].blanks) * Metrics.blockSpacing
                // TextKit 2 puts a paragraph's line spacing above each of its lines but the
                // reply's first, so the next one's comes out of the gap.
                style.paragraphSpacing = gap + topPads[index + 1] - lineSpacings[index + 1]
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))

            let start = storage.length
            storage.append(text)
            let length = text.length - (index + 1 < units.count ? 1 : 0)
            paragraphs.append(Paragraph(
                unit: unit, range: NSRange(location: start, length: length), content: start + content,
                indent: indent, topPad: topPads[index], lineSpacing: lineSpacings[index], isQuoted: isQuoted,
                hosted: host, checkbox: checkbox))
        }
        let bars = quotes.values.sorted { $0.first < $1.first }.map { QuoteBar(x: $0.x, paragraphs: $0.first...$0.last) }
        return ReplyText(
            storage: NSAttributedString(attributedString: storage), paragraphs: paragraphs, bars: bars, compact: compact,
            top: CGFloat(units[0].blanks) * Metrics.blockSpacing,
            bottom: CGFloat(ReplyPlainText.trailingBlanks(blocks)) * Metrics.blockSpacing)
    }

    /// The theme's fonts as TextKit draws them, resolved as SwiftUI resolves them at this text size.
    nonisolated struct Fonts {
        let body: ReplyFont
        let number: ReplyFont
        let bullet: ReplyFont
        let code: ReplyFont
        let inlineCode: ReplyFont
        let inlineCodeBold: ReplyFont
        private let headings: [ReplyFont]
        /// Bold words as SwiftUI draws them: on iPhone and iPad a text style's bold is its own
        /// emphasized weight (semibold for the body), which `systemFont(weight: .bold)` is not.
        private let strongs: [ReplyFont]

        init(compact: Bool, typeSize: DynamicTypeSize = .large, legibility: LegibilityWeight? = nil) {
            var environment = EnvironmentValues()
            environment.dynamicTypeSize = typeSize
            environment.legibilityWeight = legibility
            let context = environment.fontResolutionContext
            func resolved(_ font: Font) -> ReplyFont { font.resolve(in: context).ctFont as ReplyFont }
            let message = compact ? Theme.Typography.compactMessage : Theme.Typography.message
            body = resolved(message)
            number = resolved(message.monospacedDigit())
            bullet = resolved(message.weight(.bold))
            code = resolved(Theme.Typography.code)
            inlineCode = resolved(Theme.Typography.inlineCode)
            inlineCodeBold = resolved(Theme.Typography.inlineCode.bold())
            headings = (1...4).map { resolved(Theme.Typography.heading($0)) }
            strongs = [resolved(message.bold())] + (1...4).map { resolved(Theme.Typography.heading($0).bold()) }
            #if DEBUG && os(macOS)
            for font in [body, code] + headings {
                assert(Metrics.measured(font) != nil, "\(font.pointSize) pt: measure its line against the block views")
            }
            #endif
        }

        func heading(_ level: Int) -> ReplyFont {
            headings[min(max(level, 1), 4) - 1]
        }

        /// The bold of a line's font. The Mac's block views draw the system font's bold weight.
        func strong(_ base: ReplyFont) -> ReplyFont {
            #if os(macOS)
            return .systemFont(ofSize: base.pointSize, weight: .bold)
            #else
            if let index = ([body] + headings).firstIndex(of: base) { return strongs[index] }
            return .systemFont(ofSize: base.pointSize, weight: .bold)
            #endif
        }

        /// The font a unit's line is drawn in; a hosted block's line is a point tall.
        func font(for unit: ReplyPlainText.Unit, hosted: Bool) -> ReplyFont {
            guard !hosted else { return Metrics.attachmentFont }
            switch unit.content {
            case .paragraph: return body
            case .heading(let level, _): return heading(level)
            case .html: return code
            default: return Metrics.attachmentFont
            }
        }
    }

    /// The SwiftUI views' metrics, in points.
    nonisolated enum Metrics {
        /// The block views' own spaces (`MarkdownSpacing`).
        static let blockSpacing = MarkdownSpacing.block
        static let itemSpacing = MarkdownSpacing.item
        static let quoteIndent = MarkdownSpacing.quoteBar + MarkdownSpacing.quoteGap
        static let quoteBarWidth = MarkdownSpacing.quoteBar
        static let listLeading = MarkdownSpacing.listLeading
        static let markerSpacing = MarkdownSpacing.marker
        /// A rule's height: its line and the space above and below it.
        static let ruleHeight = 1 + 2 * MarkdownSpacing.rulePadding

        /// The font of a hosted block's line: a point tall, so the line is as tall as the block.
        /// Never changed, so it is shared across threads (`UIFont` is `Sendable`; `NSFont` isn't marked so).
        #if os(macOS)
        nonisolated(unsafe) static let attachmentFont = ReplyFont.systemFont(ofSize: 1)
        #else
        static let attachmentFont = ReplyFont.systemFont(ofSize: 1)
        #endif

        /// The space between a unit's lines. On iPhone and iPad SwiftUI puts the font's leading
        /// there when it is more than the `Text`'s line spacing, so TextKit draws no leading of its
        /// own (`ReplyText.drawsLeading`).
        static func lineSpacing(_ unit: ReplyPlainText.Unit, font: ReplyFont) -> CGFloat {
            let spacing: CGFloat = if case .paragraph = unit.content { Theme.Typography.messageLineSpacing } else { 0 }
            #if os(macOS)
            return spacing
            #else
            return max(spacing, font.leading)
            #endif
        }

        static func topPad(_ unit: ReplyPlainText.Unit) -> CGFloat {
            if case .heading(let level, _) = unit.content { MarkdownSpacing.headingTop(level) } else { 0 }
        }

        /// How far a run of text advances in one font.
        static func advance(_ string: String, font: ReplyFont) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }

        /// A length on SwiftUI's pixel grid.
        static func pixels(_ length: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
            (length * scale).rounded(rule) / scale
        }

        /// A bullet's column is 12 points, a number's at least 18 or as wide as its digits, and a
        /// checkbox's as wide as its symbol lays out: its alignment rectangle, narrower than the image.
        static func markerWidth(_ marker: ReplyPlainText.Unit.Marker, fonts: Fonts, scale: CGFloat) -> CGFloat {
            switch marker {
            case .bullet:
                return MarkdownSpacing.bulletWidth
            case .number(let number):
                return max(MarkdownSpacing.numberWidth, pixels(advance("\(number).", font: fonts.number), scale: scale, rule: .up))
            case .checkbox(let checked):
                let name = checked ? "checkmark.square.fill" : "square"
                #if os(macOS)
                let configuration = NSImage.SymbolConfiguration(pointSize: fonts.body.pointSize, weight: .regular)
                let width = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)?.alignmentRect.width
                #else
                let configuration = UIImage.SymbolConfiguration(pointSize: fonts.body.pointSize, weight: .regular)
                let width = UIImage(systemName: name, withConfiguration: configuration).map { image in
                    image.size.width - image.alignmentRectInsets.left - image.alignmentRectInsets.right
                }
                #endif
                return pixels(width ?? MarkdownSpacing.bulletWidth, scale: scale, rule: .up)
            }
        }

        #if os(macOS)
        /// How tall SwiftUI draws a line of this font, and where its baseline sits: measured at
        /// each size a reply uses, against the views.
        static func line(for font: ReplyFont) -> (ascent: CGFloat, height: CGFloat) {
            measured(font) ?? (ceil(font.ascender), ceil(font.ascender - font.descender + font.leading))
        }
        #else
        /// How tall SwiftUI draws a line of this font, and where its baseline sits. On iPhone and
        /// iPad a `Text` line is the font's own line height, unrounded, at every Dynamic Type size;
        /// the space between lines is `lineSpacing(_:font:)`.
        static func line(for font: ReplyFont) -> (ascent: CGFloat, height: CGFloat) {
            (font.ascender, font.lineHeight)
        }
        #endif

        /// The lines measured at the theme's Mac sizes (`Theme.Typography`). `Fonts` checks in
        /// Debug builds that every size the reply uses is here, so a new size is measured against
        /// the views before the text can draw it differently.
        #if os(macOS)
        static func measured(_ font: ReplyFont) -> (ascent: CGFloat, height: CGFloat)? {
            let isMono = font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            switch (isMono, font.pointSize) {
            case (false, 22): return (21, 26)
            case (false, 19): return (18, 23)
            case (false, 16.5): return (16, 20)
            case (false, 15): return (15, 19)
            case (false, 13): return (13, 16)
            case (true, 12.5): return (12, 15)
            default: return nil
            }
        }
        #endif

        private static let offsets = OSAllocatedUnfairLock<[String: CGFloat]>(initialState: [:])

        /// How far above TextKit's baseline SwiftUI's sits, in a line of SwiftUI's height:
        /// measured once per font.
        static func raise(for font: ReplyFont) -> CGFloat {
            let key = "\(font.fontName) \(font.pointSize)"
            if let offset = offsets.withLock({ $0[key] }) { return offset }
            let line = line(for: font)
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = line.height
            style.maximumLineHeight = line.height
            let content = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            layout.usesFontLeading = ReplyText.drawsLeading
            content.addTextLayoutManager(layout)
            layout.textContainer = NSTextContainer(size: CGSize(width: 1000, height: 1000))
            layout.textContainer?.lineFragmentPadding = 0
            content.attributedString = NSAttributedString(string: "Hg", attributes: [.font: font, .paragraphStyle: style])
            layout.ensureLayout(for: layout.documentRange)
            var baseline: CGFloat = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
                if let first = fragment.textLineFragments.first {
                    baseline = fragment.layoutFragmentFrame.minY + first.typographicBounds.minY + first.glyphOrigin.y
                }
                return false
            }
            let offset = baseline - line.ascent
            offsets.withLock { $0[key] = offset }
            return offset
        }
    }

    /// The theme's colors, as TextKit draws them (they follow light, dark and Increase Contrast).
    nonisolated enum Palette {
        static var primary: ReplyColor { ReplyColor(Theme.primaryText) }
        static var secondary: ReplyColor { ReplyColor(Theme.secondaryText) }
        static var codeBackground: ReplyColor { ReplyColor(Theme.surfaceRaised) }
        static var hairline: ReplyColor { ReplyColor(Theme.hairline) }
        /// What SwiftUI draws a `Text` link in when nothing above it sets a tint: the system's link
        /// color on the Mac, the app's accent on iPhone and iPad.
        #if os(macOS)
        static var link: ReplyColor { .linkColor }
        #else
        static var link: ReplyColor { ReplyColor(Color.accentColor) }
        #endif
    }
}

extension NSAttributedString.Key {
    /// The paragraph, by index, whose block an attachment character stands for.
    nonisolated static let replyBlock = NSAttributedString.Key("HermesReplyBlock")
    /// The thin spaces around inline code: drawn, never copied.
    nonisolated static let replyPadding = NSAttributedString.Key("HermesReplyPadding")
    /// How many points a paragraph's glyphs are drawn above where TextKit puts them.
    nonisolated static let replyRaise = NSAttributedString.Key("HermesReplyRaise")
    /// A link's underline, drawn where SwiftUI draws it: TextKit's own sits a point lower.
    nonisolated static let replyUnderline = NSAttributedString.Key("HermesReplyUnderline")
    /// How far below the drawn baseline SwiftUI's own baseline sits, which its underlines follow.
    nonisolated static let replyDrop = NSAttributedString.Key("HermesReplyDrop")
    /// Struck words' line, drawn as SwiftUI draws it: TextKit's runs a point longer.
    nonisolated static let replyStrike = NSAttributedString.Key("HermesReplyStrike")
    /// The box behind code that opens a file. SwiftUI draws it the line's full height and half a
    /// point wider than plain code's, so it is drawn by hand.
    nonisolated static let replyLinkBackground = NSAttributedString.Key("HermesReplyLinkBackground")
}

/// Inline Markdown as `InlineRenderer.attributed` renders it, in AppKit attributes.
private nonisolated struct Inlines {
    let fonts: ReplyText.Fonts
    let base: ReplyFont
    let color: ReplyColor

    func attributed(_ inlines: [MarkdownInline]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines { render(inline, bold: false, italic: false, strike: false, into: result) }
        return result
    }

    private func font(bold: Bool, italic: Bool) -> ReplyFont {
        var font = base
        if bold { font = fonts.strong(base) }
        if italic {
            #if os(macOS)
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: font.pointSize) ?? font
            #else
            if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            #endif
        }
        return font
    }

    private func render(_ inline: MarkdownInline, bold: Bool, italic: Bool, strike: Bool, into result: NSMutableAttributedString) {
        switch inline {
        case .text(let text):
            var attributes: [NSAttributedString.Key: Any] = [.font: font(bold: bold, italic: italic), .foregroundColor: color]
            if strike { attributes[.replyStrike] = true }
            result.append(NSAttributedString(string: text, attributes: attributes))
        case .emphasis(let children):
            for child in children { render(child, bold: bold, italic: true, strike: strike, into: result) }
        case .strong(let children):
            for child in children { render(child, bold: true, italic: italic, strike: strike, into: result) }
        case .strikethrough(let children):
            for child in children { render(child, bold: bold, italic: italic, strike: true, into: result) }
        case .code(let code):
            let run = NSMutableAttributedString(string: "\u{202F}\(code)\u{202F}", attributes: [
                .font: bold ? fonts.inlineCodeBold : fonts.inlineCode,
                .foregroundColor: color,
                .backgroundColor: ReplyText.Palette.codeBackground,
                .languageIdentifier: "zxx",
            ])
            run.addAttribute(.replyPadding, value: true, range: NSRange(location: 0, length: 1))
            run.addAttribute(.replyPadding, value: true, range: NSRange(location: run.length - 1, length: 1))
            if let path = GatewayFileLink.path(fromCode: code), let url = GatewayFileLink.url(for: path) {
                run.addAttribute(.link, value: url, range: NSRange(location: 0, length: run.length))
                run.addAttribute(.foregroundColor, value: ReplyText.Palette.link, range: NSRange(location: 0, length: run.length))
                run.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: run.length))
                run.addAttribute(.replyLinkBackground, value: ReplyText.Palette.codeBackground, range: NSRange(location: 0, length: run.length))
                if run.length > 2 {
                    run.addAttribute(.replyUnderline, value: true, range: NSRange(location: 1, length: run.length - 2))
                }
            }
            result.append(run)
        case .link(let destination, let children):
            let run = NSMutableAttributedString()
            for child in children { render(child, bold: bold, italic: italic, strike: strike, into: run) }
            if let destination, let path = GatewayFileLink.path(fromLink: destination), let url = GatewayFileLink.url(for: path) {
                linked(run, url)
            } else if let destination, let url = URL(string: destination), WebLink.opensFromChat(url) {
                linked(run, url)
            }
            result.append(run)
        case .image(let source, let alt):
            let run = NSMutableAttributedString(string: alt.isEmpty ? "Image" : alt, attributes: [.font: font(bold: bold, italic: italic), .foregroundColor: color])
            if let source, let url = URL(string: source), WebLink.isWeb(url) { linked(run, url) }
            result.append(run)
        case .softBreak:
            result.append(NSAttributedString(string: " ", attributes: [.font: base, .foregroundColor: color]))
        case .lineBreak:
            result.append(NSAttributedString(string: "\u{2028}", attributes: [.font: base, .foregroundColor: color]))
        }
    }

    private func linked(_ run: NSMutableAttributedString, _ url: URL) {
        let all = NSRange(location: 0, length: run.length)
        run.addAttribute(.link, value: url, range: all)
        run.addAttribute(.replyUnderline, value: true, range: all)
        run.addAttribute(.foregroundColor, value: ReplyText.Palette.link, range: all)
    }
}

#if os(macOS)
// MARK: - The view

/// The text view behind `ReplyTextView`: selectable, never editable, with no background of its own.
final class ReplyNSTextView: NSTextView, ReplyBlockOwner {
    private(set) var reply: ReplyText
    /// Where the reply sits, for the views it hosts. Its `openURL` is the chat's link gate
    /// (`MarkdownView`): links open only through it.
    let environment = ReplyEnvironment()
    private var spoken: SpokenSentence?
    private var heights: [CGFloat: CGFloat] = [:]
    private var barRects: [NSRect] = []
    /// The hosted paragraphs' attachments, by paragraph.
    private var blocks: [Int: ReplyBlockAttachment] = [:]
    /// Each block's own view, over the space its attachment keeps in the text.
    private var blockViews: [Int: NSView] = [:]
    /// Each block's view as SwiftUI measures it, away from the window.
    private var blockMeasures: [Int: NSHostingController<ReplyBlockHost>] = [:]
    /// Each block's height, by the width it was laid out at.
    private var blockHeights: [Int: [CGFloat: CGFloat]] = [:]
    /// The checklist items' boxes, by paragraph, beside their words.
    private var checkboxViews: [Int: NSView] = [:]
    private var headings: [Int: ReplyHeadingElement] = [:]
    private var clickMonitor: Any?
    private let menuWatch = SelectionMenuWatch()
    /// A press that hasn't yet moved far enough to tell a selection from a swipe to reply.
    private var pendingPress: NSEvent?
    /// The press that became a swipe to reply, and the message's swipe that follows the rest of it.
    private var swiping: (press: NSEvent, swipe: ReplySwipe)?
    /// Where a press that began outside the text was, so its release is passed over too.
    private var strayPress: NSPoint?

    private let contentStorage = NSTextContentStorage()
    private let layout = NSTextLayoutManager()
    private let fragments = ReplyFragments()
    /// The same text laid out away from the view. A text view sizes its container to its own
    /// frame, so SwiftUI's question (how tall at this width) is answered here.
    private let measure = ReplyMeasure()

    init(reply: ReplyText) {
        self.reply = reply
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.textContainer = container
        layout.delegate = fragments
        contentStorage.addTextLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        displaysLinkToolTips = false
        usesFindBar = false
        focusRingType = .none
        // Links are drawn in their own color, from the text: only the cursor changes over them.
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("Use init(reply:)")
    }

    // MARK: Contents

    func show(_ reply: ReplyText) {
        guard reply !== self.reply else { return }
        self.reply = reply
        spoken = nil
        load()
    }

    private func load() {
        let text = NSMutableAttributedString(attributedString: reply.storage)
        blocks = [:]
        for view in blockViews.values { view.removeFromSuperview() }
        for view in checkboxViews.values { view.removeFromSuperview() }
        blockViews = [:]
        checkboxViews = [:]
        blockMeasures = [:]
        blockHeights = [:]
        headings = [:]
        text.enumerateAttribute(.replyBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let index = value as? Int, let block = reply.paragraphs[index].hosted else { return }
            let paragraph = reply.paragraphs[index]
            let attachment = ReplyBlockAttachment(paragraph: index, block: block, indent: paragraph.indent, owner: self)
            attachment.state.isQuoted = paragraph.isQuoted
            blocks[index] = attachment
            text.addAttribute(.attachment, value: attachment, range: range)
        }
        heights = [:]
        textStorage?.setAttributedString(text)
        measure.load(text)
        setSelectedRange(NSRange(location: 0, length: 0))
        placeBlocks()
    }

    /// The top of the first line: a heading keeps its space above itself, and an empty fence
    /// before it a block's space.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: 0, y: reply.top + (reply.paragraphs.first?.topPad ?? 0))
    }

    // MARK: Size

    func height(for width: CGFloat) -> CGFloat {
        if let height = heights[width] { return height }
        if let height = reply.heights.height(at: width) {
            heights[width] = height
            return height
        }
        // Not rounded: a block has a fractional height, and SwiftUI stacks it as it is.
        let height = measure.height(for: width) + textContainerOrigin.y + reply.bottom
        heights[width] = height
        reply.heights.record(height, at: width)
        return height
    }

    func idealWidth() -> CGFloat {
        let blockWidths = blocks.values.map { attachment in
            measuring(attachment).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + attachment.indent
        }
        return ceil(max(measure.idealWidth(), blockWidths.max() ?? 0))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        measureBars()
        placeBlocks()
        if selectedRange().length > 0 { environment.values.selectionReply?.words.relocate() }
    }

    // MARK: Quotes

    /// Each quote's bar runs beside its paragraphs, from the top of the first (with a heading's
    /// space above it) to the last one's last line.
    private func measureBars() {
        barRects = reply.barRects(in: layout, content: contentStorage, origin: textContainerOrigin)
    }

    private func fragment(for paragraph: Int) -> NSTextLayoutFragment? {
        reply.fragment(for: paragraph, in: layout, content: contentStorage)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !barRects.isEmpty else { return }
        ReplyText.Palette.hairline.setFill()
        for bar in barRects where bar.intersects(rect) {
            NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        }
    }

    // MARK: Blocks

    /// A block's height at this width, as SwiftUI lays it out.
    func blockHeight(_ attachment: ReplyBlockAttachment, width: CGFloat) -> CGFloat {
        let index = attachment.paragraph
        if let height = blockHeights[index]?[width] { return height }
        let key = MeasuredHeights.BlockKey(paragraph: index, width: width)
        let height: CGFloat = if case .thematicBreak = attachment.block {
            ReplyText.Metrics.ruleHeight
        } else if let kept = reply.heights.blockHeight(key) {
            kept
        } else {
            measuring(attachment).sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        }
        blockHeights[index, default: [:]][width] = height
        reply.heights.recordBlock(height, at: key)
        return height
    }

    private func measuring(_ attachment: ReplyBlockAttachment) -> NSHostingController<ReplyBlockHost> {
        if let host = blockMeasures[attachment.paragraph] { return host }
        let host = NSHostingController(rootView: blockView(attachment, resized: nil))
        blockMeasures[attachment.paragraph] = host
        return host
    }

    /// A block's view changed its height where it is shown (an image arrived, a widget drew):
    /// the text makes room for it.
    private func blockResized(_ index: Int, to height: CGFloat) {
        guard let view = blockViews[index], let known = blockHeights[index]?[view.frame.width],
              abs(known - height) > 0.01 else { return }
        // What other views of this reply would reuse no longer holds.
        reply.heights.blockResized()
        blockHeights[index] = [view.frame.width: height]
        heights = [:]
        measure.invalidate()
        layout.invalidateLayout(for: layout.documentRange)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        measureBars()
        placeBlocks()
    }

    /// Puts each block's view where its attachment is laid out, and each checklist item's box
    /// beside its first line. The view draws the block; the attachment only keeps its place in
    /// the text and the selection.
    private func placeBlocks() {
        guard !blocks.isEmpty || reply.paragraphs.contains(where: { $0.checkbox != nil }), bounds.width > 0 else { return }
        layout.ensureLayout(for: layout.documentRange)
        let origin = textContainerOrigin
        for (index, attachment) in blocks.sorted(by: { $0.key < $1.key }) {
            guard let fragment = fragment(for: index) else { continue }
            let width = max(0, bounds.width - attachment.indent)
            // SwiftUI puts a block's edges on whole pixels.
            let top = origin.y + fragment.layoutFragmentFrame.minY
            let bottom = top + blockHeight(attachment, width: width)
            let frame = NSRect(x: origin.x + attachment.indent, y: pixel(top), width: width, height: pixel(bottom) - pixel(top))
            let view = blockViews[index] ?? {
                let view = NSHostingView(rootView: blockView(attachment, resized: { [weak self] in self?.blockResized(index, to: $0) }))
                view.sizingOptions = []
                addSubview(view)
                blockViews[index] = view
                return view
            }()
            if view.frame != frame { view.frame = frame }
        }
        for (index, paragraph) in reply.paragraphs.enumerated() {
            guard let checkbox = paragraph.checkbox, let fragment = fragment(for: index),
                  let line = fragment.textLineFragments.first else { continue }
            let view = checkboxViews[index] ?? {
                let state = ReplyBlockState()
                state.isQuoted = paragraph.isQuoted
                let view = ReplyCheckboxView(rootView: ReplyCheckbox(
                    isChecked: checkbox.isChecked, state: state, environment: environment, font: reply.bodyFont))
                view.state = state
                view.sizingOptions = []
                addSubview(view)
                checkboxViews[index] = view
                return view
            }()
            // The list's own row: its marker on the first line's baseline, from the list's edge.
            let top = pixel(origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
            let frame = NSRect(
                x: origin.x + checkbox.x, y: top, width: max(0, bounds.width - checkbox.x),
                height: pixel(line.typographicBounds.height))
            if view.frame != frame { view.frame = frame }
        }
    }

    private func pixel(_ y: CGFloat) -> CGFloat {
        (y * fragments.scale).rounded() / fragments.scale
    }

    private func blockView(_ attachment: ReplyBlockAttachment, resized: ((CGFloat) -> Void)?) -> ReplyBlockHost {
        ReplyBlockHost(
            block: attachment.block, state: attachment.state, environment: environment, font: reply.bodyFont, resized: resized)
    }

    // MARK: Accessibility

    /// The text, then what it hosts in reading order: its headings (for heading navigation), and
    /// the blocks' and checkboxes' own views, with their buttons and cells.
    override func accessibilityChildren() -> [Any]? {
        let own = super.accessibilityChildren() ?? []
        let origin = textContainerOrigin
        var placed: [(y: CGFloat, element: Any)] = []
        for (index, paragraph) in reply.paragraphs.enumerated() {
            if paragraph.hosted == nil, case .heading = paragraph.unit.content, let fragment = fragment(for: index) {
                let element = headings[index] ?? {
                    let element = ReplyHeadingElement(label: paragraph.unit.text, view: self)
                    headings[index] = element
                    return element
                }()
                element.rect = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
                placed.append((element.rect.minY, element))
            }
            if let view = checkboxViews[index] { placed.append((view.frame.minY, view)) }
            if let view = blockViews[index] { placed.append((view.frame.minY, view)) }
        }
        return own + placed.sorted { $0.y < $1.y }.map(\.element)
    }

    // MARK: Selection

    /// How far a press moves before it is a drag: `SwipeToReply`'s, so both decide alike.
    private static let dragDistance: CGFloat = 16

    /// A drag to the left replies to the message, as it does on the words of any other message
    /// (`docs/inbox.md` §4), so a plain press waits for its first move before it selects. The
    /// text's own tracking would keep the drag to itself, so a drag judged to the left goes to the
    /// message's swipe (`ReplySwipe`), as a drag on its other parts does.
    override func mouseDown(with event: NSEvent) {
        // AppKit can hand on a press its gesture recognizers held back after a later one has
        // reached this view, at the held press's own place; one outside the text isn't on it. The
        // test is hit testing's own, so a press on the text's last row or column still counts.
        guard NSMouseInRect(convert(event.locationInWindow, from: nil), bounds, isFlipped) else {
            strayPress = event.locationInWindow
            return
        }
        strayPress = nil
        swiping = nil
        guard event.clickCount == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              environment.values.replySwipe != nil, !reply.scrollsSideways else {
            pendingPress = nil
            return super.mouseDown(with: event)
        }
        pendingPress = event
    }

    override func mouseDragged(with event: NSEvent) {
        if let swiping {
            return swiping.swipe.follow(Self.translation(from: swiping.press, to: event).x)
        }
        guard let press = pendingPress else { return super.mouseDragged(with: event) }
        let translation = Self.translation(from: press, to: event)
        guard hypot(translation.x, translation.y) >= Self.dragDistance else { return }
        pendingPress = nil
        if SidewaysSwipe.begins(velocity: .zero, translation: translation, direction: .left),
           let swipe = environment.values.replySwipe {
            swiping = (press, swipe)
            return swipe.follow(translation.x)
        }
        select(from: press, then: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let stray = strayPress, stray == event.locationInWindow {
            strayPress = nil
            return
        }
        if let swiping {
            self.swiping = nil
            return swiping.swipe.release(Self.translation(from: swiping.press, to: event).x)
        }
        guard let press = pendingPress else { return super.mouseUp(with: event) }
        pendingPress = nil
        select(from: press, then: event)
    }

    /// How far the mouse has moved since the press, down positive, as SwiftUI measures a drag.
    private static func translation(from press: NSEvent, to event: NSEvent) -> CGPoint {
        CGPoint(
            x: event.locationInWindow.x - press.locationInWindow.x,
            y: press.locationInWindow.y - event.locationInWindow.y
        )
    }

    /// The text's own tracking from where the press began, given the event that decided it first.
    private func select(from press: NSEvent, then event: NSEvent) {
        window?.postEvent(event, atStart: true)
        super.mouseDown(with: press)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let selected = ranges.map(\.rangeValue).filter { $0.length > 0 }
        for (index, attachment) in blocks {
            let location = reply.paragraphs[index].range.location
            let isSelected = selected.contains { NSLocationInRange(location, $0) }
            if attachment.state.isSelected != isSelected { attachment.state.isSelected = isSelected }
        }
        watchClicks(!selected.isEmpty)
        publishSelection(stillSelecting: stillSelecting)
    }

    /// Words that can be quoted get Reply beside them once the drag that selects them ends
    /// (`docs/inbox.md` §4).
    private func publishSelection(stillSelecting: Bool) {
        guard let selectionReply = environment.values.selectionReply else { return }
        let text = selectionText
        if QuotedReply.quotes(text) {
            selectionReply.words.select(text, in: self, quote: selectionReply.quote, rests: !stillSelecting)
        } else {
            selectionReply.words.drop(from: self)
        }
    }

    /// The selection's lines and the part of the chat shown, in `canvas`'s space: the chat's
    /// scroll view less its bars and `margin` at each end.
    func selectionLines(in canvas: NSView, margin: CGFloat) -> (lines: QuotedReply.SelectionPlacement, visible: ClosedRange<CGFloat>)? {
        let selection = selectedRange()
        guard selection.length > 0, let scroll = enclosingScrollView,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: selection.location),
              let end = contentStorage.location(start, offsetBy: selection.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        layout.ensureLayout(for: range)
        let origin = textContainerOrigin
        var segments: [CGRect] = []
        layout.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            segments.append(convert(frame.offsetBy(dx: origin.x, dy: origin.y), to: canvas))
            return true
        }
        let column = convert(bounds, to: canvas)
        // The clip runs under the toolbar and the composer, and the overlay stops at them: the
        // bars come off the clip, and whatever is left counts only where the overlay is too.
        let clip = scroll.contentView
        let insets = scroll.contentInsets
        var clipped = clip.convert(clip.bounds, to: canvas)
        clipped.origin.y += insets.top
        clipped.size.height -= insets.top + insets.bottom
        let shown = clipped.intersection(canvas.bounds)
        let top = shown.minY + margin
        let bottom = shown.maxY - margin
        guard top < bottom, let lines = QuotedReply.SelectionPlacement(segments: segments, column: column.minX...column.maxX) else { return nil }
        return (lines, top...bottom)
    }

    /// While something is selected, a click anywhere else in the window clears it, as it does in
    /// any other text.
    private func watchClicks(_ on: Bool) {
        if on, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                // Reply beside the selection takes it, so a click there leaves it.
                let onReply = self.environment.values.selectionReply?.words.isOnButton(event) ?? false
                if !NSMouseInRect(point, self.bounds, self.isFlipped), !onReply { self.setSelectedRange(NSRange(location: 0, length: 0)) }
                return event
            }
        } else if !on, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setSelectedRange(NSRange(location: 0, length: 0)) }
        followScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        followScale()
    }

    /// Lines and blocks snap to the pixels of the screen the reply is on.
    private func followScale() {
        guard let scale = window?.backingScaleFactor, scale != fragments.scale else { return }
        fragments.scale = scale
        layout.invalidateLayout(for: layout.documentRange)
        needsDisplay = true
        placeBlocks()
    }

    /// The text's own menu (Copy, Speech, Services) inside a selection, with Reply first when the
    /// words can be quoted (`docs/inbox.md` §4); anywhere else, the reply's.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let selection = selectedRange()
        guard selection.length > 0, index >= selection.location, index <= NSMaxRange(selection) else { return nil }
        guard let menu = super.menu(for: event) else { return nil }
        Self.disableEditing(in: menu)
        if let words = environment.values.selectionReply?.words, words.canReply {
            // The shortcut is shown, not handled here: Chat → Reply to Selection owns ⇧⌘R.
            let reply = NSMenuItem(title: "Reply", action: #selector(replyToSelection(_:)), keyEquivalent: "r")
            reply.keyEquivalentModifierMask = [.command, .shift]
            reply.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(reply, at: 0)
            // Reply beside the selection steps aside while the menu is open.
            menuWatch.closed = { [weak words] in words?.menuOpened(false) }
            menu.delegate = menuWatch
            words.menuOpened(true)
        }
        return menu
    }

    @objc private func replyToSelection(_ sender: Any?) {
        environment.values.selectionReply?.words.reply()
    }

    /// The reply can't be changed, so the text menu's font, substitution and checking commands
    /// stay listed but off, as they are on SwiftUI's selectable text.
    private static let editingActions: Set<Selector> = [
        #selector(NSFontManager.addFontTrait(_:)),
        #selector(NSTextView.toggleAutomaticDataDetection(_:)),
        #selector(NSTextView.toggleAutomaticLinkDetection(_:)),
        #selector(NSTextView.checkTextInDocument(_:)),
        #selector(NSText.checkSpelling(_:)),
    ]

    private static func disableEditing(in menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { disableEditing(in: submenu) }
        }
        let editing = menu.items.filter { $0.action.map(editingActions.contains) ?? false }
        guard !editing.isEmpty else { return }
        // Validate the rest once, then stop the menu re-enabling what is turned off here.
        menu.update()
        menu.autoenablesItems = false
        for item in editing { item.isEnabled = false }
    }

    // MARK: Plain text

    /// The selection as plain text (`ReplyPlainText.text(_:drawn:hidden:selection:)`).
    func plainText(in range: NSRange) -> String {
        reply.plainText(in: range)
    }

    private var selectionText: String {
        let selection = selectedRange()
        return selection.length > 0 ? plainText(in: selection) : ""
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let text = selectionText
        guard !text.isEmpty else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return false }
        let text = selectionText
        guard !text.isEmpty else { return false }
        return pboard.setString(text, forType: .string)
    }

    /// The text menu's Speech reads the selection, or the whole reply, as its words.
    private static let speaker = NSTextView()

    override func startSpeaking(_ sender: Any?) {
        let text = selectedRange().length > 0 ? selectionText : ReplyPlainText.text(reply.units)
        Self.speaker.string = text
        Self.speaker.startSpeaking(sender)
    }

    override func stopSpeaking(_ sender: Any?) {
        Self.speaker.stopSpeaking(sender)
    }

    // MARK: Links

    override func clicked(onLink link: Any, at charIndex: Int) {
        // Through the chat's gate only: the web and mail open, gateway files open in the Inspector.
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url { environment.values.openURL(url) }
    }

    // MARK: Listen

    /// While Listen reads the reply, the blocks it isn't reading are lighter, and in a paragraph
    /// being read only the sentence is ink (`MarkdownBlockView.lit`).
    func light(_ sentence: SpokenSentence?) {
        guard sentence != spoken, let storage = textStorage else { return }
        spoken = sentence
        reply.light(storage, sentence: sentence)
        for (index, attachment) in blocks {
            let listen = reply.listen(index, sentence: sentence)
            if attachment.state.isDimmed != listen.isDimmed { attachment.state.isDimmed = listen.isDimmed }
            if attachment.state.sentence != listen.read { attachment.state.sentence = listen.read }
        }
        for (index, view) in checkboxViews {
            guard let state = (view as? ReplyCheckboxView)?.state else { continue }
            let isDimmed = reply.listen(index, sentence: sentence).isDimmed
            if state.isDimmed != isDimmed { state.isDimmed = isDimmed }
        }
    }
}

#endif

// MARK: - Shared by the text views

extension ReplyText {
    /// A paragraph's fragment in a layout of this reply's text.
    func fragment(
        for paragraph: Int, in layout: NSTextLayoutManager, content: NSTextContentStorage
    ) -> NSTextLayoutFragment? {
        let offset = paragraphs[paragraph].range.location
        guard let location = content.location(content.documentRange.location, offsetBy: offset) else { return nil }
        return layout.textLayoutFragment(for: location)
    }

    /// Each quote's bar beside its paragraphs, in the view's coordinates (y running down): from
    /// the top of the first (with a heading's space above it) to the last one's last line.
    func barRects(in layout: NSTextLayoutManager, content: NSTextContentStorage, origin: CGPoint) -> [CGRect] {
        guard !bars.isEmpty else { return [] }
        layout.ensureLayout(for: layout.documentRange)
        return bars.compactMap { bar in
            guard let first = fragment(for: bar.paragraphs.lowerBound, in: layout, content: content),
                  let last = fragment(for: bar.paragraphs.upperBound, in: layout, content: content),
                  let lastLine = last.textLineFragments.last else { return nil }
            // The first line's top: TextKit may put the line's spacing above it, inside the fragment.
            let lineTop = first.textLineFragments.first?.typographicBounds.minY ?? 0
            let top = first.layoutFragmentFrame.minY + lineTop - paragraphs[bar.paragraphs.lowerBound].topPad
            let bottom = last.layoutFragmentFrame.minY + lastLine.typographicBounds.maxY
            return CGRect(x: origin.x + bar.x, y: origin.y + top, width: Metrics.quoteBarWidth, height: bottom - top)
        }
    }

    /// The selection as plain text (`ReplyPlainText.text(_:drawn:hidden:selection:)`).
    func plainText(in range: NSRange) -> String {
        ReplyPlainText.text(placed, drawn: storage.string as NSString, hidden: hidden, selection: range)
    }

    /// While Listen reads the reply, the paragraphs it isn't reading are lighter, and in a
    /// paragraph being read only the sentence is ink (`MarkdownBlockView.lit`). `text` is a copy
    /// of this reply's text, with its blocks' attachments.
    func light(_ text: NSTextStorage, sentence: SpokenSentence?) {
        let all = NSRange(location: 0, length: text.length)
        text.beginEditing()
        storage.enumerateAttribute(.foregroundColor, in: all) { value, range, _ in
            if let value { text.addAttribute(.foregroundColor, value: value, range: range) }
        }
        if let sentence {
            for paragraph in paragraphs where paragraph.hosted == nil {
                if paragraph.unit.block != sentence.block {
                    storage.enumerateAttribute(.link, in: paragraph.range) { link, range, _ in
                        if link == nil { text.addAttribute(.foregroundColor, value: Palette.secondary, range: range) }
                    }
                } else if paragraph.unit.levels.isEmpty, case .paragraph = paragraph.unit.content, case .words = sentence.kind {
                    lit(paragraph.range, sentence: sentence, in: text)
                }
            }
        }
        text.endEditing()
    }

    /// How a hosted block or a checklist box looks while Listen reads `sentence`: lighter when
    /// it reads another block, and the sentence it reads in a block of its own (one inside a list
    /// or quote dims only).
    func listen(_ paragraph: Int, sentence: SpokenSentence?) -> (isDimmed: Bool, read: SpokenSentence?) {
        let unit = paragraphs[paragraph].unit
        let isDimmed = sentence.map { $0.block != unit.block } ?? false
        let read = unit.levels.isEmpty && sentence?.block == unit.block ? sentence : nil
        return (isDimmed, read)
    }

    private func lit(_ range: NSRange, sentence: SpokenSentence, in text: NSTextStorage) {
        let drawn = storage.string as NSString
        var plain = ""
        var places: [NSRange] = []
        var index = range.location
        while index < NSMaxRange(range) {
            let character = drawn.rangeOfComposedCharacterSequence(at: index)
            let piece = drawn.substring(with: character)
            if piece != "\u{202F}" {
                plain += piece == "\u{2028}" ? "\n" : piece
                places.append(character)
            }
            index = NSMaxRange(character)
        }
        guard let found = plain.range(of: sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let first = plain.distance(from: plain.startIndex, to: found.lowerBound)
        let last = plain.distance(from: plain.startIndex, to: found.upperBound) - 1
        guard first <= last, last < places.count else { return }
        text.addAttribute(.foregroundColor, value: Palette.secondary, range: range)
        let lit = NSRange(location: places[first].location, length: NSMaxRange(places[last]) - places[first].location)
        text.addAttribute(.foregroundColor, value: Palette.primary, range: lit)
    }
}

// MARK: - Raised lines

/// Hands TextKit a fragment that draws a paragraph's glyphs raised (`replyRaise`), so its baseline
/// sits where SwiftUI's does while its line keeps its place and height, and on whole pixels, as
/// SwiftUI puts a paragraph that follows a block of fractional height.
nonisolated final class ReplyFragments: NSObject, NSTextLayoutManagerDelegate {
    /// The screen's pixels per point, set by the text view.
    var scale: CGFloat = 2

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = ReplyFragment(textElement: textElement, range: textElement.elementRange)
        fragment.scale = scale
        if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           let raise = paragraph.attributedString.attribute(.replyRaise, at: 0, effectiveRange: nil) as? CGFloat {
            fragment.raise = raise
        }
        return fragment
    }
}

nonisolated final class ReplyFragment: NSTextLayoutFragment {
    var raise: CGFloat = 0
    var scale: CGFloat = 2

    /// How far the glyphs move up: the raise, plus what puts the fragment's top on a whole pixel.
    private var lift: CGFloat {
        let top = layoutFragmentFrame.minY
        return raise - ((top * scale).rounded() / scale - top)
    }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        return bounds.union(bounds.offsetBy(dx: 0, dy: -raise - 1)).union(bounds.offsetBy(dx: 0, dy: 1))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let origin = CGPoint(x: point.x, y: point.y - lift)
        drawLinkBackgrounds(at: point, in: context)
        super.draw(at: origin, in: context)
        drawUnderlines(at: origin, in: context)
    }

    /// The boxes behind code that opens a file, from the line's top (which the lift leaves in place)
    /// down its full height, and through the spacing below when another line follows, on whole pixels.
    private func drawLinkBackgrounds(at origin: CGPoint, in context: CGContext) {
        let lines = textLineFragments
        for (index, line) in lines.enumerated() {
            let text = line.attributedString
            text.enumerateAttribute(.replyLinkBackground, in: line.characterRange) { value, run, _ in
                guard let color = value as? ReplyColor, run.length > 0 else { return }
                let bounds = line.typographicBounds
                let style = text.attribute(.paragraphStyle, at: run.location, effectiveRange: nil) as? NSParagraphStyle
                let spacing = index + 1 < lines.count ? style?.lineSpacing ?? 0 : 0
                let lineHeight = style?.minimumLineHeight ?? 0
                let height = (lineHeight > 0 ? lineHeight : bounds.height) + spacing
                let start = line.locationForCharacter(at: run.location).x
                let end = line.locationForCharacter(at: NSMaxRange(run)).x + 0.5
                let box = CGRect(x: origin.x + bounds.minX + start, y: origin.y + bounds.minY,
                                 width: end - start, height: height)
                var device = context.convertToDeviceSpace(box)
                device = CGRect(x: device.minX.rounded(.down), y: device.minY.rounded(),
                                width: device.maxX.rounded(.down) - device.minX.rounded(.down),
                                height: device.maxY.rounded() - device.minY.rounded())
                context.setFillColor(color.cgColor)
                context.fill(context.convertToUserSpace(device))
            }
        }
    }

    /// Underlines and strike lines where SwiftUI draws them, on whole pixels.
    private func drawUnderlines(at origin: CGPoint, in context: CGContext) {
        for line in textLineFragments {
            let text = line.attributedString
            for key in [NSAttributedString.Key.replyUnderline, .replyStrike] {
                text.enumerateAttribute(key, in: line.characterRange) { value, run, _ in
                    guard value != nil, run.length > 0,
                          let font = text.attribute(.font, at: run.location, effectiveRange: nil) as? ReplyFont,
                          let color = text.attribute(.foregroundColor, at: run.location, effectiveRange: nil) as? ReplyColor
                    else { return }
                    let codeLink = text.attribute(.replyLinkBackground, at: run.location, effectiveRange: nil) != nil
                    let start = line.locationForCharacter(at: run.location).x
                    // SwiftUI's line stops a point short of the last character's advance, except
                    // where code that opens a file ends.
                    let closes = codeLink && NSMaxRange(run) < text.length
                        && text.attribute(.replyPadding, at: NSMaxRange(run), effectiveRange: nil) != nil
                    let end = line.locationForCharacter(at: NSMaxRange(run)).x - (closes ? 0 : 1)
                    let bounds = line.typographicBounds
                    let baseline = origin.y + bounds.minY + line.glyphOrigin.y
                    let left = origin.x + bounds.minX + start
                    let thickness = max(1, (font.underlineThickness * scale).rounded(.up)) / scale
                    let drop = text.attribute(.replyDrop, at: run.location, effectiveRange: nil) as? CGFloat ?? 0
                    // Measured at every font a reply uses: an underline's top sits just below SwiftUI's
                    // own baseline, or half a point below the drawn one under code that opens a file.
                    // A strike line is centred half the x-height above the drawn baseline.
                    let top = key == .replyStrike
                        ? baseline - font.xHeight / 2 - thickness / 2
                        : codeLink ? baseline + 0.5 : baseline + drop + 0.1
                    let band = CGRect(x: left, y: top, width: end - start, height: thickness)
                    let gaps = key == .replyStrike ? [] : inkGaps(text.attributedSubstring(from: run), font: font, band: band, baseline: baseline)
                    context.setFillColor(color.cgColor)
                    for piece in pieces(of: band, around: gaps) {
                        var device = context.convertToDeviceSpace(piece)
                        device.origin.y = device.origin.y.rounded()
                        device.size.height = device.size.height.rounded()
                        context.fill(context.convertToUserSpace(device))
                    }
                }
            }
        }
    }

    /// Where descenders cross an underline, widened by its thickness and 0.375 pt more (measured):
    /// SwiftUI leaves those gaps.
    private func inkGaps(_ text: NSAttributedString, font: ReplyFont, band: CGRect, baseline: CGFloat) -> [ClosedRange<CGFloat>] {
        let clearance = font.underlineThickness + 0.375
        // The band in a glyph's own space: y up from the baseline.
        let slab = CGRect(x: -1_000, y: baseline - band.maxY, width: 100_000, height: band.height)
        var gaps: [ClosedRange<CGFloat>] = []
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font as CTFont, glyph, nil) else { continue }
                let ink = path.intersection(CGPath(rect: slab, transform: nil)).boundingBoxOfPath
                guard !ink.isNull, ink.width > 0 else { continue }
                gaps.append((band.minX + position.x + ink.minX - clearance)...(band.minX + position.x + ink.maxX + clearance))
            }
        }
        return gaps
    }

    /// The band with the gaps cut out.
    private func pieces(of band: CGRect, around gaps: [ClosedRange<CGFloat>]) -> [CGRect] {
        var pieces: [CGRect] = []
        var x = band.minX
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) where gap.upperBound > x {
            if gap.lowerBound > x { pieces.append(CGRect(x: x, y: band.minY, width: min(gap.lowerBound, band.maxX) - x, height: band.height)) }
            x = gap.upperBound
        }
        if x < band.maxX { pieces.append(CGRect(x: x, y: band.minY, width: band.maxX - x, height: band.height)) }
        return pieces.filter { $0.width > 0 }
    }
}

#if !os(macOS)
extension UIFont {
    /// The font's own underline thickness, which AppKit's `NSFont` has as a property.
    nonisolated var underlineThickness: CGFloat { CTFontGetUnderlineThickness(self as CTFont) }
}
#endif

// MARK: - Measuring

/// A reply's text laid out in a container of any width, with no view: how tall it is there, and
/// how wide its longest line.
final class ReplyMeasure {
    private let storage = NSTextContentStorage()
    private let layout = NSTextLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    /// Called once the text is laid out at a new width, to adjust it as its view does.
    var laidOut: ((NSTextLayoutManager, NSTextContentStorage) -> Void)?

    init() {
        container.lineFragmentPadding = 0
        layout.usesFontLeading = ReplyText.drawsLeading
        layout.textContainer = container
        storage.addTextLayoutManager(layout)
    }

    func load(_ text: NSAttributedString) {
        storage.textStorage?.setAttributedString(text)
        container.size.width = 0
    }

    /// Lays the text out again at the next question: a block in it changed its height.
    func invalidate() {
        container.size.width = 0
    }

    func height(for width: CGFloat) -> CGFloat {
        layOut(width: width)
        var bottom: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let last = fragment.textLineFragments.last {
                bottom = max(bottom, fragment.layoutFragmentFrame.minY + last.typographicBounds.maxY)
            }
            return true
        }
        return bottom
    }

    /// The longest line of words. A block is as wide as the container it's in, so its line doesn't count.
    func idealWidth() -> CGFloat {
        layOut(width: 100_000)
        var widest: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
               paragraph.attributedString.attribute(.replyBlock, at: 0, effectiveRange: nil) != nil {
                return true
            }
            for line in fragment.textLineFragments {
                widest = max(widest, fragment.layoutFragmentFrame.minX + line.typographicBounds.maxX)
            }
            return true
        }
        return widest
    }

    private func layOut(width: CGFloat) {
        guard container.size.width != width else { return }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        // TextKit 2 keeps its lines when only the container changes: lay them out again.
        layout.invalidateLayout(for: layout.documentRange)
        layout.ensureLayout(for: layout.documentRange)
        laidOut?(layout, storage)
    }
}

// MARK: - Blocks inside the text

/// What a hosted block shows: whether it's in the selection, lighter while Listen reads another
/// block, or the sentence Listen is reading in it.
@Observable
final class ReplyBlockState {
    var isSelected = false
    var isDimmed = false
    var isQuoted = false
    var sentence: SpokenSentence?
}

/// Where the reply sits, for the views it hosts: the chat's environment, its link gate included,
/// so a hosted block opens links, names Bots and loads images as the views around it do.
@Observable
final class ReplyEnvironment {
    /// Kept current on every update of the reply, without redrawing anything: the text reads its
    /// link gate and swipe from here when it's used.
    @ObservationIgnored var values = EnvironmentValues() {
        didSet {
            let look = Look(values)
            if look != self.look { self.look = look }
        }
    }

    /// What the hosted views draw from. Only a change here redraws them: the chat updates the
    /// reply far more often than any of this changes, and redrawing every hosted block each time
    /// slowed the scroll.
    private var look = Look(EnvironmentValues())

    /// The environment for a hosted view's body, which redraws it when its look changes.
    var current: EnvironmentValues {
        _ = look
        return values
    }

    private struct Look: Equatable {
        let colorScheme: ColorScheme
        let contrast: ColorSchemeContrast
        let typeSize: DynamicTypeSize
        let legibility: LegibilityWeight?
        let reducesMotion: Bool
        let pausesMotion: Bool
        let scale: CGFloat
        let direction: LayoutDirection
        let locale: Locale
        let references: ReferenceContext
        let gatewayHosts: Set<String>
        let widgetHost: ObjectIdentifier?

        init(_ values: EnvironmentValues) {
            colorScheme = values.colorScheme
            contrast = values.colorSchemeContrast
            typeSize = values.dynamicTypeSize
            legibility = values.legibilityWeight
            reducesMotion = values.accessibilityReduceMotion
            pausesMotion = values.pausesDecorativeMotion
            scale = values.displayScale
            direction = values.layoutDirection
            locale = values.locale
            references = values.references
            gatewayHosts = values.gatewayHosts
            widgetHost = values.widgetHost.map(ObjectIdentifier.init)
        }
    }
}

/// The text view a reply's blocks sit in, which sizes them by their own views.
protocol ReplyBlockOwner: AnyObject {
    func blockHeight(_ attachment: ReplyBlockAttachment, width: CGFloat) -> CGFloat
}

/// A paragraph drawn by its own view (a code block, table, rule, lone image, or a list item the
/// text can't draw): one character wide, as tall as its view.
nonisolated final class ReplyBlockAttachment: NSTextAttachment {
    /// Its paragraph in `ReplyText.paragraphs`.
    let paragraph: Int
    let block: MarkdownBlock
    let indent: CGFloat
    let state: ReplyBlockState
    nonisolated(unsafe) private weak var owner: (any ReplyBlockOwner)?

    @MainActor
    init(paragraph: Int, block: MarkdownBlock, indent: CGFloat, owner: any ReplyBlockOwner) {
        self.paragraph = paragraph
        self.block = block
        self.indent = indent
        self.state = ReplyBlockState()
        self.owner = owner
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    func bounds(in container: NSTextContainer?, proposed: CGRect) -> CGRect {
        let width = max(0, (container?.size.width ?? proposed.width) - indent)
        let height = owner?.blockHeight(self, width: width) ?? 0
        // Below the baseline by the line font's descent, so the line is exactly as tall as the block.
        return CGRect(x: 0, y: ReplyText.Metrics.attachmentFont.descender, width: width, height: height)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        // TextKit asks on the main thread: the view lays its text out there.
        nonisolated(unsafe) let attachment = self, container = textContainer
        return MainActor.assumeIsolated { attachment.bounds(in: container, proposed: proposedLineFragment) }
    }

    // The text view puts the block's own view over this space: the text draws nothing here.
    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> ReplyImage? {
        #if os(macOS)
        NSImage(size: bounds.size)
        #else
        UIImage()
        #endif
    }
}

/// The block's own SwiftUI view, as `MarkdownBlocksView` draws it, with the selection over it.
struct ReplyBlockHost: View {
    let block: MarkdownBlock
    let state: ReplyBlockState
    let environment: ReplyEnvironment
    let font: Font
    /// Told when the view's height changes where it's shown.
    let resized: ((CGFloat) -> Void)?

    var body: some View {
        MarkdownBlockView(block: block, sentence: state.sentence)
            .equatable()
            .foregroundStyle(state.isQuoted || state.isDimmed ? Theme.secondaryText : Theme.primaryText)
            #if os(macOS)
            .textSelection(.enabled)
            #endif
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resized?($0) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if state.isSelected {
                    shape.fill(Self.selectionColor)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.markdownBodyFont, font)
            .environment(\.markdownCaches, true)
            // The chat's environment around the reply's own settings, so those win.
            .environment(\.self, environment.current)
    }

    /// The selection's color over a block, as the text's own selection looks around it.
    #if os(macOS)
    private static var selectionColor: Color { Color(nsColor: .selectedTextBackgroundColor).opacity(0.45) }
    #else
    private static var selectionColor: Color { Color.accentColor.opacity(0.2) }
    #endif

    private var shape: some Shape {
        let radius: CGFloat = switch block {
        case .codeBlock: Theme.Radius.code
        case .table: 12
        case .paragraph: 16
        default: 0
        }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// A checklist item's box, drawn as the list row draws it: the text beside it is the reply's own.
struct ReplyCheckbox: View {
    let isChecked: Bool
    let state: ReplyBlockState
    let environment: ReplyEnvironment
    let font: Font

    var body: some View {
        MarkdownBlockView(block: .list(MarkdownList(
            isOrdered: false, startIndex: 1,
            items: [MarkdownListItem(isChecked: isChecked, blocks: [.paragraph([.text(" ")])])])))
            .foregroundStyle(state.isQuoted || state.isDimmed ? Theme.secondaryText : Theme.primaryText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isChecked ? "Done" : "Not done")
            // From the top-left, as the row lays it out: a hosting view centers what's smaller.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.markdownBodyFont, font)
            .environment(\.markdownCaches, true)
            .environment(\.self, environment.current)
    }
}

#if os(macOS)
/// A checklist item's box over the text: clicks and drags go through it to the text.
final class ReplyCheckboxView: NSHostingView<ReplyCheckbox> {
    var state: ReplyBlockState?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A heading in the reply's text, for VoiceOver's heading navigation.
nonisolated final class ReplyHeadingElement: NSAccessibilityElement {
    nonisolated(unsafe) private weak var view: NSView?
    /// Where it is in the view.
    nonisolated(unsafe) var rect: NSRect = .zero

    @MainActor
    init(label: String, view: NSView) {
        self.view = view
        super.init()
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        setAccessibilityLabel(label)
        setAccessibilityParent(view)
    }

    override func accessibilityFrame() -> NSRect {
        // Accessibility asks on the main thread.
        let view = view, rect = rect
        return MainActor.assumeIsolated {
            guard let view, let window = view.window else { return .zero }
            return window.convertToScreen(view.convert(rect, to: nil))
        }
    }

    override func isAccessibilityElement() -> Bool { true }
}

// MARK: - Reply to selected words

/// How a finished reply's words reach Reply beside them (`selectionReplyButton`, `docs/inbox.md`
/// §4): the chat's selected words, and the reply's own way to quote a passage of itself.
struct SelectionReply {
    let words: SelectedReplyWords
    let quote: @MainActor (String) -> Void
}

extension EnvironmentValues {
    @Entry var selectionReply: SelectionReply? = nil
    /// The chat's selected words, for its replies to publish theirs to.
    @Entry var selectedReplyWords: SelectedReplyWords? = nil
}

/// Words selected in one of a chat's finished replies (`docs/inbox.md` §4): what Reply beside
/// them and Chat → Reply to Selection quote, and where Reply floats.
@Observable
final class SelectedReplyWords {
    /// Words that can be quoted are selected.
    private(set) var canReply = false
    /// The drag that selects them is over.
    private(set) var rests = false
    /// The selection's first and last lines, and the part of the chat Reply may sit in, in the
    /// overlay's space.
    private(set) var lines: QuotedReply.SelectionPlacement?
    private(set) var visible: ClosedRange<CGFloat>?
    /// Reply's own size, as it draws.
    var buttonSize = CGSize(width: 76, height: 28)
    /// The selection's menu is open.
    private(set) var menuOpen = false
    /// Counts Reply to Selection, so the composer takes the cursor every time, even when the
    /// same words of the same message are quoted again and the quote itself doesn't change.
    private(set) var replies = 0
    /// The chat is scrolling, or a reply is streaming: Reply steps aside until it settles.
    var scrolling = false { didSet { if scrolling != oldValue, !scrolling { relocate() } } }
    var streaming = false { didSet { if streaming != oldValue, !streaming { relocate() } } }

    @ObservationIgnored private weak var owner: ReplyNSTextView?
    @ObservationIgnored private var quote: (@MainActor (String) -> Void)?
    @ObservationIgnored private var passage = ""
    /// The overlay Reply floats in, flipped, over the whole chat.
    @ObservationIgnored weak var canvas: NSView?
    @ObservationIgnored private var scrollWatch: (any NSObjectProtocol)?
    @ObservationIgnored private var relocating = false

    /// The chat is far enough back that the soft edges fade the words: Reply keeps clear of them.
    static let fadeMargin: CGFloat = 16

    /// Where Reply is drawn, in the overlay's space, while it shows.
    var buttonFrame: CGRect? {
        guard canReply, rests, !menuOpen, !scrolling, !streaming, let lines, let visible,
              let origin = lines.origin(for: buttonSize, visible: visible) else { return nil }
        return CGRect(origin: origin, size: buttonSize)
    }

    /// Reply to Selection: quotes the selected words into the composer and clears the selection.
    func reply() {
        guard canReply, let owner, let quote else { return }
        let passage = self.passage
        owner.setSelectedRange(NSRange(location: 0, length: 0))
        quote(passage)
        replies += 1
    }

    /// A click on Reply itself, which mustn't clear the selection before Reply takes it.
    func isOnButton(_ event: NSEvent) -> Bool {
        guard let frame = buttonFrame, let canvas, event.window === canvas.window else { return false }
        return frame.contains(canvas.convert(event.locationInWindow, from: nil))
    }

    // MARK: From the reply

    func select(_ passage: String, in owner: ReplyNSTextView, quote: @escaping @MainActor (String) -> Void, rests: Bool) {
        if self.owner !== owner {
            self.owner?.setSelectedRange(NSRange(location: 0, length: 0))
            self.owner = owner
            watchScrolling(owner.enclosingScrollView?.contentView)
        }
        self.passage = passage
        self.quote = quote
        if !canReply { canReply = true }
        if self.rests != rests { self.rests = rests }
        if rests { relocate() }
    }

    func drop(from owner: ReplyNSTextView) {
        guard self.owner === owner else { return }
        self.owner = nil
        quote = nil
        passage = ""
        watchScrolling(nil)
        canReply = false
        rests = false
        lines = nil
        visible = nil
    }

    func menuOpened(_ open: Bool) {
        if menuOpen != open { menuOpen = open }
    }

    /// Follows the words after the chat moved or the window changed, once its layout is done.
    func relocate() {
        guard canReply, !relocating else { return }
        relocating = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            relocating = false
            place()
        }
    }

    private func place() {
        guard canReply, !scrolling, let owner, let canvas,
              let found = owner.selectionLines(in: canvas, margin: Self.fadeMargin) else {
            if lines != nil { lines = nil }
            return
        }
        if lines != found.lines { lines = found.lines }
        if visible != found.visible { visible = found.visible }
    }

    /// The chat moving under the selection (the end of a scroll, a reply settling at the bottom).
    private func watchScrolling(_ clip: NSClipView?) {
        if let scrollWatch { NotificationCenter.default.removeObserver(scrollWatch) }
        scrollWatch = clip.map { clip in
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.scrolling else { return }
                    self.relocate()
                }
            }
        }
    }
}

/// Reply beside words selected in a finished reply (`selectionReplyButton`), over the chat.
struct SelectionReplyOverlay: View {
    let words: SelectedReplyWords
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where Reply last showed, so it fades out where it was.
    @State private var lastOrigin = CGPoint.zero

    var body: some View {
        let frame = words.buttonFrame
        let origin = frame?.origin ?? lastOrigin
        ZStack(alignment: .topLeading) {
            SelectionCanvas(words: words)
            Button { words.reply() } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .glassButton()
            .help("Reply (⇧⌘R)")
            .accessibilityHint("Quotes the selected words in your reply")
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { words.buttonSize = $0 }
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(frame != nil)
            .accessibilityHidden(frame == nil)
            // Only the tone eases: Reply never slides from where it was.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15)) { $0.opacity(frame == nil ? 0 : 1) }
        }
        .onChange(of: frame?.origin) { _, origin in
            if let origin { lastOrigin = origin }
        }
    }
}

/// The overlay's own space, for the selection's lines to be measured in.
private struct SelectionCanvas: NSViewRepresentable {
    let words: SelectedReplyWords

    func makeNSView(context: Context) -> Canvas {
        let view = Canvas()
        view.words = words
        words.canvas = view
        return view
    }

    func updateNSView(_ view: Canvas, context: Context) {
        view.words = words
        words.canvas = view
    }

    final class Canvas: NSView {
        weak var words: SelectedReplyWords?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            words?.relocate()
        }
    }
}

/// Watches the selection's menu, so Reply steps aside while it is open.
private final class SelectionMenuWatch: NSObject, NSMenuDelegate {
    var closed: () -> Void = {}
    func menuDidClose(_ menu: NSMenu) { closed() }
}
#endif
