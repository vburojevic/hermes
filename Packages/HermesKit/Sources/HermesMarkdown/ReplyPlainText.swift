import Foundation

/// A reply as the lines it is drawn in and the plain text it copies as (`docs/chat.md` §3).
///
/// On the Mac a finished reply is one selectable text: each unit here is one of its paragraphs,
/// in order, so a selection reads back as plain text, and the paragraphs can be drawn from the
/// same walk. Blocks are separated by a blank line, list items by a line break, with their
/// markers; a table is its rows with tab-separated cells, a code block its code.
public enum ReplyPlainText {
    /// One paragraph of a reply.
    public struct Unit: Hashable, Sendable {
        public enum Content: Hashable, Sendable {
            case paragraph([MarkdownInline])
            case heading(level: Int, content: [MarkdownInline])
            case html(String)
            /// Drawn whole and copied whole: a code block, a table, a rule, a lone image, a list
            /// item that starts with a quote (one list of its own), or a quote or list with an empty
            /// fence inside it.
            case block(MarkdownBlock)
            /// A list item with nothing in it: only its marker.
            case empty
        }

        /// What the unit sits in, outermost first.
        public enum Level: Hashable, Sendable {
            /// A block quote, by its order in the reply, so the units of one quote share its bar.
            case quote(Int)
            case item(Marker)
        }

        public enum Marker: Hashable, Sendable {
            case bullet
            case number(Int)
            case checkbox(Bool)

            public var plainText: String {
                switch self {
                case .bullet: "•"
                case .number(let number): "\(number)."
                case .checkbox(let checked): checked ? "☑" : "☐"
                }
            }
        }

        /// The space drawn above it: none for the first, a list's between its items, a block's
        /// between blocks.
        public enum Gap: Hashable, Sendable { case none, item, block }

        public var content: Content
        /// The top-level block it belongs to (`MarkdownDocument.blocks`, `SpokenSentence.block`).
        public var block: Int
        public var levels: [Level]
        /// The levels, by index into `levels`, whose list item starts here and draws its marker.
        public var markers: [Int]
        public var gap: Gap
        /// What comes before it in plain text: nothing for the first, a line break inside a list, a
        /// blank line between blocks.
        public var separator: String
        /// Its markers (or a list's indent) in plain text, before `text`.
        public var prefix: String
        /// Its words in plain text.
        public var text: String
        /// The empty fences between it and the paragraph before it, at the top of the reply. Each
        /// draws nothing but keeps its place among the blocks, so a block's space more above it.
        public var blanks = 0

        /// Copied whole, never in part.
        public var isWhole: Bool {
            if case .block = content { true } else { false }
        }
    }

    /// The paragraphs of a reply, in order. A fence with nothing in it has none: it is counted in
    /// the `blanks` of the paragraph after it, or in `trailingBlanks(_:)`.
    public static func units(_ blocks: [MarkdownBlock]) -> [Unit] {
        var walk = Walk()
        var blanks = 0
        for (index, block) in blocks.enumerated() {
            guard !isBlank(block) else {
                blanks += 1
                continue
            }
            walk.top = index
            let first = walk.units.count
            if containsBlank(block) {
                // An empty fence inside a quote or a list keeps a gap only that block's own view
                // draws exactly, so the block is drawn whole.
                var inner = Walk()
                inner.top = index
                inner.quotes = walk.quotes
                inner.add(block, levels: [], markers: [], gap: .none, separator: "")
                walk.quotes = inner.quotes
                walk.units.append(Unit(
                    content: .block(block), block: index, levels: [], markers: [], gap: first == 0 ? .none : .block,
                    separator: first == 0 ? "" : "\n\n", prefix: "", text: text(inner.units)))
            } else {
                walk.add(block, levels: [], markers: [], gap: first == 0 ? .none : .block, separator: first == 0 ? "" : "\n\n")
            }
            if walk.units.count > first {
                walk.units[first].blanks = blanks
                blanks = 0
            }
        }
        return walk.units
    }

    /// The empty fences that end a reply after its last paragraph: each keeps a block's space
    /// below it.
    public static func trailingBlanks(_ blocks: [MarkdownBlock]) -> Int {
        guard blocks.contains(where: { !isBlank($0) }) else { return 0 }
        return blocks.reversed().prefix(while: isBlank).count
    }

    /// The whole reply in plain text.
    public static func text(_ blocks: [MarkdownBlock]) -> String {
        text(units(blocks))
    }

    /// These units in plain text, as `units(_:)` separates them.
    public static func text(_ units: some Sequence<Unit>) -> String {
        var result = ""
        for unit in units {
            let words = unit.prefix + unit.text
            // A rule has no words: it adds no blank line of its own.
            guard !words.isEmpty || !unit.isWhole else { continue }
            if !result.isEmpty { result += unit.separator }
            result += words
        }
        return result
    }

    /// A paragraph where it is drawn in a reply's text (`ReplyText` on the Mac).
    public struct Placed: Sendable {
        public var unit: Unit
        /// Its characters in the drawn text, without the line break that ends it.
        public var range: NSRange
        /// Where its own words start, after a list item's markers.
        public var content: Int
        /// Drawn as one character and copied whole, never in part.
        public var isWhole: Bool

