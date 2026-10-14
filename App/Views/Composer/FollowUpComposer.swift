import HermesKit
import SwiftUI
import UniformTypeIdentifiers

// The composer while Hermes works (docs/follow-ups.md, `blocks/follow-ups.elyx`): the mode chip
// and its menu, the queue tray, and the strip shown while a queued message is edited.

// MARK: - Mode chip and menu

/// Which kind of message Send makes while a turn runs (`modeChip`). It replaces Think, and opens
/// `modeMenu`; the keyboard steps aside while the menu is open.
struct FollowUpModeChip: View {
    @Bindable var conversation: ConversationModel
    var focused: Binding<Bool>

    @State private var showsMenu = false
    @State private var refocus = false
    /// Picks from the menu, for the tick (not the reset after each send).
    @State private var picks = 0

    private var mode: FollowUpMode { conversation.followUpMode }
    /// With nothing running, a queued message being edited can only go back in the queue.
    private var modes: [FollowUpMode] {
        conversation.isWorking ? conversation.availableFollowUpModes : [.sendNext]
    }
    private var isLocked: Bool { modes.count < 2 }

    var body: some View {
        Button {
            refocus = focused.wrappedValue
            focused.wrappedValue = false
            showsMenu = true
        } label: {
            ChipLabel(title: mode.title, symbol: mode.symbol, isActive: true, showsChevron: !isLocked)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isLocked)
        .fixedSize()
        .accessibilityLabel("Send mode")
        .accessibilityValue(mode.title)
        .help("Send mode")
        .popover(isPresented: $showsMenu, arrowEdge: .bottom) {
            FollowUpModeMenu(modes: modes, selected: mode) { picked in
                if conversation.editingQueued != nil {
                    conversation.followUpPick = picked == .sendNext ? nil : picked
                } else {
                    conversation.followUpPick = picked == FollowUpMode.preferredDefault ? nil : picked
                }
                showsMenu = false
                picks += 1
            }
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: showsMenu) { _, open in
            if !open, refocus { focused.wrappedValue = true }
        }
        .sensoryFeedback(.selection, trigger: picks)
    }
}

/// The modes, what each does, and where the default is set (`modeMenu`).
struct FollowUpModeMenu: View {
    let modes: [FollowUpMode]
    let selected: FollowUpMode
    let onPick: (FollowUpMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(modes) { mode in
                option(mode)
                if mode == .sendNext, modes.contains(.askAside) || modes.contains(.background) {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 1)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
            Text("Default for this chat: \(FollowUpMode.preferredDefault.title). Change it in Settings → Chat.")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 6, leading: 46, bottom: 6, trailing: 16))
        }
        .padding(.vertical, 6)
        .frame(width: 330)
    }

    private func option(_ mode: FollowUpMode) -> some View {
        Button {
            onPick(mode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.menuTitle)
                        .font(.body)
                        .foregroundStyle(Theme.primaryText)
                    Text(mode.detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 15)
                    .opacity(mode == selected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mode.menuTitle), \(mode.detail)")
        .accessibilityAddTraits(mode == selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A menu row that highlights while pressed (and on hover on the Mac).
private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? Theme.rowHover : .clear)
            .onHover { hovering = $0 }
    }
}

// MARK: - Queue tray

/// Messages waiting for the reply to finish (`queueTray`), in send order. Drag to reorder, tap
/// to edit, long-press (right-click) for more. What the gateway holds itself is listed first,
/// read-only.
struct QueueTray: View {
    let conversation: ConversationModel

    @State private var showsAll = false

    private static let visibleCount = 3

    private var held: [String] { conversation.gatewayQueued }
    private var items: [QueuedFollowUp] { conversation.queue }
    private var total: Int { held.count + items.count }
    private var isEditing: Bool { conversation.editingQueued != nil }

    /// Rows shown: the gateway's first, then the app's, up to three unless opened.
    private var shownItems: [QueuedFollowUp] {
        let room = showsAll ? Int.max : max(0, Self.visibleCount - held.count)
        return Array(items.prefix(room))
    }

    private var hiddenCount: Int {
        showsAll ? 0 : max(0, total - Self.visibleCount)
    }

