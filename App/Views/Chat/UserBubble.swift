import HermesKit
import SwiftUI

/// The person's message: trailing, in a soft bubble, with any images above it.
struct UserBubble: View {
    let entry: UserEntry
    let images: [ImageAttachment]
    /// For the message menu (Edit and Resend, Send Again, Branch from Here); `nil` in Bot Chats.
    var conversation: ConversationModel?
    /// Emoji Hermes put on this message.
    var reactions: [String] = []
    /// The bubble's colour: the surface, or the canvas where it sits on a surface (the welcome
    /// tour's card on iPad and the Mac).
    var fill = Theme.surface

    @State private var previewing: ImageAttachment?
    @State private var previewingSkill: String?
    @Environment(\.references) private var references
    @Environment(\.quoteActions) private var quoteActions

    /// A reply with a quote (`quotedBubble`): the passage, drawn as a block, never as ">".
    private var quoted: QuotedReply? {
        QuotedReply.parse(entry.parts?.body ?? entry.text)
    }

    /// What the message is made of: kept from when this app sent it, or read from text that
    /// came from elsewhere (leading `/skill`s, known `@handles`, `@file:` paths).
    private var parts: MessageParts {
        var parts = wholeParts
        // The quote is drawn above; the bubble's words are what came after it.
        if let quoted, parts.body.hasSuffix(quoted.message) {
            let cut = parts.body.utf16.count - quoted.message.utf16.count
            parts.body = quoted.message
            parts.references = parts.references.compactMap { reference in
                var moved = reference
                moved.location -= cut
                return moved.location >= 0 ? moved : nil
            }
        }
        return parts
    }

    private var wholeParts: MessageParts {
        if let parts = entry.parts, parts.command == nil { return parts }
        if !entry.skillNames.isEmpty {
            return MessageParts(body: entry.text, references: references.vocabulary.references(in: entry.text), skills: entry.skillNames)
        }
        let parsed = references.parts(of: entry.text)
        return parsed.command == nil ? parsed : MessageParts(body: entry.text)
    }

    private var spokenText: String {
        let skills = parts.skills.map { String(localized: "Skill, \($0)") }
        let body = parts.segments.map {
            switch $0 {
            case .text(let text): text
            case .reference(let reference): reference.spokenLabel(bot: reference.kind == .bot ? references.bot(handle: reference.value) : nil)
            }
        }
        .joined()
        return (skills + [body]).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var missingImageCount: Int {
        max(0, entry.imagePlaceholderCount - images.count)
    }

    /// Just sent (pending, or stamped in the last few seconds): its mention pills blink once.
    private var isFresh: Bool {
        entry.timestamp.map { Date.now.timeIntervalSince($0) < 8 } ?? true
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !images.isEmpty {
                imageGrid
            }
            if !entry.inlineImageURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(entry.inlineImageURLs, id: \.self) { url in
                            RemoteThumbnail(source: url)
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                .scrollBounceBehavior(.basedOnSize)
            }
            if missingImageCount > 0 {
                Label(
                    missingImageCount == 1 ? String(localized: "1 image") : String(localized: "\(missingImageCount) images"),
                    systemImage: "photo"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.surface, in: Capsule())
            }
            let parts = parts
            let hasText = !parts.body.isEmpty
            if let path = entry.voicePath {
                // A voice message (`voiceMessage`, `docs/voice.md` §2): the transcript is its text.
                VoiceMessageBubble(entry: entry, path: path, fill: fill)
            } else if hasText || !parts.skills.isEmpty || !entry.fileNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if let quoted {
                        let source = QuoteMemory.source(of: quoted.quote, chat: quoteActions.chat)
                        QuotedBlock(quote: quoted.quote, author: source?.author, onTap: source.map { source in { quoteActions.jump(source.rowID) } })
                            .padding(.horizontal, -6)
                    }
                    if !parts.skills.isEmpty || !entry.fileNames.isEmpty {
                        // Skills, then files (`richBubble`): they apply to the whole message.
                        FlowLayout(spacing: 6) {
                            ForEach(parts.skills, id: \.self) { name in
                                SkillChip(name: name)
                                    .onTapGesture { previewingSkill = name }
                                    .popover(isPresented: Binding(get: { previewingSkill == name }, set: { if !$0 { previewingSkill = nil } })) {
                                        ReferencePreviewCard(item: .skill(name)) { previewingSkill = nil }
                                            .environment(\.references, references)
                                            .presentationCompactAdaptation(.popover)
                                    }
                            }
                            ForEach(Array(entry.fileNames.enumerated()), id: \.offset) { _, name in
                                SentFileChip(name: name)
                            }
                        }
                    }
                    if hasText {
                        // Not selectable: the message menu (Copy, Edit and Resend…) owns the
                        // long press and the right click. Bots and files sit inline as pills
                        // (`richBubbleRefs`).
                        Group {
                            if parts.references.isEmpty {
                                Text(parts.body)
                                    .font(Theme.Typography.message)
                                    .lineSpacing(Theme.Typography.messageLineSpacing)
                            } else {
                                InlineFlow(parts: parts)
                                    .environment(\.mentionsBlinkOnAppear, isFresh)
                            }
                        }
                        .foregroundStyle(Theme.primaryText)
                    }
                }
                .padding(.horizontal, hasText ? 16 : 10)
                .padding(.vertical, hasText ? 11 : 10)
                .padding(.top, parts.skills.isEmpty && entry.fileNames.isEmpty ? 0 : -1)
                .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .contextMenu {
                    // `Overlays.userMessageMenu`.
                    // The plain form: `@writer`, `@file:path`, `/skill` prefixes.
                    if quoteActions.isEnabled, hasText, !entry.id.hasPrefix("local-") {
                        Button("Reply", systemImage: "arrowshape.turn.up.left") {
                            quoteActions.reply(.user(entry), String(localized: "You"), parts.plainText)
                        }
                    }
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(parts.plainText) }
                    if let conversation, !entry.id.hasPrefix("local-") {
                        if conversation.canBranchFromPoint {
                            Button("Edit and Resend", systemImage: "pencil") { conversation.beginEditing(entry) }
                        }
                        Button("Send Again", systemImage: "arrow.clockwise") { conversation.sendAgain(entry) }
                        if conversation.canBranchFromPoint {
                            Button("Branch from Here", systemImage: "arrow.triangle.branch") { conversation.branch(at: .through(entry.id)) }
                        }
                    }
                    ShareLink(item: parts.plainText)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !reactions.isEmpty {
                ReactionPill(emoji: reactions)
                    .offset(x: -8, y: 22)
            }
        }
        .padding(.bottom, reactions.isEmpty ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .modifier(MessageAccessibility(
            // A voice message speaks for itself: its length, its transcript, play and scrub.
            isVoice: entry.voicePath != nil,
            label: quoted.map { Text("You, quoting “\(LastLine.flatten($0.quote))”: \(spokenText)") } ?? Text("You: \(spokenText)"),
            hint: entry.fileNames.isEmpty ? Text(verbatim: "") : Text("With \(entry.fileNames.formatted(.list(type: .and)))")
        ))
        .sheet(item: $previewing) { image in
            ImagePreview(image: image)
        }
    }

