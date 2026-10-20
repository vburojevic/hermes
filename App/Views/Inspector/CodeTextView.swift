import HermesMarkdown
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Code in the Inspector (`docs/inspector.md` §4): monospaced, with line numbers and Xcode
/// colours (`syntax.*`), lines never wrapping. A File tab edits it; an artifact's Code view only
/// reads it. Text selection and the system find bar (⌘F) work; the size follows Dynamic Type on
/// iPhone and iPad. Lines changed since opening get a tint.
struct CodeTextView: View {
    @Binding var text: String
    var language: String?
    var isEditable = false
    /// 1-based lines to tint (changed since the file was opened).
    var changedLines: Set<Int> = []
    var onCaretLine: ((Int) -> Void)?

    var body: some View {
        CodeTextRepresentable(text: $text, language: language, isEditable: isEditable, changedLines: changedLines, onCaretLine: onCaretLine)
            .accessibilityLabel(Text(isEditable ? "Code editor" : "Code"))
    }

    /// Lines in `new` that aren't in `old` (insertions), 1-based.
    static func changedLines(from old: String, to new: String) -> Set<Int> {
        guard old != new else { return [] }
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        var lines = Set<Int>()
        for change in b.difference(from: a) {
            if case .insert(let offset, _, _) = change { lines.insert(offset + 1) }
        }
        return lines
    }
}

/// Tints code with `CodeHighlighter`'s tokens, keeping the text (and so the selection) as is.
@MainActor
private enum CodeStyler {
    static let highlightLimit = 300_000

    #if os(macOS)
    typealias PlatformFont = NSFont
    typealias PlatformColor = NSColor
    #else
    typealias PlatformFont = UIFont
    typealias PlatformColor = UIColor
    #endif

    static var font: PlatformFont {
        #if os(macOS)
        .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        #else
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        #endif
    }

    static var lineHeight: CGFloat { (font.ascender - font.descender + font.leading) * 1.25 }

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    static func color(_ kind: CodeHighlighter.Token.Kind) -> PlatformColor {
        let color: Color = switch kind {
        case .plain: Theme.primaryText
        case .keyword: Theme.Syntax.keyword
        case .type: Theme.Syntax.type
        case .string: Theme.Syntax.string
        case .number: Theme.Syntax.number
        case .comment: Theme.Syntax.comment
        case .function: Theme.Syntax.function
        case .property: Theme.Syntax.property
        case .meta: Theme.Syntax.meta
        case .inserted: Theme.Syntax.inserted
        case .deleted: Theme.Syntax.deleted
        }
        return PlatformColor(color)
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color(.plain), .paragraphStyle: paragraph]
    }

    static func apply(to storage: NSTextStorage, language: String?) {
        let string = storage.string
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        if storage.length <= highlightLimit {
            var location = 0
            for token in CodeHighlighter.tokenize(string, language: language) {
                let length = (token.text as NSString).length
                if token.kind != .plain, location + length <= storage.length {
                    storage.addAttribute(.foregroundColor, value: color(token.kind), range: NSRange(location: location, length: length))
                }
                location += length
            }
        }
        storage.endEditing()
    }

    /// Where each line starts (UTF-16 offsets), for numbering line fragments.
    static func lineStarts(_ string: String) -> [Int] {
        var starts = [0]
        let utf16 = Array(string.utf16)
        for (index, unit) in utf16.enumerated() where unit == 10 { starts.append(index + 1) }
        return starts
    }

    /// The 1-based line a character offset is on.
    static func line(at offset: Int, in starts: [Int]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }
}

#if os(macOS)

