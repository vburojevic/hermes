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

    @State private var previewing: ImageAttachment?
    @State private var previewingSkill: String?
    @Environment(\.references) private var references

    /// What the message is made of: kept from when this app sent it, or read from text that
    /// came from elsewhere (leading `/skill`s, known `@handles`, `@file:` paths).
    private var parts: MessageParts {
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
            if hasText || !parts.skills.isEmpty || !entry.fileNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
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
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .contextMenu {
                    // `Overlays.userMessageMenu`.
                    // The plain form: `@writer`, `@file:path`, `/skill` prefixes.
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("You: \(spokenText)"))
        .accessibilityHint(entry.fileNames.isEmpty ? Text(verbatim: "") : Text("With \(entry.fileNames.formatted(.list(type: .and)))"))
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
/// decoded and downsampled off the main thread, once.
private struct RemoteThumbnail: View {
    let source: String

    @State private var decoded: PlatformImage?

    var body: some View {
        Group {
            if source.hasPrefix("data:") {
                if let image = decoded {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    Theme.surface
                }
            } else if let url = URL(string: source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.surface
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
