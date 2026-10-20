import HermesKit
import SwiftUI

/// Sizes of the inbox rows and their marks (`blocks/inbox.elyx`): 62 pt rows on iPhone and iPad,
/// 46 pt with 13 pt type on the Mac (`docs/inbox.md` §2).
enum InboxMetrics {
    #if os(macOS)
    static let rowHeight: CGFloat = 46
    static let botRowHeight: CGFloat = 50
    static let faceSize: CGFloat = 32
    static let titleFont = Font.system(size: 13)
    static let unreadTitleFont = Font.system(size: 13, weight: .semibold)
    static let lineFont = Font.system(size: 11.5)
    static let timeFont = Font.system(size: 11)
    static let badgeFont = Font.system(size: 10.5, weight: .semibold)
    static let badgeHeight: CGFloat = 17
    static let glyphSize: CGFloat = 10
    static let lineSpacing: CGFloat = 2
    #else
    static let rowHeight: CGFloat = 62
    static let botRowHeight: CGFloat = 66
    static let faceSize: CGFloat = 44
    static let titleFont = Font.body
    static let unreadTitleFont = Font.body.weight(.semibold)
    static let lineFont = Font.subheadline
    static let timeFont = Font.footnote
    static let badgeFont = Font.caption.weight(.semibold)
    static let badgeHeight: CGFloat = 20
    static let glyphSize: CGFloat = 12
    static let lineSpacing: CGFloat = 3
    #endif
}

// MARK: - Badges

/// The unread count (`unreadBadge`): an ink capsule; grey when muted (`unreadBadgeMuted`). It
/// scales in with a spring and its digits roll as the count changes (`docs/inbox.md` §3).
struct UnreadCountBadge: View {
    let count: Int
    var muted = false
    /// Cut out of what's behind it (`unreadBadgeCutout`, the drawer button).
    var cutout = false

    var body: some View {
        Text(UnreadCounter.label(count))
            .font(InboxMetrics.badgeFont)
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(muted ? Theme.secondaryText : Theme.inkForeground)
            .padding(.horizontal, InboxMetrics.badgeHeight * 0.3)
            .frame(minWidth: InboxMetrics.badgeHeight, minHeight: InboxMetrics.badgeHeight)
            .background(muted ? Theme.controlFill : Theme.ink, in: Capsule())
            .background {
                if cutout {
                    Capsule().fill(Theme.canvas).padding(-2)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: count)
            .accessibilityHidden(true)
    }
}

/// Marked unread by hand (`unreadDot`).
struct UnreadMarkDot: View {
    var body: some View {
        Circle()
            .fill(Theme.ink)
            .frame(width: InboxMetrics.badgeHeight * 0.5, height: InboxMetrics.badgeHeight * 0.5)
            .accessibilityHidden(true)
    }
}

/// Hermes waits for you (`unreadBadgeNeedsYou`): orange, the raised hand.
struct NeedsYouBadge: View {
    var body: some View {
        Image(systemName: "hand.raised.fill")
            .font(.system(size: InboxMetrics.glyphSize, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: InboxMetrics.badgeHeight, height: InboxMetrics.badgeHeight)
            .background(Theme.warning, in: Circle())
            .accessibilityHidden(true)
    }
}

/// You were mentioned (`unreadBadgeMention`): an @ in ink.
struct MentionBadge: View {
    var body: some View {
        Image(systemName: "at")
            .font(.system(size: InboxMetrics.glyphSize, weight: .bold))
            .foregroundStyle(Theme.inkForeground)
            .frame(width: InboxMetrics.badgeHeight, height: InboxMetrics.badgeHeight)
            .background(Theme.ink, in: Circle())
            .accessibilityHidden(true)
    }
}

/// What a row says on the right: needs you first, then a mention, then the count or the dot.
struct RowTrailingMarks: View {
    let badge: UnreadBadge
    var muted = false
    var needsYou = false
    var mentioned = false

