import HermesKit
import SwiftUI

// MARK: - Filters

/// All · Unread · Needs You · Running over the chat list (`filterChip`, `docs/inbox.md` §5). The
/// Mac has no All: clicking the selected filter clears it. A long press (a right-click on the
/// Mac) on Unread offers Mark All as Read.
struct InboxFilterChips: View {
    @Bindable var workspace: BotWorkspace

    @Environment(\.sidebarRowsInStack) private var inStack

    /// The row's height with its padding, for centring states below it.
    static let height: CGFloat = 46

    private var filters: [InboxFilter] {
        #if os(macOS)
        [.unread, .needsYou, .running]
        #else
        InboxFilter.allCases
        #endif
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(filters, id: \.self) { filter in
                    chip(filter)
                }
            }
            .padding(.horizontal, SidebarMetrics.listInset + SidebarMetrics.rowPadding)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .padding(.vertical, 8)
        .modifier(EdgeToEdgeRow(inStack: inStack))
        .animation(.smooth(duration: 0.2), value: workspace.inboxFilter)
    }

    @ViewBuilder
    private func chip(_ filter: InboxFilter) -> some View {
        let selected = workspace.inboxFilter == filter
        let count = filter == .all ? 0 : workspace.count(for: filter)
        Button {
            #if os(macOS)
            workspace.inboxFilter = selected ? .all : filter
            #else
            workspace.inboxFilter = filter
            #endif
        } label: {
            HStack(spacing: 5) {
                Text(filter.title)
                    .foregroundStyle(Theme.primaryText)
                if count > 0 {
                    Text("\(count)")
                        .foregroundStyle(Theme.tertiaryText)
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .font(InboxChipMetrics.font)
            .padding(.horizontal, 10)
            .frame(height: InboxChipMetrics.height)
            .background {
                if selected {
                    Capsule().fill(Theme.surfaceRaised)
                } else {
                    Capsule().strokeBorder(Theme.hairline)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? Text("\(filter.title), \(count)") : Text(filter.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if filter == .unread, count > 0 {
                Button("Mark All as Read", systemImage: "envelope.open") {
                    Task { await workspace.unread.markAllRead(workspace.unreadChatKeys) }
                }
            }
        }
    }
}

private enum InboxChipMetrics {
    #if os(macOS)
    static let height: CGFloat = 24
    static let font = Font.system(size: 11.5, weight: .semibold)
    #else
    static let height: CGFloat = 30
    static let font = Font.footnote.weight(.semibold)
    #endif
}

/// A row that runs to the list's edges (a horizontal scroller): no insets of its own.
private struct EdgeToEdgeRow: ViewModifier {
    let inStack: Bool

    func body(content: Content) -> some View {
        if inStack {
            content
        } else {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}

/// A filter with nothing in it (`caughtUp`), centred in the free space.
struct CaughtUpState: View {
    let filter: InboxFilter

    private var title: String {
        switch filter {
        case .unread, .all: String(localized: "You’re all caught up")
        case .needsYou: String(localized: "Nothing needs you")
        case .running: String(localized: "Nothing running")
        }
    }

    private var message: String {
        switch filter {
        case .unread, .all: String(localized: "Nothing unread in your chats.")
        case .needsYou: String(localized: "Hermes isn’t waiting on you in any chat.")
        case .running: String(localized: "No chat is running right now.")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
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

/// "Archived “Release notes”  Undo" at the foot of the list, for a few seconds.
struct ArchivedToast: ViewModifier {
    @Bindable var workspace: BotWorkspace
    let onError: (HermesError) -> Void

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let session = workspace.recentlyArchived {
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
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: session.stableID) {
                    AccessibilityNotification.Announcement(String(localized: "Archived \(session.displayTitle)")).post()
                    try? await Task.sleep(for: .seconds(5))
                    if workspace.recentlyArchived?.stableID == session.stableID {
                        withAnimation(Theme.snappy) { workspace.recentlyArchived = nil }
                    }
                }
            }
        }
        .animation(Theme.snappy, value: workspace.recentlyArchived?.stableID)
    }
}

// MARK: - Swipes in the drawer

/// One action behind a row: glyph over label (`swipeLeading` in ink, `swipeAction` in grey).
struct SwipeTile {
    let title: String
    let symbol: String
    var isInk = false
    let action: () -> Void
}

/// A row swiped in the drawer claims the drag, so the drawer doesn't close under it.
@MainActor
enum RowSwipe {
    static var claimedAt = Date.distantPast

    static var isClaimed: Bool { Date.now.timeIntervalSince(claimedAt) < 0.6 }

    /// The drawer itself is being swiped (open or closed): a row the finger started on slides
    /// along under it, and letting go mustn't open that row.
    static var drawerDraggedAt = Date.distantPast

    static var drawerJustDragged: Bool { Date.now.timeIntervalSince(drawerDraggedAt) < 0.35 }
}

/// Swipe actions for the drawer's rows, which sit in a lazy stack rather than a `List`: from the
/// leading edge Read / Unread and Pin, from the trailing edge Mute and Archive (`docs/inbox.md`
/// §5). The row slides over its actions, which share the room it uncovers as the system's do and
/// grow in as they appear; pulled past them, the first one takes the whole width (a tap of
/// haptics) and runs when let go. One row is open at a time; scrolling or a tap on the row
/// closes it.
///
/// The drag is UIKit's, and only a sideways one: a SwiftUI drag on every row took the vertical
/// drags too, and the drawer's list stopped scrolling.
struct DrawerSwipeActions: ViewModifier {
    /// The row is in the drawer's stack (not a `List`).
    let isInDrawer: Bool
    let leading: [SwipeTile]
    let trailing: [SwipeTile]

    /// Before iOS 27 the drawer draws its own; from it the system's swipe the row, and this only
    /// keeps the drawer from closing under a row swiped toward it (`RowSwipe`).
    private var isEnabled: Bool { isInDrawer && !DrawerSwipe.isSystems }

    @State private var offset: CGFloat = 0
    @State private var resting: CGFloat = 0
    /// Pulled past the actions: the first one fills the room and runs when let go.
    @State private var isFull = false
    @State private var width: CGFloat = 0
    @State private var id = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tileWidth: CGFloat = 74
    private static let gap: CGFloat = 6
    private var leadingRest: CGFloat { Self.rest(leading.count) }
    private var trailingRest: CGFloat { Self.rest(trailing.count) }

    /// Open: the tiles and the gaps around them (the row's own inset is the outer one).
    private static func rest(_ count: Int) -> CGFloat {
        CGFloat(count) * (tileWidth + gap)
    }

    /// How far past the actions a pull runs the first one.
    private var fullPull: CGFloat { max(96, width * 0.22) }

    func body(content: Content) -> some View {
        #if os(iOS)
        if isEnabled {
            content
                // Opaque, so the actions stay under the row until it uncovers them.
                .background(Theme.sidebar)
                // A tap on the open row closes it. Laid on the row before it slides, so it moves
                // with the row: after the offset it stayed where the row had been, over the
                // actions, and a tap on Mute or Archive only closed the row.
                .overlay {
                    if resting != 0 {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offset)
                .background { if offset != 0 { actions } }
                .gesture(SidewaysSwipePan(began: began, changed: changed, ended: ended))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .onChange(of: DrawerSwipe.shared.openRow) { _, open in
                    if open != id, offset != 0 { close() }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: isFull) { _, full in full }
                .onDisappear {
                    offset = 0
                    resting = 0
                    isFull = false
                }
        } else if isInDrawer {
            content.gesture(SidewaysSwipePan(passive: true, began: { RowSwipe.claimedAt = .now }, changed: { _ in RowSwipe.claimedAt = .now }, ended: { _, _ in }))
        } else {
            content
        }
        #else
        content
        #endif
    }

    // MARK: The actions

    private var actions: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                tiles(leading, room: offset, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                tiles(trailing, room: -offset, alignment: .trailing)
            }
        }
        .padding(.horizontal, SidebarMetrics.listInset)
        .padding(.vertical, 2)
    }

    /// The tiles in the room the row has uncovered (less the gap before the row), side by side,
    /// or the first alone once the pull would run it.
    private func tiles(_ tiles: [SwipeTile], room: CGFloat, alignment: Alignment) -> some View {
        let available = max(0, room - Self.gap)
        let count = CGFloat(max(1, tiles.count))
        let shared = max(0, (available - Self.gap * (count - 1)) / count)
        return HStack(spacing: isFull ? 0 : Self.gap) {
            ForEach(tiles.indices, id: \.self) { index in
                let tileWidth = isFull ? (index == 0 ? available : 0) : shared
                tileView(tiles[index], width: tileWidth)
            }
        }
        .frame(width: available, alignment: alignment)
    }

    private func tileView(_ tile: SwipeTile, width: CGFloat) -> some View {
        // How much of the tile is out: its glyph and label grow in with it.
        let shown = min(1, width / Self.tileWidth)
        return Button {
            run(tile)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(tile.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(tile.isInk ? Theme.inkForeground : Theme.primaryText)
            .opacity(shown < 0.35 ? 0 : (shown - 0.35) / 0.65)
            .scaleEffect(reduceMotion ? 1 : 0.75 + 0.25 * shown)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(tile.isInk ? Theme.ink : Theme.controlFill, in: RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: SidebarMetrics.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(width < 1 ? 0 : 1)
        .accessibilityLabel(tile.title)
    }

    // MARK: The drag

    private func began() {
        RowSwipe.claimedAt = .now
        DrawerSwipe.shared.openRow = id
    }

    private func changed(_ translation: CGFloat) {
        RowSwipe.claimedAt = .now
        let raw = resting + translation
        let limit = raw > 0 ? leadingRest : trailingRest
        let tiles = raw > 0 ? leading : trailing
        guard !tiles.isEmpty else {
            offset = raw * 0.15 // nothing on this side: it barely gives
            return
        }
        // Past the actions it follows the finger more slowly, as the system's does.
        let magnitude = abs(raw) <= limit ? abs(raw) : limit + (abs(raw) - limit) * 0.55
        offset = raw > 0 ? magnitude : -magnitude
        let full = abs(raw) > limit + fullPull
        if full != isFull {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { isFull = full }
        }
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        RowSwipe.claimedAt = .now
        let pulled = resting + translation
        if isFull {
            let tile = pulled > 0 ? leading.first : trailing.first
            if let tile { run(tile) } else { close() }
            return
        }
        // Where a flick would carry it.
        let landing = pulled + velocity * 0.18
        if landing > leadingRest * 0.5, !leading.isEmpty {
            settle(leadingRest)
        } else if landing < -trailingRest * 0.5, !trailing.isEmpty {
            settle(-trailingRest)
        } else {
            close()
        }
    }

    private func run(_ tile: SwipeTile) {
        tile.action()
        close()
    }

    private func settle(_ position: CGFloat) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.86)) {
            offset = position
            resting = position
            isFull = false
        }
        if position != 0 { DrawerSwipe.shared.openRow = id }
    }

    private func close() {
        settle(0)
        if DrawerSwipe.shared.openRow == id { DrawerSwipe.shared.openRow = nil }
    }
}

/// The drawer row whose actions are open: opening another closes it, and so does scrolling.
@MainActor
@Observable
final class DrawerSwipe {
    static let shared = DrawerSwipe()
    var openRow: UUID?

    /// iOS 27 swipes rows in any container (`swipeActions` plus `swipeActionsContainer()`), so the
    /// drawer uses the system's, as `List` does. Before it, only `List` rows swiped and the drawer
    /// draws its own (`DrawerSwipeActions`); both on one row fought over the drag.
    static var isSystems: Bool {
        if #available(iOS 27.0, macOS 27.0, *) { true } else { false }
    }
}

/// The drawer's list coordinates its rows' system swipes (iOS 27): one row open at a time,
/// closed by scrolling or a tap elsewhere.
struct DrawerSwipeContainer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.0, macOS 27.0, *) {
            content.swipeActionsContainer()
        } else {
            content
        }
    }
}

#if os(iOS)
/// A pan that begins only when the finger moves more sideways than up or down (`SidewaysSwipe`),
/// so vertical drags stay the list's or the chat's. A SwiftUI drag on rows in a scroll view took
/// those too, and the drawer's list and the chat stopped scrolling.
struct SidewaysSwipePan: UIGestureRecognizerRepresentable {
    /// Only watches: runs alongside the system's swipe and leaves the touches to it.
    var passive = false
    var direction = SidewaysSwipe.Direction.either
    /// Reports where the finger is across the view (a scrubber's) instead of how far it moved.
    var tracksLocation = false
    var isEnabled = true
    var began: () -> Void = {}
    /// How far the finger has moved across (or where it is, `tracksLocation`).
    let changed: (CGFloat) -> Void
    let ended: (_ x: CGFloat, _ velocity: CGFloat) -> Void
    /// The system took the touch, or the row went. Without it, the swipe ends where it is.
    var cancelled: (() -> Void)?

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(passive: passive, direction: direction)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = !passive
        pan.isEnabled = isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        if pan.isEnabled != isEnabled { pan.isEnabled = isEnabled }
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let x = tracksLocation ? context.converter.localLocation.x : pan.translation(in: pan.view).x
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
        let passive: Bool
        let direction: SidewaysSwipe.Direction

        init(passive: Bool, direction: SidewaysSwipe.Direction) {
            self.passive = passive
            self.direction = direction
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            passive
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return SidewaysSwipe.begins(velocity: pan.velocity(in: pan.view), translation: pan.translation(in: pan.view), direction: direction)
        }
    }
}
#endif
