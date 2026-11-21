import HermesKit
import HermesPush
import SwiftUI

/// The New Messages line, where you stopped reading (`newMessagesDivider`, `docs/inbox.md` §4).
/// A header for VoiceOver.
struct NewMessagesDivider: View {
    let count: Int

    private var label: String {
        count == 1 ? String(localized: "1 new message") : String(localized: "\(UnreadCounter.label(count)) new messages")
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .fixedSize()
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Theme.surface, in: Capsule())
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("newMessagesLine")
    }
}

/// The pill over the composer while you read further up (`newMessagesPill` + `Live`, `Bot`):
/// what's below, and a tap to get there. Nothing new: the round arrow.
struct JumpPillView: View {
    let pill: JumpPill
    /// What's running, for the live pill.
    var activity: ActivityLine?
    /// A Bot chat's face leads (`newMessagesPillBot`).
    var face: BotAppearance?
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var morph

    var body: some View {
        Button(action: action) {
            switch pill {
            case .latest:
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .matchedGeometryEffect(id: "glyph", in: morph)
            case .live:
                capsule {
                    // What the turn is doing, shimmering: the one moving thing over the chat.
                    ShimmerText(text: liveText, font: .subheadline.weight(.semibold), tone: .ink)
                        .contentTransition(.opacity)
                }
            case .newMessages(let count, _):
                capsule {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .matchedGeometryEffect(id: "glyph", in: morph)
                    Text(count == 1 ? String(localized: "1 new message") : String(localized: "\(UnreadCounter.label(count)) new messages"))
                        // The count rolls to its new value; with Reduce Motion it just changes.
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(count)))
                }
            case .mention(let name, _):
                capsule {
                    Image(systemName: "at")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(name) mentioned you")
                }
            }
        }
        .foregroundStyle(Theme.primaryText)
        .glassButton()
        .buttonBorderShape(pill == .latest ? .circle : .capsule)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.85), value: pill)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The running step ("Running swift test"), else "Hermes is writing…": the reply's own words
    /// are what's below.
    private var liveText: String {
        switch activity {
        case .none, .writing: String(localized: "Hermes is writing…")
        case let line?: line.text
        }
    }

    private func capsule<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            if let face {
                BotFace(appearance: face, size: 22, mood: activity?.isLive == true ? .thinking : .idle)
            }
            content()
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.leading, face == nil ? 14 : 8)
        .padding(.trailing, 16)
        .frame(height: 38)
    }

    private var accessibilityLabel: Text {
        switch pill {
        case .latest: Text("Scroll to latest")
        case .live: Text("\(liveText). Jump to the latest.")
        // What the next tap does: the first new message, or the end once the first tap went there.
        case .newMessages(1, nil): Text("1 new message. Jump to the latest.")
        case .newMessages(1, _): Text("1 new message. Jump to it.")
        case .newMessages(let count, nil): Text("\(count) new messages. Jump to the latest.")
        case .newMessages(let count, _): Text("\(count) new messages. Jump to the first one.")
        case .mention(let name, _): Text("\(name) mentioned you. Jump to it.")
        }
    }
}

/// A Bot in a group chat before its first words (`botThinkingLine`): its face in the thinking
/// mood, without dots, and "Ada is thinking…" shimmering. No bubble: the words are the one thing
/// that moves (`docs/chat.md` §4a).
struct BotThinkingLine: View {
    let appearance: BotAppearance?
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            if let appearance {
                BotFace(appearance: appearance, size: 18, mood: .thinking)
            }
            ShimmerText(text: String(localized: "\(name) is thinking…"))
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The passages a reply quotes, in the composer (`docs/inbox.md` §4). One quote is the
/// `replyBar`: whose it is, the passage and ✕. Two or three are `replyQuotes`: a head that counts
/// them, then one row each with its own ✕ (`replyQuote`), and the note when Reply found the bar
/// full (`replyQuotesLimit`). Short on room, the list stops at 120 pt and scrolls
/// (`replyQuotesCapped`); with the keyboard up in iPhone landscape only the head shows, and a tap
/// on it hides the keyboard (`replyQuotesCollapsed`).
struct ReplyBar: View {
    let draft: QuotedReply.Draft
    var capped = false
    var collapsed = false
    var onExpand: () -> Void = {}
    let onRemove: (QuotedReply.Passage.ID) -> Void