    /// One image large; two side by side; three or four in a two-column grid. Tiles shrink to
    /// fit narrow widths instead of running off the screen.
    @ViewBuilder
    private var imageGrid: some View {
        if images.count == 1, let image = images.first {
            tile(image, maxSide: 220)
        } else if images.count == 2 {
            HStack(spacing: 8) {
                ForEach(images) { tile($0, maxSide: 140) }
            }
        } else {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: images.count, by: 2)), id: \.self) { start in
                    GridRow {
                        ForEach(images[start..<min(start + 2, images.count)]) { tile($0, maxSide: 120) }
                    }
                }
            }
        }
    }

    private func tile(_ image: ImageAttachment, maxSide: CGFloat) -> some View {
        Button {
            previewing = image
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: maxSide)
                .overlay {
                    Image(platformImage: image.preview)
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Attached image")
    }
}

/// The message as one VoiceOver element, read as "You: …".
private struct MessageAccessibility: ViewModifier {
    let isVoice: Bool
    let label: Text
    let hint: Text

    func body(content: Content) -> some View {
        if isVoice {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityHint(hint)
        }
    }
}

/// A file that went with the message.
private struct SentFileChip: View {
    let name: String

    private var symbol: String {
        name.lowercased().hasSuffix(".pdf") ? "doc.richtext.fill" : "doc.text"
    }

    var body: some View {
        Label {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(maxWidth: 240)
        .background(Theme.surfaceRaised, in: Capsule())
        .accessibilityLabel(Text("Attached file \(name)"))
    }
}

/// Images still present in stored content as `data:` or `https:` URLs. Inline images are
/// decoded and downsampled off the main thread, once. One from anywhere but the gateway waits
/// for a tap (`WebLink.isOnGateway`).
private struct RemoteThumbnail: View {
    let source: String

    @Environment(\.gatewayHosts) private var gatewayHosts
    @State private var decoded: PlatformImage?
    @State private var fetches = false

    var body: some View {
        Group {
            if source.hasPrefix("data:") {
                if let image = decoded {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Theme.surface
                }
            } else if let url = URL(string: source), WebLink.loadsByItself(url) {
                if fetches || WebLink.isOnGateway(url, gatewayHosts: gatewayHosts) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.surface
                    }
                } else {
                    Button { fetches = true } label: {
                        Image(systemName: "photo")
                            .foregroundStyle(Theme.tertiaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.surface)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Show Image from \(url.host() ?? "")"))
                }
            }
        }
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: source) {
            guard source.hasPrefix("data:"), decoded == nil else { return }
            decoded = await FaceImageCache.prepare(dataURL: source, key: "inline:\(source.hashValue)", maxPixelSize: 360)
        }
    }
}

/// Full-size view of a sent image.
struct ImagePreview: View {
    let image: ImageAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Image(platformImage: image.preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
    }
}

/// Under a message of yours the gateway hasn't taken yet: "Sending…", then "Waiting for <Mac>…" once
/// it's away or busy. A wait, not an error: the message goes when it can, and Stop takes it back
/// meanwhile (`docs/chat.md` §4).
struct PendingSendLine: View {
    let isWaiting: Bool
    /// The gateway's name ("MacBook Pro").
    let gateway: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .imageScale(.small)
            if isWaiting {
                Text("Waiting for \(gateway)…")
            } else {
                Text("Sending…")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryText)
        .contentTransition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isWaiting ? Text("Not sent yet, waiting for \(gateway)") : Text("Sending"))
    }
}
