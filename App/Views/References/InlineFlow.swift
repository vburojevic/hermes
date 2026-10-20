import HermesKit
import SwiftUI

/// The attribute that marks a Bot or file inside an attributed reply.
enum MessageReferenceAttribute: AttributedStringKey {
    typealias Value = MessageReference
    static let name = "hermes.reference"
}

/// Text with pills where they were typed (`inlineFlow`, `richBubbleRefs`,
/// `Groups.memberMessageMentions`): words wrap as units, a pill stays with the punctuation
/// that touches it, and the line holding a pill grows a few points. Tapping a pill (hovering
/// on the Mac) previews it.
struct InlineFlow: View {
    enum Piece: Hashable {
        case text(AttributedString)
        case reference(MessageReference)
    }

    fileprivate enum Unit {
        case word(AttributedString)
        case pill(Int, MessageReference, leading: AttributedString?, trailing: AttributedString?)
        case lineBreak
    }

    private let units: [Unit]
    private let pills: [MessageReference]
    private let plain: [Piece]
    var font: Font = Theme.Typography.message
    var lineSpacing: CGFloat = Theme.Typography.messageLineSpacing
    var size: PillSize = .message

    @Environment(\.references) private var references
    @State private var previewing: Int?
    #if os(macOS)
    @State private var hoverTask: Task<Void, Never>?
    #endif

    init(pieces: [Piece], font: Font = Theme.Typography.message, lineSpacing: CGFloat = Theme.Typography.messageLineSpacing, size: PillSize = .message) {
        (units, pills) = Self.units(from: pieces)
        plain = pieces
        self.font = font
        self.lineSpacing = lineSpacing
        self.size = size
    }

    /// A message's body.
    init(parts: MessageParts, font: Font = Theme.Typography.message, lineSpacing: CGFloat = Theme.Typography.messageLineSpacing, size: PillSize = .message) {
        self.init(pieces: parts.segments.map {
            switch $0 {
            case .text(let text): .text(AttributedString(text))
            case .reference(let reference): .reference(reference)
            }
        }, font: font, lineSpacing: lineSpacing, size: size)
    }

    /// An attributed reply whose references carry ``MessageReferenceAttribute``.
    init(attributed: AttributedString, font: Font, lineSpacing: CGFloat = Theme.Typography.messageLineSpacing, size: PillSize = .message) {
        var pieces: [Piece] = []
        for run in attributed.runs {
            if let reference = run[MessageReferenceAttribute.self] {
                if case .reference(reference)? = pieces.last { continue }
                pieces.append(.reference(reference))
            } else {
                let text = AttributedString(attributed[run.range])
                if case .text(let previous)? = pieces.last {
                    pieces[pieces.count - 1] = .text(previous + text)
                } else {
                    pieces.append(.text(text))
                }
            }
        }
        self.init(pieces: pieces, font: font, lineSpacing: lineSpacing, size: size)
    }

