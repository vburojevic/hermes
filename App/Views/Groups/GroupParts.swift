import HermesKit
import SwiftUI

// The pieces of a group chat (`blocks/groups.elyx`).

/// Two member faces overlapping, the front one cut out of the background (`groupAvatar`); or
/// the room's own picture (`groupAvatarPicture`).
struct GroupAvatar: View {
    var front: BotAppearance?
    var back: BotAppearance?
    var picture: PlatformImage?
    var size: CGFloat = 40
    var cutout: Color = Theme.sidebar

    var body: some View {
        Group {
            if let picture {
                Image(platformImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack(alignment: .topLeading) {
                    if let back {
                        BotFace(appearance: back, size: size * 0.65)
                            .offset(x: size * 0.35)
                    }
                    Circle()
                        .fill(cutout)
                        .frame(width: size * 0.75, height: size * 0.75)
                        .offset(x: -size * 0.05, y: size * 0.25)
                    if let front {
                        BotFace(appearance: front, size: size * 0.65)
                            .offset(y: size * 0.3)
                    }
                }
                .frame(width: size, height: size, alignment: .topLeading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A group chat in the roster (`groupRow`): avatar, name, member count, the latest line, time,
/// and "Needs you" when the room waits on the person.
struct GroupRowLabel: View {
    let name: String
    let memberCount: Int
    var preview: String?
    var date: Date?
    var needsYou = false
    let avatar: GroupAvatar

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(name)
                        .font(SidebarMetrics.nameFont)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text("\(memberCount) Bots")
                        .font(SidebarMetrics.previewFont)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(SidebarMetrics.previewFont)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(needsYou ? 2 : 1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                if let date {
                    Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
                        .font(SidebarMetrics.previewFont)
                        .foregroundStyle(Theme.secondaryText)
                }
                if needsYou {
                    TagLabel(title: String(localized: "Needs you"), style: .warning)
                        .fixedSize()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A member's message (`memberMessage`): face, name (with "Lead"), time, then the text.
struct MemberMessageRow: View {
    let appearance: BotAppearance?
    let name: String
    var isLead = false
    var date: Date?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let appearance {
                    BotFace(appearance: appearance, size: 28)
                } else {
                    Circle().fill(Theme.surfaceRaised).frame(width: 28, height: 28)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    if isLead {
                        TagLabel(title: String(localized: "Lead"))
                    }
                    if let date {
                        Text(date, format: .dateTime.hour().minute())
                            .font(.caption)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                MarkdownView(text: text)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A member had nothing new to add this round (`memberPassed`).
struct MemberPassedRow: View {
    let appearance: BotAppearance?
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            if let appearance {
                BotFace(appearance: appearance, size: 16)
            }
            Text("\(name) passed")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Round 2 of 3", "Room settled · 2 rounds" between turns (`roundDivider`).
struct RoundDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A member's live status in Activity (`memberStatusRow`).
struct MemberStatusRow: View {
    enum Status: Equatable {
        case replied, passed, replying, paused, waiting

        var tag: (String, String, TagLabel.Style) {
            switch self {
            case .replied: (String(localized: "Replied"), "checkmark", .success)
            case .passed: (String(localized: "Passed"), "minus", .neutral)
            case .replying: (String(localized: "Replying…"), "ellipsis", .warning)
            case .paused: (String(localized: "Paused"), "pause.fill", .neutral)
            case .waiting: (String(localized: "Waiting"), "clock", .neutral)
            }
        }
    }

    let appearance: BotAppearance?
    let name: String
    var subtitle: String?
    let status: Status

    var body: some View {
        HStack(spacing: 10) {
            if let appearance {
                BotFace(appearance: appearance, size: 30, mood: status == .replying ? .thinking : .idle)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            let tag = status.tag
            TagLabel(title: tag.0, symbol: tag.1, style: tag.2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Pick a member (`memberPickRow`): checkbox circle, face, name, @handle and role.
struct MemberPickRow: View {
    let appearance: BotAppearance
    let name: String
    let handle: String
    var role: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Theme.primaryText : Theme.placeholderText)
                    .contentTransition(.symbolEffect(.replace))
                BotFace(appearance: appearance, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text([("@" + handle), role].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Member faces side by side (`memberStack`).
struct MemberStack: View {
    let appearances: [BotAppearance]
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.18) {
            ForEach(Array(appearances.prefix(6).enumerated()), id: \.offset) { _, appearance in
                BotFace(appearance: appearance, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}
