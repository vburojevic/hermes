#if os(iOS)
import HermesKit
import HermesMarkdown
import SwiftUI
import UIKit

/// Words selected in a finished reply on iPhone and iPad quote into the composer from Reply, first
/// in the edit menu (`docs/inbox.md` §4). Set by the reply's row while it can be quoted.
struct ReplyQuote: Equatable {
    /// The row the reply is in, and whose words they are: one row's quote does the same whenever
    /// the row is drawn again, so drawing it again doesn't redraw the reply.
    let rowID: String
    let author: String
    let quote: @MainActor (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rowID == rhs.rowID && lhs.author == rhs.author }
}

extension EnvironmentValues {
    @Entry var replyQuote: ReplyQuote? = nil
}

/// A finished reply on iPhone and iPad selects in place (`docs/chat.md` §3 Selection). It is drawn
/// a block at a time, as every reply is: one text view per reply made a long chat's scrolling half
/// again as heavy. A long press on its words lays the same reply out as one text
/// (`ReplyUIKitTextView`) over the blocks, at the same place, and selects the word under the
/// finger; the handles carry the selection across paragraphs, lists and quotes, and Reply quotes
/// it. Once the words are let go the text goes and the blocks show again.
struct ReplySelection: ViewModifier {
    /// The sentence Listen is reading (`docs/voice.md` §3).
    var highlight: SpokenSentence?
    /// The reply as one text, built only for a press.
    let reply: () -> ReplyText?
    @State private var isSelecting = false

    func body(content: Content) -> some View {
        content
            .opacity(isSelecting ? 0 : 1)
            .overlay(alignment: .topLeading) {
                ReplySelectionLayer(reply: reply, highlight: highlight, isSelecting: $isSelecting)
            }
    }
}

private struct ReplySelectionLayer: UIViewRepresentable {
    let reply: () -> ReplyText?
    var highlight: SpokenSentence?
    @Binding var isSelecting: Bool

    func makeUIView(context: Context) -> ReplySelectionView {
        ReplySelectionView()
    }

    func updateUIView(_ view: ReplySelectionView, context: Context) {
        view.reply = reply
        view.environment = context.environment
        view.highlight = highlight
        let isSelecting = $isSelecting
        view.selecting = { isSelecting.wrappedValue = $0 }
    }

    /// The blocks' own size: the layer only holds the text while words are selected.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: ReplySelectionView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }
}

/// Over a reply's blocks, empty and taking no touch until a press on the words
/// (`ReplyPressRecognizer`) puts the reply's text in it.
final class ReplySelectionView: UIView {
    var reply: () -> ReplyText? = { nil }
    var environment = EnvironmentValues() {
        didSet { text?.environment.values = environment }
    }
    var highlight: SpokenSentence? {
        didSet { text?.light(highlight) }
    }
    /// Hides the blocks while the text is shown over them, and shows them again.
    var selecting: (Bool) -> Void = { _ in }
    private(set) var text: ReplyUIKitTextView?
    /// Set while the press asks whether this reply is the frontmost view under the finger.
    fileprivate var isProbed = false

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isProbed { return bounds.contains(point) ? self : nil }
        guard let text, !isHidden else { return nil }
        return text.hitTest(convert(point, to: text), with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endSelection() } else { ReplyPressRecognizer.follow(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let text else { return }
        if text.frame.width != bounds.width { endSelection() }
    }

    /// The press held long enough at `point`: on the words, the reply shows as one text with the
    /// word there selected, and this answers true. Elsewhere it stays as it was, for the
    /// message's menu.
    fileprivate func beginSelection(at point: CGPoint) -> Bool {
        guard text == nil, bounds.width > 0, let reply = reply() else { return false }
        let text = ReplyUIKitTextView(reply: reply)
        text.environment.values = environment
        // Laid out for this screen's pixels before the words are looked for, so nothing moves
        // once it is shown.
        text.followScale(traitCollection.displayScale)
        text.frame = CGRect(x: 0, y: 0, width: bounds.width, height: text.height(for: bounds.width))
        guard text.isOnWords(point, layingOut: true) else { return false }
        text.light(highlight)
        addSubview(text)
        self.text = text
        selecting(true)
        text.beginSelection(at: point) { [weak self] in self?.endSelection() }
        return true
    }

    private func endSelection() {
        guard let text else { return }
        self.text = nil
        text.selectionEnded = nil
        text.removeFromSuperview()
        selecting(false)
    }
}

/// The long press that selects a reply's words, one for the chat. The message's menu
/// (`.contextMenu` on the row, one interaction for the whole screen) waits until it fails: off the
/// words, on a block, or let go too soon. Whether the finger is on the words is asked only once the
/// press has been held, so touching the chat to scroll costs nothing.
final class ReplyPressRecognizer: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    private let replies = NSHashTable<ReplySelectionView>.weakObjects()
    private weak var pressed: ReplySelectionView?
    /// Where the pressed reply sat in the window as its words were picked.
    private var pressedOrigin: CGPoint?