private struct CodeTextRepresentable: NSViewRepresentable {
    @Binding var text: String
    var language: String?
    var isEditable: Bool
    var changedLines: Set<Int>
    var onCaretLine: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let textView = CodeNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.typingAttributes = CodeStyler.baseAttributes
        textView.delegate = context.coordinator
        scroll.documentView = textView
        let ruler = LineNumberRuler(textView: textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        textView.string = text
        CodeStyler.apply(to: textView.textStorage!, language: language)
        context.coordinator.lineStarts = CodeStyler.lineStarts(text)
        ruler.lineStarts = context.coordinator.lineStarts
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.isEditable = isEditable
        textView.isSelectable = true
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            CodeStyler.apply(to: textView.textStorage!, language: language)
            context.coordinator.lineStarts = CodeStyler.lineStarts(text)
            context.coordinator.ruler?.lineStarts = context.coordinator.lineStarts
            textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        if textView.changedLines != changedLines {
            textView.changedLines = changedLines
            textView.lineStarts = context.coordinator.lineStarts
            textView.needsDisplay = true
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextRepresentable
        weak var textView: CodeNSTextView?
        weak var ruler: LineNumberRuler?
        var lineStarts: [Int] = [0]
        private var restyle: Task<Void, Never>?

        init(_ parent: CodeTextRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            lineStarts = CodeStyler.lineStarts(textView.string)
            ruler?.lineStarts = lineStarts
            textView.lineStarts = lineStarts
            ruler?.needsDisplay = true
            restyle?.cancel()
            restyle = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let textView = self?.textView else { return }
                CodeStyler.apply(to: textView.textStorage!, language: self?.parent.language)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.onCaretLine?(CodeStyler.line(at: textView.selectedRange().location, in: lineStarts))
        }
    }
}

/// The text view, tinting changed lines across their full width.
final class CodeNSTextView: NSTextView {
    var changedLines: Set<Int> = []
    var lineStarts: [Int] = [0]

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !changedLines.isEmpty, let layoutManager, let textContainer else { return }
        NSColor(Theme.successTint).setFill()
        for line in changedLines where line - 1 < lineStarts.count {
            let start = lineStarts[line - 1]
            guard start <= (string as NSString).length else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: start)
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: min(glyph, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil)
            if layoutManager.numberOfGlyphs == 0 || start == (string as NSString).length { fragment = layoutManager.extraLineFragmentRect }
            _ = textContainer
            let y = fragment.minY + textContainerOrigin.y
            NSRect(x: rect.minX, y: y, width: rect.width, height: fragment.height).fill()
        }
    }
}

/// Line numbers beside the code.
final class LineNumberRuler: NSRulerView {
    var lineStarts: [Int] = [0] {
        didSet { updateThickness() }
    }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateThickness() {
        let digits = max(2, String(lineStarts.count).count)
        ruleThickness = CGFloat(digits) * 8 + 16
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(Theme.tertiaryText),
        ]
        let origin = textView.textContainerOrigin
        let offset = convert(NSPoint.zero, from: textView).y
        var lastLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layoutManager.characterIndexForGlyph(at: range.location)
            let line = CodeStyler.line(at: character, in: self.lineStarts)
            guard line != lastLine else { return }
            lastLine = line
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + origin.y + offset + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 8, y: y), withAttributes: attributes)
        }
    }
}

#else

private struct CodeTextRepresentable: UIViewRepresentable {
    @Binding var text: String
    var language: String?
    var isEditable: Bool
    var changedLines: Set<Int>
    var onCaretLine: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeUITextView {
        let view = CodeUITextView()
        view.delegate = context.coordinator
        view.text = text
        view.language = language
        view.restyle()
        return view
    }

    func updateUIView(_ view: CodeUITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = isEditable
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            view.language = language
            view.restyle()
            if selection.upperBound <= (text as NSString).length { view.selectedRange = selection }
        }
        if view.changedLines != changedLines {
            view.changedLines = changedLines
            view.setNeedsLayout()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeTextRepresentable
        private var restyle: Task<Void, Never>?

        init(_ parent: CodeTextRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? CodeUITextView else { return }
            parent.text = view.text
            view.lineStarts = CodeStyler.lineStarts(view.text)
            view.setNeedsLayout()
            restyle?.cancel()
            restyle = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                view.restyle()
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let view = textView as? CodeUITextView else { return }
            parent.onCaretLine?(CodeStyler.line(at: view.selectedRange.location, in: view.lineStarts))
        }
    }
}

