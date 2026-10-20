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
                        .contentTransition(.numericText(value: Double(count)))
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
        case .newMessages(let count, _):
            count == 1 ? Text("1 new message. Jump to it.") : Text("\(count) new messages. Jump to the first one.")
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

/// Replying to a passage (`replyBar`): whose it is, the quote, and ✕. Sits in the composer.
struct ReplyBar: View {
    let author: String
    let quote: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(author)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(LastLine.flatten(quote))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop replying")
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .contain)
    }
}

/// The quote at the top of a reply (`quotedBubble`): who said it and one line of it. Tapping it
/// goes back to the passage when this device knows where it was.
struct QuotedBlock: View {
    let quote: String
    var author: String?
    var onTap: (() -> Void)?

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
        .background(Theme.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .gesture(SidewaysSwipePan(direction: .left, changed: follow, ended: { translation, _ in release(translation) }, cancelled: { release(0) }))
                #else
                .simultaneousGesture(drag)
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