    /// Follows a reply's presses, from the view that holds the message's menu.
    static func follow(_ reply: ReplySelectionView) {
        var up = reply.superview
        while let view = up, !view.interactions.contains(where: { $0 is UIContextMenuInteraction }) { up = view.superview }
        guard let holder = up ?? reply.window else { return }
        let press = holder.gestureRecognizers?.lazy.compactMap { $0 as? ReplyPressRecognizer }.first ?? {
            let press = ReplyPressRecognizer()
            holder.addGestureRecognizer(press)
            return press
        }()
        press.replies.add(reply)
    }

    private init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(pressChanged))
        delegate = self
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard state == .possible, let window = view?.window else { return false }
        let point = touch.location(in: window)
        // A reply showing its text takes its own presses; one under the composer or a button
        // isn't the one pressed.
        pressed = replies.allObjects.first { reply in
            guard reply.text == nil, reply.window === window, reply.bounds.contains(touch.location(in: reply)) else { return false }
            reply.isProbed = true
            defer { reply.isProbed = false }
            return window.hitTest(point, with: nil) === reply
        }
        return pressed != nil
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let reply = pressed, reply.beginSelection(at: location(in: reply)) else { return false }
        pressedOrigin = reply.convert(CGPoint.zero, to: nil)
        return true
    }

    /// The message's menu, and the chat's own presses and taps, wait for the words.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other.view === view && !(other is UIPanGestureRecognizer || other is UIHoverGestureRecognizer)
    }

    @objc private func pressChanged() {
        guard let reply = pressed, let text = reply.text else { return }
        switch state {
        case .began:
            // The message's menu follows the touch from the moment it lands, so it is already
            // under way when the words are picked: stop it, or it opens over them.
            for other in view?.gestureRecognizers ?? [] where other !== self && !(other is UIHoverGestureRecognizer)
                && (other.state == .began || other.state == .changed) {
                other.isEnabled = false
                other.isEnabled = true
            }
        case .changed:
            // Selecting takes the keyboard focus, so the composer's keyboard goes down and the
            // chat slides under a finger that hasn't moved: the words picked stay picked.
            let origin = reply.convert(CGPoint.zero, to: nil)
            guard let start = pressedOrigin, abs(origin.y - start.y) < 1, abs(origin.x - start.x) < 1 else { return }
            text.extendSelection(to: location(in: text))
        case .ended, .cancelled:
            text.presentMenu()
            pressed = nil
            pressedOrigin = nil
        default:
            break
        }
    }
}

/// A reply as one text, shown over its blocks while its words are selected (`ReplySelection`):
/// selectable, never editable or scrolling, with no background of its own. Only its words and the
/// selection take a touch: a press anywhere else falls through to the reply's row, so a long press
/// on a code block, a table or an image still opens the message's menu.
final class ReplyUIKitTextView: UITextView, ReplyBlockOwner, UITextViewDelegate {
    private(set) var reply: ReplyText
    /// Where the reply sits, for the views it hosts. Its `openURL` is the chat's link gate
    /// (`MarkdownView`): links open only through it.
    let environment = ReplyEnvironment()
    private var spoken: SpokenSentence?
    private var heights: [CGFloat: CGFloat] = [:]
    /// The width the blocks and bars were last placed at.
    private var placedWidth: CGFloat = -1
    /// The hosted paragraphs' attachments, by paragraph.
    private var blocks: [Int: ReplyBlockAttachment] = [:]
    /// Each block's own view, over the space its attachment keeps in the text.
    private var blockViews: [Int: UIHostingController<ReplyBlockHost>] = [:]
    /// Each block's view as SwiftUI measures it, away from the window.
    private var blockMeasures: [Int: UIHostingController<ReplyBlockHost>] = [:]
    /// Each block's height, by the width it was laid out at.
    private var blockHeights: [Int: [CGFloat: CGFloat]] = [:]
    /// The checklist items' boxes, by paragraph, beside their words.
    private var checkboxViews: [Int: (host: UIHostingController<ReplyCheckbox>, state: ReplyBlockState)] = [:]
    private let bars = ReplyBarsView()