    var body: some View {
        InlineFlowLayout(wordGap: 4, lineGap: lineSpacing + 1) {
            ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                switch unit {
                case .word(let word):
                    Text(word)
                case .lineBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: FlowLineBreak.self, value: true)
                case .pill(let index, let reference, let leading, let trailing):
                    HStack(spacing: 0) {
                        if let leading { Text(leading) }
                        pill(reference, index: index)
                        if let trailing { Text(trailing) }
                    }
                }
            }
        }
        .font(font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spokenText))
        .accessibilityActions {
            ForEach(Array(pills.enumerated()), id: \.offset) { index, reference in
                Button(String(localized: "Preview \(title(of: reference))")) { previewing = index }
            }
        }
    }

    private func pill(_ reference: MessageReference, index: Int) -> some View {
        ReferencePillView(reference: reference, size: size)
            .contentShape(Capsule())
            .onTapGesture { previewing = index }
            #if os(macOS)
            .onHover { inside in
                hoverTask?.cancel()
                guard inside else { return }
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    previewing = index
                }
            }
            #endif
            .popover(isPresented: Binding(get: { previewing == index }, set: { if !$0 { previewing = nil } })) {
                ReferencePreviewCard(item: .reference(reference), onRemove: nil) { previewing = nil }
                    .environment(\.references, references)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func title(of reference: MessageReference) -> String {
        reference.kind == .bot ? references.bot(handle: reference.value)?.title ?? "@" + reference.value : GatewayFile(path: reference.value).name
    }

    private var spokenText: String {
        plain.map {
            switch $0 {
            case .text(let text): String(text.characters)
            case .reference(let reference): reference.spokenLabel(bot: reference.kind == .bot ? references.bot(handle: reference.value) : nil)
            }
        }
        .joined()
    }

    // MARK: Units

    private enum Token {
        case word(AttributedString)
        case space
        case newline
        case reference(MessageReference)
    }

    private static func units(from pieces: [Piece]) -> ([Unit], [MessageReference]) {
        var tokens: [Token] = []
        for piece in pieces {
            switch piece {
            case .reference(let reference):
                tokens.append(.reference(reference))
            case .text(let text):
                var start: AttributedString.Index?
                var index = text.startIndex
                while index < text.endIndex {
                    let character = text.characters[index]
                    if character.isWhitespace {
                        if let wordStart = start {
                            tokens.append(.word(AttributedString(text[wordStart..<index])))
                            start = nil
                        }
                        tokens.append(character.isNewline ? .newline : .space)
                    } else if start == nil {
                        start = index
                    }
                    index = text.characters.index(after: index)
                }
                if let wordStart = start {
                    tokens.append(.word(AttributedString(text[wordStart..<text.endIndex])))
                }
            }
        }

        var units: [Unit] = []
        var pills: [MessageReference] = []
        var consumed = -1
        var index = 0
        while index < tokens.count {
            switch tokens[index] {
            case .space:
                index += 1
            case .newline:
                units.append(.lineBreak)
                index += 1
            case .word(let word):
                // "(" touching a pill goes with it.
                if index + 1 < tokens.count, case .reference = tokens[index + 1] {
                    index += 1
                    continue
                }
                units.append(.word(word))
                index += 1
            case .reference(let reference):
                var leading: AttributedString?
                if index > 0, index - 1 != consumed, case .word(let word) = tokens[index - 1] { leading = word }
                var trailing: AttributedString?
                if index + 1 < tokens.count, case .word(let word) = tokens[index + 1] {
                    trailing = word
                    index += 1
                    consumed = index
                }
                units.append(.pill(pills.count, reference, leading: leading, trailing: trailing))
                pills.append(reference)
                index += 1
            }
        }
        return (units, pills)
    }
}

/// One pill for a reference, with its Bot's face when the roster knows it.
struct ReferencePillView: View {
    let reference: MessageReference
    var size: PillSize = .message

    @Environment(\.references) private var references

    var body: some View {
        Group {
            switch reference.kind {
            case .bot:
                BotPill(handle: reference.value, appearance: references.appearance(handle: reference.value), size: size)
            case .file, .folder:
                FilePill(path: reference.value, isFolder: reference.kind == .folder, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(reference.spokenLabel(bot: reference.kind == .bot ? references.bot(handle: reference.value) : nil)))
        .accessibilityAddTraits(.isButton)
    }
}

/// Starts a new line in an ``InlineFlowLayout``.
nonisolated struct FlowLineBreak: LayoutValueKey {
    static let defaultValue = false
}

/// Words and pills left to right, wrapping like text; each line's items centred on it.
nonisolated struct InlineFlowLayout: Layout {
    var wordGap: CGFloat = 4
    var lineGap: CGFloat = 4

    private struct Placement {
        var index: Int
        var size: CGSize
        var origin: CGPoint
    }

    private func arrange(width maxWidth: CGFloat, subviews: Subviews) -> (placements: [Placement], size: CGSize) {
        var placements: [Placement] = []
        var line: [(Int, CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var widest: CGFloat = 0
        var lastLineHeight: CGFloat = 0

        func finishLine() {
            let height = line.map(\.1.height).max() ?? lastLineHeight
            var lineX: CGFloat = 0
            for (index, size) in line {
                placements.append(Placement(index: index, size: size, origin: CGPoint(x: lineX, y: y + (height - size.height) / 2)))
                lineX += size.width + wordGap
            }
            widest = max(widest, lineX - wordGap)
            y += height + lineGap
            lastLineHeight = height
            line = []
            x = 0
        }

        for (index, subview) in subviews.enumerated() {
            if subview[FlowLineBreak.self] {
                finishLine()
                continue
            }
            var size = subview.sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            if !line.isEmpty, x + size.width > maxWidth {
                finishLine()
            }
            line.append((index, size))
            x += size.width + wordGap
        }
        if !line.isEmpty { finishLine() }
        return (placements, CGSize(width: max(0, widest), height: max(0, y - lineGap)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arranged = arrange(width: bounds.width, subviews: subviews)
        for placement in arranged.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }
}