        public init(unit: Unit, range: NSRange, content: Int, isWhole: Bool) {
            self.unit = unit
            self.range = range
            self.content = content
            self.isWhole = isWhole
        }
    }

    /// The block a paragraph's own view draws inside the Mac's reply text (`ReplyText`), or nil
    /// when the text draws it as the block views do: a paragraph, heading or html with at most
    /// one marker, the one of the item it opens. `names` says its words name a Bot or a file,
    /// which are drawn as pills.
    public static func hosted(_ unit: Unit, names: Bool) -> MarkdownBlock? {
        let isInItem = unit.levels.contains { if case .item = $0 { true } else { false } }
        let drawn: MarkdownBlock?
        var hosts: Bool
        switch unit.content {
        case .block(let block):
            drawn = block
            hosts = true
        case .empty:
            drawn = nil
            hosts = true
        case .paragraph(let inlines):
            // A tab in the words would land on a list's tab stops.
            drawn = .paragraph(inlines)
            hosts = names || unit.text.contains("\t")
        case .heading(let level, let inlines):
            drawn = .heading(level: level, content: inlines)
            hosts = unit.text.contains("\t")
        case .html(let raw):
            // In a list item, html sits beside the marker on the code font's own baseline.
            drawn = .html(raw)
            hosts = isInItem || raw.contains("\t")
        }
        if let first = unit.markers.first {
            if unit.markers.count > 1 || first != unit.levels.count - 1 {
                hosts = true
            } else if case .paragraph = unit.content {
            } else {
                hosts = true
            }
        }
        guard hosts else { return nil }
        // The items it opens, innermost first, each a list of one.
        var blocks = drawn.map { [$0] } ?? []
        for level in unit.markers.reversed() {
            guard case .item(let marker) = unit.levels[level] else { continue }
            let (isOrdered, start, checked): (Bool, Int, Bool?) = switch marker {
            case .bullet: (false, 1, nil)
            case .number(let number): (true, number, nil)
            case .checkbox(let isChecked): (false, 1, isChecked)
            }
            blocks = [.list(MarkdownList(
                isOrdered: isOrdered, startIndex: start, items: [MarkdownListItem(isChecked: checked, blocks: blocks)]))]
        }
        return blocks.first ?? .paragraph([])
    }

    /// Whether a block holds a code block or a table, which scroll sideways.
    public static func scrollsSideways(_ block: MarkdownBlock) -> Bool {
        switch block {
        // A diagram or formula fits the reply's width; its code, when it can't be drawn, wraps.
        case .codeBlock: DrawnBlock(block) == nil
        case .table: true
        case .blockQuote(let blocks): blocks.contains(where: scrollsSideways)
        case .list(let list): list.items.contains { $0.blocks.contains(where: scrollsSideways) }
        case .paragraph, .heading, .thematicBreak, .html: false
        }
    }

    /// A selection in the drawn text as plain text: whole paragraphs as `text(_:)` writes them, a
    /// paragraph in part as its selected words (without the `hidden` characters, which are drawn
    /// and never copied), with its markers only when the selection starts at its start.
    public static func text(_ placed: [Placed], drawn: NSString, hidden: IndexSet, selection: NSRange) -> String {
        var picked: [Unit] = []
        for paragraph in placed {
            let overlap = NSIntersectionRange(selection, paragraph.range)
            guard overlap.length > 0 else { continue }
            var unit = paragraph.unit
            if !paragraph.isWhole, overlap != paragraph.range {
                let start = max(overlap.location, paragraph.content)
                var words = ""
                if start < NSMaxRange(overlap) {
                    for part in IndexSet(integersIn: start..<NSMaxRange(overlap)).subtracting(hidden).rangeView {
                        words += drawn.substring(with: NSRange(location: part.lowerBound, length: part.count))
                    }
                }
                unit.text = words.replacingOccurrences(of: "\u{2028}", with: "\n")
                if overlap.location > paragraph.range.location { unit.prefix = "" }
            }
            picked.append(unit)
        }
        return text(picked)
    }