    /// The tallest the list gets when it is capped.
    static let cap: CGFloat = 120

    @State private var listHeight: CGFloat = 0

    var body: some View {
        if draft.count == 1, let passage = draft.passages.first, !draft.showsLimit {
            single(passage)
        } else {
            several
        }
    }

    private func single(_ passage: QuotedReply.Passage) -> some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(passage.author)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(LastLine.flatten(passage.quote))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            closeButton(label: Text("Stop replying")) { onRemove(passage.id) }
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .contain)
    }

    private var several: some View {
        VStack(alignment: .leading, spacing: 2) {
            head
            if !collapsed {
                list
                if draft.showsLimit { limit }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, collapsed ? 6 : (overflows ? 10 : 2))
        .accessibilityElement(children: .contain)
    }

    private var head: some View {
        HStack(spacing: 6) {
            Text("Replying with \(draft.count) quotes")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if collapsed {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { if collapsed { onExpand() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(collapsed ? [.isHeader, .isButton] : .isHeader)
        .accessibilityHint(collapsed ? Text("Hides the keyboard to show the quotes") : Text(""))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(draft.passages) { passage in
                row(passage)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
    }

    /// Whether the capped list is taller than its cap, so it scrolls and its cut row fades.
    private var overflows: Bool { capped && listHeight > Self.cap }

    @ViewBuilder
    private var list: some View {
        if capped {
            ScrollView {
                rows
            }
            .frame(height: min(max(listHeight, 1), Self.cap))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(overflows ? .visible : .hidden)
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    if overflows {
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 24)
                    }
                }
            }
        } else {
            rows
        }
    }

    private func row(_ passage: QuotedReply.Passage) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(passage.author)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(LastLine.flatten(passage.quote))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(quoteLabel(passage))
            closeButton(label: removeLabel(passage)) {
                onRemove(passage.id)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.leading, 12)
        .padding(.trailing, 6)
    }

    /// With several quotes each says where it sits, so two of the same words can be told apart.
    private func quoteLabel(_ passage: QuotedReply.Passage) -> Text {
        let words = LastLine.flatten(passage.quote)
        guard let position = draft.position(of: passage.id) else {
            return Text("Quote from \(passage.author): \(words)")
        }
        return Text("Quote \(position) of \(draft.count), from \(passage.author): \(words)")
    }

    private func removeLabel(_ passage: QuotedReply.Passage) -> Text {
        let words = LastLine.flatten(passage.quote)
        guard let position = draft.position(of: passage.id) else {
            return Text("Remove the quote from \(passage.author): \(words)")
        }
        return Text("Remove quote \(position) of \(draft.count), from \(passage.author): \(words)")
    }

    private var limit: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Text(QuotedReply.Draft.limitNote)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        // One element with the note's words, so VoiceOver doesn't read the glyph as "Info".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(QuotedReply.Draft.limitNote))
    }

    private func closeButton(label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The quote at the top of a reply (`quotedBubble`): who said it and one line of it. Tapping it
/// goes back to the passage when this device knows where it was.
struct QuotedBlock: View {
    let quote: String
    var author: String?
    var onTap: (() -> Void)?
    /// A veil of the canvas on a bubble; the surface on a card that is the canvas itself
    /// (`asideCardQuoted`).
    var fill: Color

    /// A sent quote: whose it was and the row it links back to, as this device remembers them
    /// for the chat. One it doesn't remember shows only the words.
    init(quote: String, chat: String?, fill: Color = Theme.canvas.opacity(0.7), jump: @escaping (String) -> Void) {
        let source = QuoteMemory.source(of: quote, chat: chat)
        self.init(quote: quote, author: source?.author, fill: fill, onTap: source.flatMap { source in
            source.rowID.isEmpty ? nil : { jump(source.rowID) }
        })
    }

    init(quote: String, author: String? = nil, fill: Color = Theme.canvas.opacity(0.7), onTap: (() -> Void)? = nil) {
        self.quote = quote
        self.author = author
        self.fill = fill
        self.onTap = onTap
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3)
                .frame(minHeight: 18)
            VStack(alignment: .leading, spacing: 0) {
                if let author {
                    Text(author)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                }
                Text(LastLine.flatten(quote))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Quote\(author.map { ", \($0)" } ?? ""): \(LastLine.flatten(quote))"))
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

/// Reply to chosen words (`docs/inbox.md` §4): the message, to select from, and Reply.
struct ChooseQuoteSheet: View {
    let author: String
    let text: String
    let onReply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editable: String
    @State private var selection: TextSelection?

    init(author: String, text: String, onReply: @escaping (String) -> Void) {
        self.author = author
        self.text = text
        self.onReply = onReply
        _editable = State(initialValue: text)
    }

    private var chosen: String {
        guard let selection, case .selection(let range) = selection.indices, !range.isEmpty,
              range.lowerBound >= editable.startIndex, range.upperBound <= editable.endIndex else { return "" }
        return String(editable[range])
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $editable, selection: $selection)
                .font(Theme.Typography.message)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                // Selecting only: the words stay as they were.
                .onChange(of: editable) { _, now in if now != text { editable = text } }
                .navigationTitle("Reply to \(author)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Reply") {
                            onReply(chosen.isEmpty ? text : chosen)
                            dismiss()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text(chosen.isEmpty ? "Select the words to quote, or reply to all of it." : "Replying to the words you selected.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(12)
                }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 360)
        #endif
    }
}

#if os(iOS)
/// Select Text: a reply's words, to select any part of and copy. Read-only, so no keyboard comes
/// up and the menu has only what fits (Copy, Look Up, Share).
struct SelectTextSheet: View {
    let author: String
    /// The words as they read: inline Markdown (`**`, backticks, links) gone, lines and lists kept.
    private let words: String

    @Environment(\.dismiss) private var dismiss
    @State private var chosen = ""

    init(author: String, text: String) {
        self.author = author
        words = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? text
    }

    var body: some View {
        NavigationStack {
            ReadOnlyText(text: words, chosen: $chosen)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(chosen.isEmpty ? "Copy All" : "Copy") {
                            Pasteboard.copy(chosen.isEmpty ? words : chosen)
                            dismiss()
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("From \(author). Select any part of it to copy.")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(12)
                }
        }
    }
}

/// Selectable, not editable, text: what's selected comes back in `chosen`.
private struct ReadOnlyText: UIViewRepresentable {
    let text: String
    @Binding var chosen: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.text = text
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(chosen: $chosen) }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let chosen: Binding<String>

        init(chosen: Binding<String>) { self.chosen = chosen }

        func textViewDidChangeSelection(_ view: UITextView) {
            let range = view.selectedRange
            chosen.wrappedValue = range.length > 0 ? (view.text as NSString).substring(with: range) : ""
        }
    }
}
#endif

/// Swipe a message left to reply to it (`docs/inbox.md` §4): it follows the finger a little, an
/// arrow shows, and past the mark it lets go into the reply bar with a tick of haptics.
///
/// On iPhone and iPad the drag is UIKit's, begun only by a drag to the left: a SwiftUI drag on
/// each reply took the chat's vertical drags too, and the chat stopped scrolling.
struct SwipeToReply: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @State private var offset: CGFloat = 0
    @State private var replies = 0
    #if os(macOS)
    @State private var isHorizontal: Bool?
    /// Notices a drag that ends without `onEnded`, so the next one is decided afresh.
    @GestureState private var isDragging = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let mark: CGFloat = 64

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .offset(x: offset)
                .overlay(alignment: .trailing) {
                    if offset < -12 {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(-offset >= Self.mark ? Theme.primaryText : Theme.tertiaryText)
                            .offset(x: 30 + offset * 0.3)
                            .accessibilityHidden(true)
                    }
                }
                #if os(iOS)
                .gesture(SidewaysSwipePan(direction: .left, countsFromTouchDown: true, changed: follow, ended: { translation, _ in release(translation) }, cancelled: { release(0) }))
                #else
                .simultaneousGesture(drag)
                .background(SidewaysScrollReader(follow: follow, release: release))
                .environment(\.replySwipe, ReplySwipe(follow: follow, release: release))
                .onChange(of: isDragging) { _, dragging in
                    guard !dragging, isHorizontal != nil else { return }
                    isHorizontal = nil
                    release(0)
                }
                #endif
                .sensoryFeedback(.selection, trigger: replies)
        } else {
            content
        }
    }

    private func follow(_ translation: CGFloat) {
        offset = max(-Self.mark * 1.3, min(0, translation))
    }

    /// Past the mark it replies; either way the message springs back.
    private func release(_ translation: CGFloat) {
        if -translation >= Self.mark {
            replies += 1
            action()
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
    }

    #if os(macOS)
    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                if isHorizontal == nil {
                    let translation = CGPoint(x: value.translation.width, y: value.translation.height)
                    isHorizontal = SidewaysSwipe.begins(velocity: .zero, translation: translation, direction: .left)
                }
                guard isHorizontal == true else { return }
                follow(value.translation.width)
            }
            .onEnded { value in
                defer { isHorizontal = nil }
                guard isHorizontal == true else { return }
                release(value.translation.width)
            }
    }
    #endif
}

