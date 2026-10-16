import HermesKit
import HermesPush
import SwiftUI

// The pieces of a group chat (`blocks/groups.elyx`).

/// Two member faces overlapping, a sliver of space cut around the front one along its own outline
/// (`groupAvatar`), so it reads on any row, selected or not; or the room's own picture
/// (`groupAvatarPicture`).
struct GroupAvatar: View {
    var front: BotAppearance?
    var back: BotAppearance?
    var picture: PlatformImage?
    var size: CGFloat = 40

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
                    if let front {
                        FaceHalo(appearance: front, size: size * 0.65, width: 5)
                            .offset(y: size * 0.3)
                            .blendMode(.destinationOut)
                        BotFace(appearance: front, size: size * 0.65)
                            .offset(y: size * 0.3)
                    }
                }
                .compositingGroup()
                .frame(width: size, height: size, alignment: .topLeading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A face's silhouette grown by `width` face units: what's erased around a face laid over another.
struct FaceHalo: View {
    let appearance: BotAppearance
    let size: CGFloat
    var width: CGFloat = 4

    var body: some View {
        Canvas { context, canvasSize in
            if appearance.imageURL != nil {
                // Photo faces are rounded squares (22% radius) at the top of the face box.
                let side = canvasSize.width
                let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: -width * side / 80, dy: -width * side / 80)
                context.fill(Path(roundedRect: rect, cornerRadius: side * 0.22 + width * side / 80, style: .continuous), with: .color(.black))
            } else {
                let scale = canvasSize.width / 40
                context.scaleBy(x: scale, y: scale)
                let body = FacePainter.body(appearance.shape)
                context.fill(body, with: .color(.black))
                context.stroke(body, with: .color(.black), style: StrokeStyle(lineWidth: width, lineJoin: .round))
            }
        }
        .frame(width: size, height: FacePainter.height(forWidth: size))
        .accessibilityHidden(true)
    }
}

/// Everyone in a group chat, side by side (`docs/bot-faces.md` §5.2): the member whose turn is
/// running lifts with a 4° tilt and thinks, and the others look at it. One that passed blinks and
/// looks back to centre. When a member's message hands work to another (`@handle`), the two look
/// at each other for 0.6 s, then the one receiving it starts thinking (§5.8).
struct GroupFaceStack: View {
    struct Face: Identifiable {
        let id: String
        let appearance: BotAppearance
    }

    let faces: [Face]
    var active: String?
    var passed: Set<String> = []
    var handOff: (from: String, to: String, seq: Int)?
    var size: CGFloat = 22

    @State private var lookingAtEachOther: (from: String, to: String)?
    @State private var receiving: String?
    @State private var blinks: [String: Int] = [:]
    @State private var seenHandOff: Int?

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(Array(faces.enumerated()), id: \.element.id) { index, face in
                let isActive = face.id == (active ?? receiving)
                BotFace(
                    appearance: face.appearance, size: size, mood: isActive ? .thinking : .idle,
                    look: look(for: index), blinks: blinks[face.id] ?? 0
                )
                .rotationEffect(.degrees(isActive ? 4 : 0), anchor: .bottom)
                .offset(y: isActive ? -size * 0.12 : 0)
                .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isActive)
            }
        }
        .onChange(of: passed) { old, new in
            for member in new.subtracting(old) { blinks[member, default: 0] += 1 }
        }
        .task(id: handOff?.seq) {
            // Only hand-offs that happen while the room is open, not the one it opened on.
            guard let seenHandOff else {
                seenHandOff = handOff?.seq ?? -1
                return
            }
            guard let handOff, handOff.seq > seenHandOff else { return }
            self.seenHandOff = handOff.seq
            lookingAtEachOther = (handOff.from, handOff.to)
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            lookingAtEachOther = nil
            receiving = handOff.to
            try? await Task.sleep(for: .seconds(3))
            if receiving == handOff.to { receiving = nil }
        }
        .onChange(of: active) { if active != nil { receiving = nil } }
        .accessibilityHidden(true)
    }

    private func index(of id: String?) -> Int? {
        id.flatMap { id in faces.firstIndex { $0.id == id } }
    }

    /// Toward the face that has the floor, or at each other during a hand-off.
    private func look(for index: Int) -> CGVector? {
        let id = faces[index].id
        if let pair = lookingAtEachOther, let from = self.index(of: pair.from), let to = self.index(of: pair.to) {
            if id == pair.from { return CGVector(dx: to > from ? 1 : -1, dy: 0) }
            if id == pair.to { return CGVector(dx: from > to ? 1 : -1, dy: 0) }
        }
        if passed.contains(id) { return nil }
        guard let target = self.index(of: active ?? receiving), target != index else { return nil }
        return CGVector(dx: target > index ? 1 : -1, dy: -0.3)
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
    /// Toward the member that's replying (`docs/bot-faces.md` §5.2).
    var look: CGVector?

    @State private var blinks = 0

    var body: some View {
        HStack(spacing: 10) {
            if let appearance {
                BotFace(appearance: appearance, size: 30, mood: status == .replying ? .thinking : .idle, look: look, blinks: blinks)
                    .onChange(of: status) { _, new in if new == .passed { blinks += 1 } }
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