    private let contentStorage = NSTextContentStorage()
    private let layout = NSTextLayoutManager()
    private let fragments = ReplyFragments()
    /// The same text laid out away from the view, for its height at a width.
    private let measure = ReplyMeasure()

    init(reply: ReplyText) {
        self.reply = reply
        let container = ReplyTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.usesFontLeading = ReplyText.drawsLeading
        layout.textContainer = container
        layout.delegate = fragments
        contentStorage.addTextLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        // The text never scrolls, so it has no indicators; accessibility would list them as sliders.
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        // Links are drawn in their own color, from the text.
        linkTextAttributes = [:]
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        isFindInteractionEnabled = false
        writingToolsBehavior = .none
        // A drag on the words is a swipe to reply or a scroll, never the text dragged out.
        textDragInteraction?.isEnabled = false
        delegate = self
        bars.isUserInteractionEnabled = false
        bars.backgroundColor = .clear
        bars.isOpaque = false
        insertSubview(bars, at: 0)
        measure.laidOut = { [weak self] layout, content in
            guard let self else { return }
            reply.roundUpToPixels(in: layout, content: content, scale: fragments.scale)
        }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _: UITraitCollection) in
            view.followScale()
        }
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Contents

    private func load() {
        let text = NSMutableAttributedString(attributedString: reply.storage)
        blocks = [:]
        for host in blockViews.values { host.view.removeFromSuperview() }
        for box in checkboxViews.values { box.host.view.removeFromSuperview() }
        blockViews = [:]
        checkboxViews = [:]
        blockMeasures = [:]
        blockHeights = [:]
        text.enumerateAttribute(.replyBlock, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let index = value as? Int, let block = reply.paragraphs[index].hosted else { return }
            let paragraph = reply.paragraphs[index]
            let attachment = ReplyBlockAttachment(paragraph: index, block: block, indent: paragraph.indent, owner: self)
            attachment.state.isQuoted = paragraph.isQuoted
            blocks[index] = attachment
            text.addAttribute(.attachment, value: attachment, range: range)
        }
        heights = [:]
        // The top of the first line: a heading keeps its space above itself, and an empty fence
        // before it a block's space.
        textContainerInset = UIEdgeInsets(top: reply.top + (reply.paragraphs.first?.topPad ?? 0), left: 0, bottom: reply.bottom, right: 0)
        textStorage.setAttributedString(text)
        measure.load(text)
        placedWidth = -1
        setNeedsLayout()
    }

    private var origin: CGPoint {
        CGPoint(x: textContainerInset.left, y: textContainerInset.top)
    }

    // MARK: Size

    func height(for width: CGFloat) -> CGFloat {
        if let height = heights[width] { return height }
        // Not rounded: a block has a fractional height, and SwiftUI stacks it as it is.
        let height = measure.height(for: width) + textContainerInset.top + reply.bottom
        heights[width] = height
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bars.frame != bounds { bars.frame = bounds }
        if subviews.first !== bars { sendSubviewToBack(bars) }
        guard bounds.width != placedWidth else { return }
        placedWidth = bounds.width
        reply.roundUpToPixels(in: layout, content: contentStorage, scale: fragments.scale)
        measureBars()
        placeBlocks()
    }

    // MARK: Quotes

    private func measureBars() {
        bars.rects = reply.barRects(in: layout, content: contentStorage, origin: origin)
    }

    private func fragment(for paragraph: Int) -> NSTextLayoutFragment? {
        reply.fragment(for: paragraph, in: layout, content: contentStorage)
    }

    // MARK: Blocks

    /// A block's height at this width, as SwiftUI lays it out.
    func blockHeight(_ attachment: ReplyBlockAttachment, width: CGFloat) -> CGFloat {
        let index = attachment.paragraph
        if let height = blockHeights[index]?[width] { return height }
        let height: CGFloat = if case .thematicBreak = attachment.block {
            ReplyText.Metrics.ruleHeight
        } else {
            measuring(attachment).sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        }
        blockHeights[index, default: [:]][width] = height
        return height
    }

    private func measuring(_ attachment: ReplyBlockAttachment) -> UIHostingController<ReplyBlockHost> {
        if let host = blockMeasures[attachment.paragraph] { return host }
        let host = UIHostingController(rootView: blockView(attachment, resized: nil))
        host.sizingOptions = []
        host.safeAreaRegions = []
        blockMeasures[attachment.paragraph] = host
        return host
    }

    /// A block's view changed its height where it is shown (an image arrived, a widget drew):
    /// the text makes room for it.
    private func blockResized(_ index: Int, to height: CGFloat) {
        guard let view = blockViews[index]?.view, let known = blockHeights[index]?[view.frame.width],
              abs(known - height) > 0.01 else { return }
        blockHeights[index] = [view.frame.width: height]
        heights = [:]
        measure.invalidate()
        layout.invalidateLayout(for: layout.documentRange)
        placedWidth = -1
        frame.size.height = self.height(for: bounds.width)
        setNeedsLayout()
    }

    /// Puts each block's view where its attachment is laid out, and each checklist item's box
    /// beside its first line. The view draws the block; the attachment only keeps its place in
    /// the text and the selection.
    private func placeBlocks() {
        guard !blocks.isEmpty || reply.paragraphs.contains(where: { $0.checkbox != nil }), bounds.width > 0 else { return }
        layout.ensureLayout(for: layout.documentRange)
        let origin = origin
        for (index, attachment) in blocks.sorted(by: { $0.key < $1.key }) {
            guard let fragment = fragment(for: index) else { continue }
            let width = max(0, bounds.width - attachment.indent)
            // SwiftUI puts a block's edges on whole pixels.
            let top = origin.y + fragment.layoutFragmentFrame.minY
            let bottom = top + blockHeight(attachment, width: width)
            let frame = CGRect(x: origin.x + attachment.indent, y: pixel(top), width: width, height: pixel(bottom) - pixel(top))
            let host = blockViews[index] ?? {
                let host = UIHostingController(rootView: blockView(attachment, resized: { [weak self] in self?.blockResized(index, to: $0) }))
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.view.backgroundColor = .clear
                addSubview(host.view)
                blockViews[index] = host
                return host
            }()
            if host.view.frame != frame { host.view.frame = frame }
        }
        for (index, paragraph) in reply.paragraphs.enumerated() {
            guard let checkbox = paragraph.checkbox, let fragment = fragment(for: index),
                  let line = fragment.textLineFragments.first else { continue }
            let box = checkboxViews[index] ?? {
                let state = ReplyBlockState()
                state.isQuoted = paragraph.isQuoted
                let host = UIHostingController(rootView: ReplyCheckbox(
                    isChecked: checkbox.isChecked, state: state, environment: environment, font: reply.bodyFont))
                host.sizingOptions = []
                host.safeAreaRegions = []
                host.view.backgroundColor = .clear
                // Touches go through the box to the words beside it.
                host.view.isUserInteractionEnabled = false
                addSubview(host.view)
                checkboxViews[index] = (host, state)
                return (host, state)
            }()
            // The list's own row: its marker on the first line's baseline, from the list's edge.
            let top = pixel(origin.y + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY)
            let frame = CGRect(
                x: origin.x + checkbox.x, y: top, width: max(0, bounds.width - checkbox.x),
                height: pixel(line.typographicBounds.height))
            if box.host.view.frame != frame { box.host.view.frame = frame }
        }
    }

    private func pixel(_ y: CGFloat) -> CGFloat {
        (y * fragments.scale).rounded() / fragments.scale
    }

    private func blockView(_ attachment: ReplyBlockAttachment, resized: ((CGFloat) -> Void)?) -> ReplyBlockHost {
        ReplyBlockHost(
            block: attachment.block, state: attachment.state, environment: environment, font: reply.bodyFont, resized: resized)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearSelection() }
        followScale()
    }

    /// Lines and blocks snap to the pixels of the screen the reply is on.
    func followScale(_ shown: CGFloat? = nil) {
        let scale = shown ?? traitCollection.displayScale
        guard scale > 0, scale != fragments.scale else { return }
        fragments.scale = scale
        heights = [:]
        measure.invalidate()
        layout.invalidateLayout(for: layout.documentRange)
        placedWidth = -1
        setNeedsLayout()
    }

    // MARK: Touches

    /// The block whose view is at `point`, in the view's coordinates.
    private func blockView(at point: CGPoint) -> UIView? {
        blockViews.values.lazy.map(\.view).first { $0.frame.contains(point) }
    }

    private var hasSelection: Bool {
        selectedRanges.contains { $0.length > 0 }
    }

    /// Whether `point` is on a line of words, not a block or the space around the text. Before the
    /// view is shown, `layingOut` lays the whole text out first.
    func isOnWords(_ point: CGPoint, layingOut: Bool = false) -> Bool {
        if layingOut { reply.roundUpToPixels(in: layout, content: contentStorage, scale: fragments.scale) }
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard let fragment = layout.textLayoutFragment(for: inContainer) else { return false }
        if let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
           paragraph.attributedString.attribute(.replyBlock, at: 0, effectiveRange: nil) != nil {
            return false
        }
        let frame = fragment.layoutFragmentFrame
        return fragment.textLineFragments.contains { line in
            line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY).insetBy(dx: -6, dy: -2).contains(inContainer)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
        if let block = blockView(at: point) {
            return block.hitTest(convert(point, to: block), with: event) ?? block
        }
        // While words are selected the whole text is the selection's: its handles reach past the words.
        guard hasSelection || isOnWords(point) else { return nil }
        holdMessageMenu()
        return super.hitTest(point, with: event)
    }

    /// The word under a point, in the text's characters.
    private func word(at point: CGPoint) -> NSRange? {
        guard let position = closestPosition(to: point) else { return nil }
        let directions: [UITextStorageDirection] = [.forward, .backward]
        for direction in directions {
            if let range = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: UITextDirection(rawValue: direction.rawValue)) {
                return NSRange(location: offset(from: beginningOfDocument, to: range.start), length: offset(from: range.start, to: range.end))
            }
        }
        return nil
    }

    /// Each message menu recognizer and text press it already waits for. The text's presses are
    /// made again when it gives up the keyboard focus, so a pair is held once, not a recognizer.
    private var heldMenuPairs: Set<[ObjectIdentifier]> = []

    /// A long press on other words while some are selected picks those instead, so the message's
    /// menu (`.contextMenu` on the row, one interaction for the whole screen) waits until that press
    /// fails: off the words, on a block, or let go too soon.
    private func holdMessageMenu() {
        let presses = (gestureRecognizers ?? []).filter {
            $0 is UILongPressGestureRecognizer && $0.isEnabled && $0.delegate !== self
        }
        var up = superview
        while let view = up {
            if view.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
                for recognizer in view.gestureRecognizers ?? []
                where !(recognizer is UIHoverGestureRecognizer || recognizer is UIPanGestureRecognizer) {
                    for press in presses
                    where heldMenuPairs.insert([ObjectIdentifier(recognizer), ObjectIdentifier(press)]).inserted {
                        recognizer.require(toFail: press)
                    }
                }
            }
            up = view.superview
        }
    }

    /// The words' menu once a press the reply's row followed lifts (`ReplyPressRecognizer`): the
    /// text shows its own menu only for its own presses.
    private lazy var movedMenu: (interaction: UIEditMenuInteraction, delegate: MovedMenuDelegate) = {
        let delegate = MovedMenuDelegate(owner: self)
        let interaction = UIEditMenuInteraction(delegate: delegate)
        addInteraction(interaction)
        return (interaction, delegate)
    }()

    private func showMenu(selecting words: NSRange) {
        guard isFirstResponder, NSMaxRange(words) <= textStorage.length else { return }
        selectedRange = words
        guard let range = selectedTextRange else { return }
        let rect = firstRect(for: range)
        movedMenu.interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)))
    }

    fileprivate final class MovedMenuDelegate: NSObject, UIEditMenuInteractionDelegate {
        weak var owner: ReplyUIKitTextView?

        init(owner: ReplyUIKitTextView) { self.owner = owner }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            owner?.editMenu(suggestedActions: suggestedActions)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            guard let owner, let range = owner.selectedTextRange else { return .null }
            return owner.selectionRects(for: range).map(\.rect).reduce(CGRect.null) { $0.union($1) }
        }
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // A press on a block is the block's, or the message's menu.
        if recognizer.view === self, blockView(at: recognizer.location(in: self)) != nil { return false }
        return super.gestureRecognizerShouldBegin(recognizer)
    }

    // MARK: Selection

    /// Called once the words are let go, so the reply's blocks show again.
    var selectionEnded: (@MainActor @Sendable () -> Void)?
    /// The word a press picked first, which dragging the finger selects from.
    private var pressedWord: NSRange?

    /// Selects the word at `point` for a press the reply's row followed (`ReplyPressRecognizer`),
    /// as the text's own press would.
    func beginSelection(at point: CGPoint, ended: @escaping @MainActor @Sendable () -> Void) {
        _ = becomeFirstResponder()
        if let word = word(at: point) {
            selectedRange = word
            pressedWord = word
        }
        selectionEnded = ended
        if !hasSelection { endIfLetGo() }
    }

    /// The finger moved on: the words from the first one to the one under it are selected.
    func extendSelection(to point: CGPoint) {
        guard let start = pressedWord, let word = word(at: point) else { return }
        let words = NSUnionRange(start, word)
        if selectedRange != words { selectedRange = words }
    }

    /// The words' menu, once the finger lifts.
    func presentMenu() {
        pressedWord = nil
        guard hasSelection else { return }
        showMenu(selecting: selectedRange)
    }

    private func endIfLetGo() {
        guard !hasSelection, let ended = selectionEnded else { return }
        selectionEnded = nil
        // After the menu's action, or the tap that let go, has finished with the text.
        DispatchQueue.main.async(execute: ended)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let selected = selectedRanges.filter { $0.length > 0 }
        for (index, attachment) in blocks {
            let location = reply.paragraphs[index].range.location
            let isSelected = selected.contains { NSLocationInRange(location, $0) }
            if attachment.state.isSelected != isSelected { attachment.state.isSelected = isSelected }
        }
        followTapsElsewhere(hasSelection)
        endIfLetGo()
    }

    /// The tap on the chat that lets go of the words, while some are selected.
    private var tapElsewhere: (recognizer: UITapGestureRecognizer, delegate: TapElsewhereDelegate)?

    /// A tap anywhere else in the chat lets go of the selected words, as a tap beside them does.
    /// The text never sees that tap (it takes no touch off its own bounds), so the chat's scroll
    /// view watches for it. The edit menu isn't in the chat, so its actions still find the words.
    private func followTapsElsewhere(_ follows: Bool) {
        guard follows else {
            if let tap = tapElsewhere { tap.recognizer.view?.removeGestureRecognizer(tap.recognizer) }
            tapElsewhere = nil
            return
        }
        guard tapElsewhere == nil else { return }
        var up = superview
        while let view = up, !(view is UIScrollView) { up = view.superview }
        guard let chat = up else { return }
        let delegate = TapElsewhereDelegate()
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(tappedElsewhere(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = delegate
        chat.addGestureRecognizer(recognizer)
        tapElsewhere = (recognizer, delegate)
    }

    @objc private func tappedElsewhere(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, !bounds.contains(tap.location(in: self)) else { return }
        clearSelection()
    }

    fileprivate final class TapElsewhereDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// Reply comes first in the edit menu, for words that can be quoted (`docs/inbox.md` §4).
    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
        editMenu(suggestedActions: suggestedActions)
    }

    private func editMenu(suggestedActions: [UIMenuElement]) -> UIMenu {
        let passage = selectionText
        guard let replyQuote = environment.values.replyQuote, QuotedReply.quotes(passage) else {
            return UIMenu(children: suggestedActions)
        }
        let reply = UIAction(title: String(localized: "Reply"), image: UIImage(systemName: "arrowshape.turn.up.left")) { [weak self] _ in
            replyQuote.quote(passage)
            self?.clearSelection()
        }
        return UIMenu(children: [reply] + suggestedActions)
    }

    private var selectionText: String {
        let selected = selectedRanges.filter { $0.length > 0 }
        guard let first = selected.first else { return "" }
        let union = selected.dropFirst().reduce(first) { NSUnionRange($0, $1) }
        return reply.plainText(in: union)
    }

    private func clearSelection() {
        followTapsElsewhere(false)
        guard hasSelection else { return }
        selectedRanges = [NSRange(location: 0, length: 0)]
        _ = resignFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { followTapsElsewhere(false) }
        if resigned, hasSelection { selectedRanges = [NSRange(location: 0, length: 0)] }
        if resigned { endIfLetGo() }
        return resigned
    }

    /// Copy takes the selection as plain text (`ReplyPlainText`), never the drawn text with its
    /// blocks' attachments.
    override func copy(_ sender: Any?) {
        let text = selectionText
        guard !text.isEmpty else { return }
        Pasteboard.copy(text)
    }

    // MARK: Links

    /// A tap on a link goes through the chat's gate only: the web and mail open, gateway files
    /// open in the Inspector.
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return nil }
        let openURL = environment.values.openURL
        return UIAction { _ in openURL(url) }
    }

    /// No system preview or menu for a link, an attachment or a tag: nothing opens around the gate.
    func textView(
        _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        nil
    }

    // MARK: Listen

    /// While Listen reads the reply, the blocks it isn't reading are lighter, and in a paragraph
    /// being read only the sentence is ink (`MarkdownBlockView.lit`).
    func light(_ sentence: SpokenSentence?) {
        guard sentence != spoken else { return }
        spoken = sentence
        reply.light(textStorage, sentence: sentence)
        for (index, attachment) in blocks {
            let listen = reply.listen(index, sentence: sentence)
            if attachment.state.isDimmed != listen.isDimmed { attachment.state.isDimmed = listen.isDimmed }
            if attachment.state.sentence != listen.read { attachment.state.sentence = listen.read }
        }
        for (index, box) in checkboxViews {
            let isDimmed = reply.listen(index, sentence: sentence).isDimmed
            if box.state.isDimmed != isDimmed { box.state.isDimmed = isDimmed }
        }
    }
}