#if os(macOS)
/// A message's swipe to reply, for the words of a reply: their text view keeps the mouse's drags to
/// itself, so it hands a drag to the left on through these, as `SidewaysScrollReader` does a scroll.
struct ReplySwipe {
    let follow: (CGFloat) -> Void
    let release: (CGFloat) -> Void
}

extension EnvironmentValues {
    @Entry var replySwipe: ReplySwipe? = nil
}

/// A sideways scroll on a message (a trackpad's or a Magic Mouse's swipe, a mouse that scrolls
/// sideways) moves it as a drag does: SwiftUI has no scroll-wheel events, so this reads them from
/// the window before the chat does (`SidewaysScroll`, `docs/inbox.md` §4). It never takes a click.
private struct SidewaysScrollReader: NSViewRepresentable {
    let follow: (CGFloat) -> Void
    let release: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(follow: follow, release: release) }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.follow = follow
        view.release = release
    }

    static func dismantleNSView(_ view: ReaderView, coordinator: ()) { view.stop() }

    final class ReaderView: NSView {
        var follow: (CGFloat) -> Void
        var release: (CGFloat) -> Void
        private var scroll = SidewaysScroll()
        private var monitor: Any?
        /// Ends a mouse wheel's run of steps once they stop.
        private var quiet: Task<Void, Never>?

        init(follow: @escaping (CGFloat) -> Void, release: @escaping (CGFloat) -> Void) {
            self.follow = follow
            self.release = release
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            quiet?.cancel()
            quiet = nil
            scroll = SidewaysScroll()
        }

        /// The event, or nil once the scroll is the message's, so the chat doesn't move with it.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, let phase = Self.phase(of: event) else { return event }
            if phase == .began || (phase == .step && scroll.isIdle), !starts(at: event) {
                scroll.beganElsewhere()
                return event
            }
            // A wheel's steps are lines; a trackpad's are points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            let action = scroll.scroll(phase, delta: CGPoint(x: event.scrollingDeltaX * scale, y: event.scrollingDeltaY * scale))
            if phase == .step { waitForQuiet() }
            // The end always reaches the chat, so a scroll it saw begin doesn't stay open there.
            return apply(action) && phase != .ended && phase != .cancelled ? nil : event
        }

        /// Whether the action was the message's.
        private func apply(_ action: SidewaysScroll.Action) -> Bool {
            switch action {
            case .pass: return false
            case .follow(let x): follow(x); return true
            case .release(let x): release(x); return true
            case .absorb: return true
            }
        }

        private func waitForQuiet() {
            quiet?.cancel()
            quiet = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                _ = self.apply(self.scroll.idle())
            }
        }

        /// A scroll starts a swipe on this message only over it, and never over something inside
        /// it that scrolls sideways itself (a widget's strip of hours, a wide table).
        private func starts(at event: NSEvent) -> Bool {
            guard bounds.contains(convert(event.locationInWindow, from: nil)),
                  let root = window?.contentView else { return false }
            let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var scrollView = root.hitTest(point)?.enclosingScrollView
            while let current = scrollView {
                if let document = current.documentView, document.frame.width > current.contentView.bounds.width + 1 { return false }
                scrollView = current.enclosingScrollView
            }
            return true
        }

        private static func phase(of event: NSEvent) -> SidewaysScroll.Phase? {
            if !event.momentumPhase.isEmpty { return .momentum }
            let phase = event.phase
            if phase.isEmpty { return .step }
            if phase.contains(.began) { return .began }
            if phase.contains(.changed) { return .changed }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            // A finger resting on the trackpad (`mayBegin`) moves nothing yet.
            return nil
        }
    }
}
#endif
