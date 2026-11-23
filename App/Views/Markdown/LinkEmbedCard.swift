import HermesMarkdown
import SwiftUI

/// A paragraph that is only a link the app knows by its address (`LinkEmbed`, `docs/chat.md` §3d):
/// its card, or its words while the reply may still be writing it and inside a list or a quote.
struct LinkEmbedParagraph<Words: View>: View {
    let embed: LinkEmbed
    @ViewBuilder let words: Words
    @Environment(\.markdownOpenTail) private var isArriving
    @Environment(\.markdownLinkCards) private var showsCards

    var body: some View {
        if isArriving || !showsCards {
            words
        } else {
            LinkEmbedCard(embed: embed)
        }
    }
}

extension EnvironmentValues {
    /// Off in lists and quotes, where a link stays words.
    @Entry var markdownLinkCards = true
}

/// The card itself, made from the address and the reply's words alone: nothing is fetched, and the
/// service hears of it only when a tap opens it in the browser, through the reply's link gate.
private struct LinkEmbedCard: View {
    let embed: LinkEmbed
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button { openURL(embed.url) } label: {
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) { glyph; words }
                        open
                    }
                } else {
                    HStack(spacing: 10) {
                        glyph
                        words
                        Spacer(minLength: 8)
                        open
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 480, alignment: .leading)
            .background(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .modifier(VoiceOverLandingTarget())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail].joined(separator: ", "))
        .accessibilityHint("Opens in the browser")
        .accessibilityAddTraits(.isLink)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAction { openURL(embed.url) }
    }

    private var glyph: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(Theme.primaryText)
            .frame(width: 36, height: 36)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                .multilineTextAlignment(.leading)
            Text(verbatim: detail)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
        }
    }

    private var open: some View {
        Text("Open")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .background(Theme.controlFill, in: Capsule())
            .accessibilityHidden(true)
    }

    private var title: String {
        embed.label ?? embed.name ?? String(localized: "\(embed.service.name) \(kind.lowercased())")
    }

    /// Where it goes: always from the address, so the reply's words can't pass one page off as another.
    private var detail: String {
        let parts: [String]
        if embed.label != nil {
            parts = [embed.service.name, kind, embed.name ?? ""]
        } else if embed.name != nil {
            parts = [embed.service.name, kind]
        } else {
            let address = embed.url.absoluteString
            parts = [address.hasPrefix("https://") ? String(address.dropFirst(8)) : address]
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var kind: String {
        switch embed.kind {
        case .video: String(localized: "Video")
        case .short: String(localized: "Short")
        case .live: String(localized: "Live video")
        case .playlist: String(localized: "Playlist")
        case .track: String(localized: "Track")
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .episode: String(localized: "Episode")
        case .show: String(localized: "Show")
        case .repository: String(localized: "Repository")
        case .issue(let number): String(localized: "Issue #\(String(number))")
        case .pullRequest(let number): String(localized: "Pull request #\(String(number))")
        case .discussion(let number): String(localized: "Discussion #\(String(number))")
        }
    }

    private var symbol: String {
        switch embed.kind {
        case .video, .short, .live: "play.rectangle"
        case .playlist: embed.service == .youtube ? "play.rectangle.on.rectangle" : "music.note.list"
        case .track: "music.note"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .episode, .show: "mic"
        case .repository: "chevron.left.forwardslash.chevron.right"
        case .issue: "smallcircle.filled.circle"
        case .pullRequest: "arrow.triangle.pull"
        case .discussion: "bubble.left.and.bubble.right"
        }
    }
}