    /// A table as rows of tab-separated cells.
    public static func text(_ table: MarkdownTable) -> String {
        ([table.header] + table.rows)
            .map { row in row.map { $0.map(\.plainText).joined() }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private struct Walk {
        var units: [Unit] = []
        var top = 0
        var quotes = 0

        mutating func add(_ block: MarkdownBlock, levels: [Unit.Level], markers: [Int], gap: Unit.Gap, separator: String) {
            func unit(_ content: Unit.Content, _ text: String) {
                units.append(Unit(
                    content: content, block: top, levels: levels, markers: markers, gap: gap,
                    separator: separator, prefix: ReplyPlainText.prefix(levels: levels, markers: markers), text: text))
            }
            switch block {
            case .paragraph(let inlines):
                // A link drawn as a card (`LinkEmbed`) is one too, but not in a list or a quote.
                if Self.isLoneImage(inlines) || DrawnBlock(block) != nil || (levels.isEmpty && LinkEmbed(inlines) != nil) {
                    unit(.block(block), inlines.map(\.plainText).joined().trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    unit(.paragraph(inlines), inlines.map(\.plainText).joined())
                }
            case .heading(let level, let inlines):
                unit(.heading(level: level, content: inlines), inlines.map(\.plainText).joined())
            case .html(let raw) where DrawnBlock(block) != nil:
                // An SVG drawn as a picture is a block of its own, copied as its markup.
                unit(.block(block), raw)
            case .html(let raw):
                unit(.html(raw), raw)
            case .codeBlock(_, let code):
                unit(.block(block), code)
            case .table(let table):
                unit(.block(block), ReplyPlainText.text(table))
            case .thematicBreak:
                unit(.block(block), "")
            case .blockQuote(let children):
                quotes += 1
                let inner = levels + [.quote(quotes)]
                let between = levels.contains { if case .item = $0 { true } else { false } } ? "\n" : "\n\n"
                for (index, child) in children.filter({ !isBlank($0) }).enumerated() {
                    add(child, levels: inner, markers: index == 0 ? markers : [], gap: index == 0 ? gap : .block,
                        separator: index == 0 ? separator : between)
                }
            case .list(let list):
                for (index, item) in list.items.enumerated() {
                    let marker: Unit.Marker = if let checked = item.isChecked {
                        .checkbox(checked)
                    } else if list.isOrdered {
                        .number(list.startIndex + index)
                    } else {
                        .bullet
                    }
                    let inner = levels + [.item(marker)]
                    let outer = index == 0 ? markers : []
                    let opens = outer + [levels.count]
                    let itemGap: Unit.Gap = index == 0 ? gap : .item
                    let itemSeparator = index == 0 ? separator : "\n"
                    let blocks = item.blocks.filter { !isBlank($0) }
                    if blocks.isEmpty {
                        units.append(Unit(
                            content: .empty, block: top, levels: inner, markers: opens, gap: itemGap, separator: itemSeparator,
                            prefix: ReplyPlainText.prefix(levels: inner, markers: opens), text: ""))
                    } else if case .blockQuote = blocks[0] {
                        // A quote beside a marker is drawn whole: the item is one list of its own.
                        var walk = Walk()
                        walk.top = top
                        walk.quotes = quotes
                        for (offset, child) in blocks.enumerated() {
                            walk.add(child, levels: inner, markers: offset == 0 ? opens : [], gap: offset == 0 ? .none : .block,
                                     separator: offset == 0 ? "" : "\n")
                        }
                        quotes = walk.quotes
                        let single = MarkdownList(
                            isOrdered: list.isOrdered, startIndex: list.startIndex + index,
                            items: [MarkdownListItem(isChecked: item.isChecked, blocks: blocks)])
                        units.append(Unit(
                            content: .block(.list(single)), block: top, levels: levels, markers: outer, gap: itemGap,
                            separator: itemSeparator, prefix: "", text: ReplyPlainText.text(walk.units)))
                    } else {
                        for (offset, child) in blocks.enumerated() {
                            add(child, levels: inner, markers: offset == 0 ? opens : [], gap: offset == 0 ? itemGap : .block,
                                separator: offset == 0 ? itemSeparator : "\n")
                        }
                    }
                }
            }
        }

        /// A paragraph that is nothing but one image draws the image itself.
        static func isLoneImage(_ inlines: [MarkdownInline]) -> Bool {
            let meaningful = inlines.filter {
                switch $0 {
                case .softBreak, .lineBreak: false
                case .text(let text): !text.trimmingCharacters(in: .whitespaces).isEmpty
                default: true
                }
            }
            guard meaningful.count == 1, case .image(.some, _) = meaningful[0] else { return false }
            return true
        }
    }

    /// A fenced block with nothing in it: the views draw nothing for it, but its empty view still
    /// takes a place in the blocks' stack, with the stack's spacing around it.
    static func isBlank(_ block: MarkdownBlock) -> Bool {
        if case .codeBlock(_, let code) = block { code.allSatisfy(\.isWhitespace) } else { false }
    }

    /// A quote or list with an empty fence somewhere inside it.
    static func containsBlank(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .blockQuote(let children): children.contains { isBlank($0) || containsBlank($0) }
        case .list(let list): list.items.contains { $0.blocks.contains { isBlank($0) || containsBlank($0) } }
        default: false
        }
    }

    /// A tab for each list the unit is nested in, then the markers that start on it: `\t• ` for
    /// a nested bullet, `\t` for an item's second paragraph.
    static func prefix(levels: [Unit.Level], markers: [Int]) -> String {
        let items = levels.indices.filter { if case .item = levels[$0] { true } else { false } }
        guard !items.isEmpty else { return "" }
        guard let first = markers.first else { return String(repeating: "\t", count: items.count) }
        let depth = items.filter { $0 < first }.count
        let marks = markers.compactMap { index -> String? in
            if case .item(let marker) = levels[index] { marker.plainText } else { nil }
        }
        return String(repeating: "\t", count: depth) + marks.joined(separator: " ") + " "
    }
}
