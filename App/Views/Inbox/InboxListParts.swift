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

#if os(iOS)
/// A pan that begins only when the finger moves more sideways than up or down (`SidewaysSwipe`),
/// so vertical drags stay the list's or the chat's. A SwiftUI drag on rows in a scroll view took
/// those too, and the list and the chat stopped scrolling.
struct SidewaysSwipePan: UIGestureRecognizerRepresentable {
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
        let direction: SidewaysSwipe.Direction

        init(direction: SidewaysSwipe.Direction) {
            self.direction = direction
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return SidewaysSwipe.begins(velocity: pan.velocity(in: pan.view), translation: pan.translation(in: pan.view), direction: direction)
        }
    }
}
#endif