    private var subtitle: String? {
        if isEditing { return nil }
        if conversation.queuePaused, !conversation.isWorking { return String(localized: "Send sends the first") }
        return String(localized: "sends when this reply is done")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(Array(held.prefix(showsAll ? held.count : Self.visibleCount).enumerated()), id: \.offset) { index, text in
                HeldRow(order: index + 1, text: text, gateway: conversation.gatewayName)
            }
            ForEach(shownItems) { item in
                let index = items.firstIndex(of: item) ?? 0
                // The message being edited keeps its number; the others keep theirs.
                let skipsEdited = conversation.editingQueued.map { index >= $0.index } ?? false
                QueueRow(
                    order: held.count + index + 1 + (skipsEdited ? 1 : 0),
                    item: item,
                    isFirst: index == 0,
                    isLast: index == items.count - 1,
                    conversation: conversation
                )
                .transition(ComposerView.rowAppears)
            }
            if hiddenCount > 0 {
                Button {
                    showsAll = true
                } label: {
                    Text("+\(hiddenCount) more")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Group {
                if let subtitle {
                    Text("Up next · \(subtitle)")
                } else {
                    Text("Up next")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !items.isEmpty, !isEditing {
                Button("Clear") {
                    conversation.clearQueue()
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the queue")
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One queued message (`queueItem`): its place, one line, a paperclip with attachments, a handle.
private struct QueueRow: View {
    let order: Int
    let item: QueuedFollowUp
    let isFirst: Bool
    let isLast: Bool
    let conversation: ConversationModel

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            OrderBadge(order: order)
            Text(item.line)
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.hasAttachments {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.placeholderText)
                .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
        .frame(minHeight: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .top) {
            // Where a dragged message lands.
            if isTargeted {
                Capsule().fill(Theme.primaryText.opacity(0.5)).frame(height: 2).offset(y: -4)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { conversation.editQueued(item) }
        .contextMenu { menu }
        .draggable(item.id.uuidString) {
            Text(item.line)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)),
                  let from = conversation.queue.firstIndex(where: { $0.id == id }),
                  let to = conversation.queue.firstIndex(where: { $0.id == item.id }), from != to
            else { return false }
            withAnimation(Theme.spring) {
                conversation.moveQueued(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.hasAttachments ? Text("\(order). \(item.line), with attachments") : Text("\(order). \(item.line)"))
        .accessibilityHint("Edits the message")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { conversation.editQueued(item) }
        .accessibilityActions {
            if !isFirst {
                Button("Move up") { conversation.moveQueued(item, by: -1) }
            }
            if !isLast {
                Button("Move down") { conversation.moveQueued(item, by: 1) }
            }
            if conversation.isWorking {
                Button("Steer Now") { conversation.steerNow(item) }
            }
            Button("Remove") { conversation.removeQueued(item) }
        }
    }

    /// `queueItemMenu`.
    @ViewBuilder
    private var menu: some View {
        Button("Edit", systemImage: "pencil") { conversation.editQueued(item) }
        if conversation.isWorking {
            Button("Steer Now", systemImage: "arrow.turn.up.right") { conversation.steerNow(item) }
        } else {
            Button("Send Now", systemImage: "arrow.up") { conversation.sendQueued(item) }
        }
        if !isFirst {
            Button("Move to Top", systemImage: "arrow.up.to.line") { withAnimation(Theme.spring) { conversation.moveQueuedToTop(item) } }
        }
        Divider()
        Button("Remove", systemImage: "trash", role: .destructive) { conversation.removeQueued(item) }
    }
}

/// A message the gateway holds for the next turn itself: read-only, marked with where it is.
private struct HeldRow: View {
    let order: Int
    let text: String
    let gateway: String

    var body: some View {
        HStack(spacing: 10) {
            OrderBadge(order: order)
            Text(text.split(whereSeparator: \.isNewline).joined(separator: " "))
                .font(.subheadline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("on \(gateway)")
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10))
        .frame(minHeight: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Waiting on \(gateway); it can't be changed here")
    }
}

private struct OrderBadge: View {
    let order: Int

    var body: some View {
        Text("\(order)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .monospacedDigit()
            .frame(width: 20, height: 20)
            .background(Theme.surfaceRaised, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Strips

/// What Send does with the text in the field when it isn't a new message (`composerEditing`,
/// `composerQueueEditing`), and ✕ to stop.
struct ComposerStrip: View {
    let symbol: String
    let text: String
    let closeLabel: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeLabel)
        }
        .padding(.horizontal, 6)
    }
}