/// A TextKit 1 text view whose lines never wrap, with a gutter of line numbers pinned to the
/// left and changed lines tinted underneath.
final class CodeUITextView: UITextView {
    var language: String?
    var changedLines: Set<Int> = []
    var lineStarts: [Int] = [0]
    private let gutter = GutterView()
    private let underlay = LineTintView()
    private var gutterWidth: CGFloat = 36

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        backgroundColor = .clear
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .asciiCapable
        isFindInteractionEnabled = true
        alwaysBounceVertical = true
        showsHorizontalScrollIndicator = true
        adjustsFontForContentSizeCategory = true
        typingAttributes = CodeStyler.baseAttributes
        gutter.textView = self
        underlay.textView = self
        insertSubview(underlay, at: 0)
        addSubview(gutter)
        // Dynamic Type resizes the code; light, dark and Increase Contrast redraw the gutter.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: CodeUITextView, _) in view.restyle() }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: CodeUITextView, _) in
            view.restyle()
            view.gutter.setNeedsDisplay()
            view.underlay.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func restyle() {
        lineStarts = CodeStyler.lineStarts(text)
        CodeStyler.apply(to: textStorage, language: language)
        setNeedsLayout()
    }


    override func layoutSubviews() {
        super.layoutSubviews()
        let digits = max(2, String(lineStarts.count).count)
        let width = CGFloat(digits) * 8 + 18
        if width != gutterWidth || textContainerInset.left != width + 4 {
            gutterWidth = width
            textContainerInset = UIEdgeInsets(top: 10, left: width + 4, bottom: 24, right: 12)
        }
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        underlay.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: bounds.width, height: bounds.height)
        gutter.setNeedsDisplay()
        underlay.setNeedsDisplay()
        bringSubviewToFront(gutter)
    }

    /// Visible line fragments: (rect in this view's visible coordinates, 1-based line).
    func visibleLines() -> [(rect: CGRect, line: Int)] {
        let visible = CGRect(origin: CGPoint(x: contentOffset.x, y: contentOffset.y - textContainerInset.top), size: bounds.size)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        var out: [(CGRect, Int)] = []
        var lastLine = -1
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = self.layoutManager.characterIndexForGlyph(at: range.location)
            let line = CodeStyler.line(at: character, in: self.lineStarts)
            guard line != lastLine else { return }
            lastLine = line
            out.append((CGRect(x: 0, y: fragment.minY + self.textContainerInset.top - self.contentOffset.y, width: self.bounds.width, height: fragment.height), line))
        }
        if layoutManager.extraLineFragmentRect.height > 0, text.hasSuffix("\n") || text.isEmpty {
            let extra = layoutManager.extraLineFragmentRect
            out.append((CGRect(x: 0, y: extra.minY + textContainerInset.top - contentOffset.y, width: bounds.width, height: extra.height), lineStarts.count))
        }
        return out
    }

    final class GutterView: UIView {
        weak var textView: CodeUITextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ rect: CGRect) {
            guard let textView else { return }
            UIColor(Theme.canvas).setFill()
            UIRectFill(bounds)
            let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor(Theme.tertiaryText)]
            for (rect, line) in textView.visibleLines() {
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: bounds.width - size.width - 8, y: rect.minY + (rect.height - size.height) / 2), withAttributes: attributes)
            }
        }
    }

    final class LineTintView: UIView {
        weak var textView: CodeUITextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            isUserInteractionEnabled = false
            contentMode = .redraw
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ rect: CGRect) {
            guard let textView, !textView.changedLines.isEmpty else { return }
            UIColor(Theme.successTint).setFill()
            for (rect, line) in textView.visibleLines() where textView.changedLines.contains(line) {
                UIRectFill(rect)
            }
        }
    }
}

#endif