/// The reply's text container, with no bottom. A text view that doesn't scroll sizes its
/// container to its own frame, and TextKit lays out only what fits in the container: the height
/// is measured from the text (`ReplyMeasure`), so a frame from an earlier pass never cuts the
/// layout short.
nonisolated final class ReplyTextContainer: NSTextContainer {
    override var size: CGSize {
        get { super.size }
        set { super.size = CGSize(width: newValue.width, height: .greatestFiniteMagnitude) }
    }
}

/// The quotes' bars, behind the text.
final class ReplyBarsView: UIView {
    var rects: [CGRect] = [] {
        didSet { if rects != oldValue { setNeedsDisplay() } }
    }

    override func draw(_ rect: CGRect) {
        guard !rects.isEmpty else { return }
        ReplyText.Palette.hairline.setFill()
        for bar in rects where bar.intersects(rect) {
            UIBezierPath(roundedRect: bar, cornerRadius: bar.width / 2).fill()
        }
    }
}
extension ReplyText {
    /// SwiftUI rounds each block's height up to a whole pixel and stacks the next one below it,
    /// where TextKit starts the next paragraph at the fraction: each paragraph's space after it
    /// takes that fraction, so no line moves when the text takes the blocks' place.
    func roundUpToPixels(in layout: NSTextLayoutManager, content: NSTextContentStorage, scale: CGFloat) {
        layout.ensureLayout(for: layout.documentRange)
        guard scale > 0, let text = content.textStorage else { return }
        var styles: [(NSRange, NSParagraphStyle)] = []
        for (index, paragraph) in paragraphs.enumerated() where paragraph.hosted == nil && index + 1 < paragraphs.count {
            guard let fragment = fragment(for: index, in: layout, content: content),
                  let first = fragment.textLineFragments.first, let last = fragment.textLineFragments.last,
                  let base = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let shown = text.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
            else { continue }
            // The lines' height from the first one's top: TextKit puts the line spacing above it.
            let height = last.typographicBounds.maxY - first.typographicBounds.minY
            let spacing = base.paragraphSpacing + (height * scale - 0.001).rounded(.up) / scale - height
            guard abs(shown.paragraphSpacing - spacing) > 0.0001,
                  let style = base.mutableCopy() as? NSMutableParagraphStyle else { continue }
            style.paragraphSpacing = spacing
            styles.append((NSRange(location: paragraph.range.location, length: paragraph.range.length + 1), style))
        }
        guard !styles.isEmpty else { return }
        content.performEditingTransaction {
            for (range, style) in styles { text.addAttribute(.paragraphStyle, value: style, range: range) }
        }
        layout.ensureLayout(for: layout.documentRange)
    }
}
#endif
