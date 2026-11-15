import HermesKit
import SwiftUI

// MARK: - Filters

/// The list's filter menu (`docs/inbox.md` §5): which chats show, then Only Unread, Needs You or
/// Running, then Mark All as Read. The sidebar's filter button, iPhone's bottom bar and the Mac's
/// View ▸ Filter menu all show it.
struct InboxFilterMenuContent: View {
    @Bindable var workspace: BotWorkspace

    var body: some View {
        Section("Show") {
            Picker("Show", selection: $workspace.inboxShow) {
                ForEach(InboxShow.allCases, id: \.self) { show in
                    Label(show.title, systemImage: show.symbol).tag(show)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Only") {
            ForEach([InboxFilter.unread, .needsYou, .running], id: \.self) { filter in
                Toggle(isOn: only(filter)) {
                    Text(filter.title)
                    let count = workspace.count(for: filter)
                    if count > 0 { Text("\(count)") }
                }
            }
        }
        Section {
            Button("Mark All as Read", systemImage: "envelope.open") {
                Task { await workspace.unread.markAllRead(workspace.unreadChatKeys) }
            }
            .disabled(workspace.unreadChatKeys.isEmpty)
        }
    }

    /// One filter on at a time; turning the one that's on off shows everything again.
    private func only(_ filter: InboxFilter) -> Binding<Bool> {
        Binding {
            workspace.inboxFilter == filter
        } set: { on in
            workspace.inboxFilter = on ? filter : .all
        }
    }
}

/// The filter button: filled for any choice but the default (This App, nothing narrowed), so a
/// narrowed list is never a surprise, and saying both choices in VoiceOver.
struct InboxFilterButton: View {
    @Bindable var workspace: BotWorkspace

    private var isNarrowed: Bool {
        workspace.inboxShow != .thisApp || workspace.inboxFilter != .all
    }

    private var value: String {
        workspace.inboxFilter == .all
            ? workspace.inboxShow.title
            : "\(workspace.inboxShow.title), \(workspace.inboxFilter.title)"
    }

    var body: some View {
        Menu {
            InboxFilterMenuContent(workspace: workspace)
        } label: {
            Label("Filter", systemImage: isNarrowed
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Filter")
        .accessibilityValue(value)
        .accessibilityIdentifier("inbox.filter")
    }
}

/// A filter with nothing in it (`caughtUp`), centred in the free space: Only with no chat in that
/// state, or Show holding no chat (`caughtUpThisApp`, `caughtUpOtherPlatforms`,
/// `caughtUpScheduled`, `docs/inbox.md` §5).
struct CaughtUpState: View {
    private let symbol: String
    private let title: String
    private let message: String

    init(filter: InboxFilter) {
        symbol = "checkmark.circle.fill"
        switch filter {
        case .unread, .all:
            title = String(localized: "You’re all caught up")
            message = String(localized: "Nothing unread in your chats.")
        case .needsYou:
            title = String(localized: "Nothing needs you")
            message = String(localized: "Hermes isn’t waiting on you in any chat.")
        case .running:
            title = String(localized: "Nothing running")
            message = String(localized: "No chat is running right now.")
        }
    }

    /// A list that is simply empty, so its Show glyph rather than a check.
    init(show: InboxShow) {
        symbol = show.symbol
        switch show {
        case .thisApp, .all:
            title = String(localized: "No chats from this app")
            message = String(localized: "Chats you start in this app show up here.")
        case .otherPlatforms:
            title = String(localized: "No chats from other platforms")
            message = String(localized: "Telegram, Discord and CLI chats show up here.")
        case .scheduled:
            title = String(localized: "No scheduled runs")
            message = String(localized: "Runs from your scheduled tasks show up here.")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(Theme.tertiaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

extension InboxShow {
    /// The choice's glyph, in the menu and on its empty state. This App is the device it runs on.
    var symbol: String {
        switch self {
        case .thisApp:
            #if os(macOS)
            "macbook"
            #else
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        case .all: "tray"
        case .otherPlatforms: "bubble.left.and.bubble.right"
        case .scheduled: "calendar.badge.clock"
        }
    }
}

// MARK: - Menus

/// Mute ▸ For 1 Hour, For 8 Hours, For 1 Week, Until I Turn It Back On; or Unmute
/// (`docs/inbox.md` §1 Muting).
struct MuteMenu: View {
    let unread: UnreadStore
    let key: String

    var body: some View {
        if let end = unread.mutes.end(of: key) {
            Button(end == .distantFuture ? String(localized: "Unmute") : String(localized: "Unmute (until \(end.formatted(date: .omitted, time: .shortened)))"),
                   systemImage: "bell") {
                unread.unmute(key)
            }
        } else {
            Menu("Mute", systemImage: "bell.slash") {
                Button("For 1 Hour") { unread.mute(key, for: .hour) }
                Button("For 8 Hours") { unread.mute(key, for: .eightHours) }
                Button("For 1 Week") { unread.mute(key, for: .week) }
                Button("Until I Turn It Back On") { unread.mute(key, for: .untilTurnedOff) }
            }
        }
    }
}

/// "Archived “Release notes”  Undo" at the foot of the list, for a few seconds. It shows only in
/// the place the chat was archived from (the chat list or a project home), so a window never
/// shows two.
struct ArchivedToast: ViewModifier {
    @Bindable var workspace: BotWorkspace
    var place = BotWorkspace.ArchivePlace.chatList
    /// Room left below it: the chat list's bottom bar, or a project home's composer.
    var bottomPadding: CGFloat = 64
    let onError: (HermesError) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let session = workspace.recentlyArchived, workspace.recentlyArchivedPlace == place {
                HStack(spacing: 12) {
                    Text("Archived “\(session.displayTitle)”")
                        .font(.subheadline)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Button("Undo") {
                        Task {
                            do {
                                try await workspace.unarchive(session)
                            } catch {
                                onError(error as? HermesError ?? .invalidResponse(error.localizedDescription))
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Theme.sheetCell, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: Theme.shadow, radius: 12, y: 4)
                .padding(.horizontal, 16)
                .padding(.bottom, bottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: session.stableID) {
                    AccessibilityNotification.Announcement(String(localized: "Archived \(session.displayTitle)")).post()
                    try? await Task.sleep(for: .seconds(5))
                    if workspace.recentlyArchived?.stableID == session.stableID {
                        withAnimation(Theme.snappy) { workspace.recentlyArchived = nil }
                    }
                }
                // Leaving a project home ends its Undo; it would otherwise wait there with no timer.
                // The chat list keeps its own, which shows again on return (`docs/inbox.md` §5).
                .onDisappear {
                    if place == .project, workspace.recentlyArchived?.stableID == session.stableID, workspace.recentlyArchivedPlace == place {
                        workspace.recentlyArchived = nil
                    }
                }
            }
        }
        .animation(Theme.snappy, value: workspace.recentlyArchived?.stableID)
    }
}

#if os(iOS)
/// One of a row's swipe actions, as a `List` row's `swipeActions` would hold it.
struct RowSwipeAction: Identifiable {
    let title: String
    let symbol: String
    let tint: Color
    let perform: () -> Void

    var id: String { title }
}

/// The chat list's trailing swipe on a row outside a `List` (a project's lanes, `docs/projects.md`
/// §2), where `swipeActions` does nothing. The actions are in `swipeActions`' order: the first sits
/// at the edge and is what a full swipe does. It looks and moves as the system's does: round
/// buttons with their names under them, in places and at marks `RowSwipe` holds. The pan begins
/// only on a drag to the left (`SidewaysSwipePan`), so the lanes still scroll and the edge's back
/// swipe stays the system's. VoiceOver gets the actions from the row's own `accessibilityAction`s.
struct TrailingSwipeActions: ViewModifier {
    let id: String
    let actions: [RowSwipeAction]
    /// The row that's open, so opening one shuts the others and a scroll shuts it.
    @Binding var openRow: String?

    @State private var offset: CGFloat = 0
    /// Where the drag began: shut or open.
    @State private var start: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    @State private var isFull = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The round button's height, as the system draws the chat list's.
    static let buttonHeight: CGFloat = 34

    private var swipe: RowSwipe {
        RowSwipe(count: actions.count, rowWidth: rowWidth)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .background(alignment: .trailing) { buttons }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .gesture(SidewaysSwipePan(direction: openRow == id ? .either : .left, countsFromTouchDown: true, began: { start = offset }, changed: follow, ended: release, cancelled: { settle(.close) }))
            .sensoryFeedback(.impact(weight: .medium), trigger: isFull) { _, full in full }
            .onChange(of: openRow) { _, row in
                if row != id, offset != 0 { settle(.close) }
            }
    }

    /// Behind the row, in the space it has uncovered. They stay in the tree while the row slides
    /// back, so they shrink and fade with it instead of vanishing.
    private var buttons: some View {
        ZStack(alignment: .trailing) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let slot = swipe.slot(index, at: offset)
                let shows = swipe.shows(index, at: offset)
                button(action, width: slot.width)
                    .animation(.easeOut(duration: 0.1), value: isFull)
                    .opacity(shows ? swipe.opacity(index, at: offset) : 0)
                    .scaleEffect(shows || reduceMotion ? 1 : 0.5)
                    .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.72), value: shows)
                    .padding(.trailing, slot.inset)
            }
        }
        .frame(width: max(0, -offset), alignment: .trailing)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private func button(_ action: RowSwipeAction, width: CGFloat) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: width, height: Self.buttonHeight)
                    .background(action.tint, in: Capsule())
                Text(action.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private func follow(_ translation: CGFloat) {
        if openRow != id, openRow != nil { openRow = nil }
        offset = swipe.offset(translation: translation, from: start)
        isFull = swipe.isFull(offset)
    }

    /// Where the row is decides, not how fast it moved, as in the chat list.
    private func release(_ translation: CGFloat, velocity _: CGFloat) {
        offset = swipe.offset(translation: translation, from: start)
        settle(swipe.release(offset: offset))
    }

    private func perform(_ action: RowSwipeAction) {
        action.perform()
        settle(.close)
    }

    private func settle(_ release: RowSwipe.Release) {
        if release == .full, let first = actions.first { first.perform() }
        let target: CGFloat = release == .open ? -swipe.openWidth : 0
        let animation: Animation = if reduceMotion {
            .easeOut(duration: 0.15)
        } else if release == .full {
            .smooth(duration: 0.6)
        } else {
            .spring(response: 0.35, dampingFraction: 0.86)
        }
        // `isFull` stays as it was until the next drag: dropping it here would snap the first
        // button back to its own width instead of letting it shrink with the row.
        withAnimation(animation) { offset = target }
        if release == .open {
            openRow = id
        } else if openRow == id {
            openRow = nil
        }
    }
}

/// A pan that begins only when the finger moves more sideways than up or down (`SidewaysSwipe`),
/// so vertical drags stay the list's or the chat's. A SwiftUI drag on rows in a scroll view took
/// those too, and the list and the chat stopped scrolling.
struct SidewaysSwipePan: UIGestureRecognizerRepresentable {
    var direction = SidewaysSwipe.Direction.either
    /// Reports where the finger is across the view (a scrubber's) instead of how far it moved.
    var tracksLocation = false
    /// Reports how far the finger has moved since it touched down, the move that began the pan
    /// included, as a row's swipe actions must to keep up with it (`SidewaysSwipe.travel`).
    var countsFromTouchDown = false
    var isEnabled = true
    var began: () -> Void = {}
    /// How far the finger has moved across (or where it is, `tracksLocation`).
    let changed: (CGFloat) -> Void
    let ended: (_ x: CGFloat, _ velocity: CGFloat) -> Void
    /// The system took the touch, or the row went. Without it, the swipe ends where it is.
    var cancelled: (() -> Void)?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        if pan.isEnabled != isEnabled { pan.isEnabled = isEnabled }
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let x = if tracksLocation {
            context.converter.localLocation.x
        } else if countsFromTouchDown, let touchDown = context.coordinator.touchDown {
            SidewaysSwipe.travel(from: touchDown, to: pan.location(in: nil))
        } else {
            pan.translation(in: pan.view).x
        }
        switch pan.state {
        case .began:
            began()
            changed(x)
        case .changed:
            changed(x)
        case .ended:
            ended(x, pan.velocity(in: pan.view).x)
        case .cancelled, .failed:
            if let cancelled { cancelled() } else { ended(x, 0) }
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// An open row's swipe goes either way: back to the right shuts it.
        var direction: SidewaysSwipe.Direction
        /// Where the finger touched down, in the window: the row may move under it.
        var touchDown: CGPoint?

        init(direction: SidewaysSwipe.Direction) {
            self.direction = direction
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDown = touch.location(in: nil)
            return true
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return SidewaysSwipe.begins(velocity: pan.velocity(in: pan.view), translation: pan.translation(in: pan.view), direction: direction)
        }
    }
}
#endif