    var body: some View {
        HStack(spacing: 4) {
            if needsYou {
                NeedsYouBadge()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if mentioned {
                MentionBadge()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            switch badge {
            case .count(let count):
                UnreadCountBadge(count: count, muted: muted)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .dot:
                UnreadMarkDot()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .none:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: badge)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: needsYou)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: mentioned)
    }
}

// MARK: - Live

/// A turn is running (`chatRow.live`): a still ink dot in a soft halo. It marks the row; only the
/// activity line below moves (`docs/chat.md` §4a).
struct LiveDot: View {
    var body: some View {
        Circle()
            .fill(Theme.ink)
            .frame(width: 8, height: 8)
            .padding(3)
            .background(Theme.controlFill, in: Circle())
            .padding(-3)
            .accessibilityHidden(true)
    }
}

// MARK: - The activity line

extension ActivityLine {
    /// The words, the same everywhere: rows, the jump pill, the Live Activity (`docs/inbox.md` §2).
    var text: String {
        switch self {
        case .starting: String(localized: "Starting…")
        case .thinking: String(localized: "Thinking…")
        case .writing(let words): String(localized: "Writing: “\(words)”")
        case .tool(_, let title, let progress?): String(localized: "\(title) · \(progress.done) of \(progress.total)")
        case .tool(_, let title, nil): title
        case .helpers(let count): count == 1 ? String(localized: "1 helper working") : String(localized: "\(count) helpers working")
        case .waiting(.approval): String(localized: "Waiting for your approval")
        case .waiting(.question): String(localized: "Has a question")
        case .waiting(.key): String(localized: "Needs a key")
        case .failed(let reason): String(localized: "Stopped: \(reason)")
        case .routine(let name): String(localized: "\(name) · thinking…")
        }
    }

    /// Spoken after the title ("Hermes is running swift test").
    var spoken: String {
        switch self {
        case .starting, .thinking, .routine: String(localized: "Hermes is thinking")
        case .writing: String(localized: "Hermes is writing")
        case .tool(_, let title, _): String(localized: "Hermes: \(title)")
        case .helpers: text
        case .waiting(.approval): String(localized: "waiting for your approval")
        case .waiting(.question): String(localized: "has a question")
        case .waiting(.key): String(localized: "needs a key")
        case .failed: text
        }
    }

    var glyph: String? {
        switch self {
        case .tool(let symbol, _, _): symbol
        case .helpers: "person.2"
        case .waiting: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .starting, .thinking, .writing, .routine: nil
        }
    }

    var tint: Color {
        switch self {
        case .waiting: Theme.warning
        case .failed: Theme.danger
        default: Theme.secondaryText
        }
    }

    var needsYou: Bool {
        if case .waiting = self { return true }
        return false
    }
}

/// The line that replaces a row's preview while something happens (`activityLine` and its
/// variants): a glyph when it names the tool, helpers or a need, then the words, cross-fading as
/// they change. The words shimmer while Hermes works; waiting for you and stopped stay solid.
struct ActivityLineView: View {
    let line: ActivityLine
    var font = InboxMetrics.lineFont

    var body: some View {
        HStack(spacing: 7) {
            if let glyph = line.glyph {
                Image(systemName: glyph)
                    .font(.system(size: InboxMetrics.glyphSize, weight: .medium))
                    .foregroundStyle(line.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            if line.shimmers {
                ShimmerText(text: line.text, font: font, tone: .row)
                    .contentTransition(.opacity)
            } else {
                Text(line.text)
                    .font(font)
                    .foregroundStyle(line.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: line)
    }
}

// MARK: - Time

/// The time on a row: "now", "2 min", "14:21", "Yesterday", "Thu", "12 Oct". Rows from the last
/// hour tick each minute; older ones don't wake anything.
struct InboxTimeText: View {
    let date: Date
    var emphasized = false

    var body: some View {
        if Date.now.timeIntervalSince(date) < 3600 {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                label(InboxTime(date, now: context.date))
            }
        } else {
            label(InboxTime(date))
        }
    }

    private func label(_ time: InboxTime) -> some View {
        Text(Self.words(time))
            .font(InboxMetrics.timeFont)
            .monospacedDigit()
            .foregroundStyle(emphasized ? Theme.primaryText : Theme.tertiaryText)
            .lineLimit(1)
            .fixedSize()
    }

    static func words(_ time: InboxTime) -> String {
        switch time {
        case .now: String(localized: "now")
        case .minutes(let minutes): String(localized: "\(minutes) min")
        case .time(let date): date.formatted(date: .omitted, time: .shortened)
        case .yesterday: String(localized: "Yesterday")
        case .weekday(let date): date.formatted(.dateTime.weekday(.abbreviated))
        case .date(let date): date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    /// Spoken: "14:21", "yesterday".
    static func spoken(_ date: Date) -> String {
        switch InboxTime(date) {
        case .now: String(localized: "now")
        case .minutes(let minutes): String(localized: "\(minutes) minutes ago")
        default: words(InboxTime(date))
        }
    }
}
