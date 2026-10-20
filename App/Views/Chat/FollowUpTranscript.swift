import HermesKit
import SwiftUI

// What became of messages sent while Hermes worked (docs/follow-ups.md, `blocks/follow-ups.elyx`):
// captioned bubbles, the redirect mark, a missed steer, a background run.

/// The person's message with a line above it saying how it was sent and what happened to it
/// (`followUpBubble*`). Dashed while a steer is still unread.
struct FollowUpBubble: View {
    let text: String
    let caption: FollowUpBubbleCaption
    var isPending = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            FollowUpCaptionLine(caption: caption)
            Text(text)
                .font(Theme.Typography.message)
                .lineSpacing(Theme.Typography.messageLineSpacing)
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
                        .strokeBorder(Theme.placeholderText, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .opacity(isPending ? 1 : 0)
                }
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
                }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
        .animation(.smooth(duration: 0.32), value: isPending)
        .animation(.smooth(duration: 0.32), value: caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(caption.spoken): \(text)"))
    }
}

/// "↪ Steer · read after “Listed snapshots”". While it waits, the bubble's dashed border says so.
struct FollowUpCaptionLine: View {
    let caption: FollowUpBubbleCaption

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: caption.symbol)
                .font(.system(size: 10.5, weight: .medium))
            Text(caption.text)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .foregroundStyle(Theme.tertiaryText)
        .padding(.horizontal, 6)
        .accessibilityHidden(true)
    }
}

extension FollowUpBubbleCaption {
    /// Read before the message: "Steer, read after Listed snapshots".
    var spoken: String {
        text.replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
    }

    /// A steer Hermes read, and the step it read it after.
    static func steerRead(after step: String?) -> FollowUpBubbleCaption {
        let text = step.map { String(localized: "Steer · read after “\($0)”") } ?? String(localized: "Steer · read")
        return FollowUpBubbleCaption(symbol: FollowUpMode.steer.symbol, text: text)
    }
}

/// A stored message that was sent mid-turn: its caption over the usual bubble, and before a
/// redirect the mark where the turn changed course.
struct CaptionedUserRow<Bubble: View>: View {
    let caption: FollowUpCaption
    @ViewBuilder let bubble: () -> Bubble

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if case .redirect(let stoppedWhile) = caption {
                RedirectMark(stoppedWhile: stoppedWhile)
            }
            VStack(alignment: .trailing, spacing: 4) {
                FollowUpCaptionLine(caption: caption.bubble)
                bubble()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: caption.bubble.spoken))
        }
    }
}

/// Where a redirect cut the turn (`redirectMark`): "Changed course · Stopped while …".
struct RedirectMark: View {
    let stoppedWhile: String?

    var body: some View {
        HStack(spacing: 8) {
            TagLabel(title: String(localized: "Changed course"), symbol: FollowUpMode.redirect.symbol)
            if let stoppedWhile {
                Text("Stopped while \(stoppedWhile).")
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The turn ended before Hermes read a steer, or Hermes refused it (`steerMissed`). Nothing is
/// sent without asking.
struct SteerMissedCard: View {
    let text: String
    var title = String(localized: "Hermes finished before reading your note")
    var sendTitle = String(localized: "Send as Message")
    /// Where it sits: at the person's side in the chat; full width in a helper's card.
    var alignment: Alignment = .trailing
    let onDiscard: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: FollowUpMode.steer.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.secondaryText)
            Text("“\(text)”")
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(MissedButtonStyle(isInk: false))
                Button(action: onSend) {
                    Text(sendTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(MissedButtonStyle(isInk: true))
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: 460, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .contain)
    }
}

private struct MissedButtonStyle: ButtonStyle {
    let isInk: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isInk ? Theme.inkForeground : Theme.primaryText)
            .background(isInk ? Theme.ink : Theme.surfaceRaised, in: Capsule())
            .overlay { if !isInk { Capsule().strokeBorder(Theme.hairline) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Run in Background, working (`backgroundStarted`): a quiet line that shimmers until the answer's
/// card. No spinner (`docs/chat.md` §4a).
struct BackgroundStartedLine: View {
    let prompt: String

    var body: some View {
        ShimmerText(text: String(localized: "Working in the background: \(Self.lowercasedFirst(prompt))"), font: .footnote, tone: .row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private static func lowercasedFirst(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard let first = line.first, first.isUppercase, line.dropFirst().first?.isLowercase ?? true else { return line }
        return first.lowercased() + line.dropFirst()
    }
}

/// A mid-turn message not settled into the transcript yet: a steer carried to the next turn, a
/// missed one, a background run.
struct FollowUpRecordRow: View {
    let record: FollowUpRecord
    let conversation: ConversationModel

    var body: some View {
        switch record.state {
        case .steerMissed:
            SteerMissedCard(
                text: record.text,
                onDiscard: { withAnimation(Theme.spring) { conversation.discardMissed(record) } },
                onSend: { withAnimation(Theme.spring) { conversation.sendMissed(record) } }
            )
        case .background(let answer):
            VStack(alignment: .leading, spacing: 12) {
                if let caption = record.caption {
                    FollowUpBubble(text: record.text, caption: caption)
                }
                Group {
                    if let answer {
                        BackgroundCard(prompt: record.text, answer: answer)
                    } else {
                        BackgroundStartedLine(prompt: record.text)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
            .animation(.smooth(duration: 0.32), value: answer)
        case .steerWaiting, .steerCarriedOver:
            if let caption = record.caption {
                FollowUpBubble(text: record.text, caption: caption, isPending: true)
            }
        }
    }
}
