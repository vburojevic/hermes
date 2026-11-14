import HermesKit
import SwiftUI

/// Chats | Bots: the sidebar's two halves, as a full-width track with a raised pill
/// that slides to the selected side. The Bots side carries an unread count.
struct SidebarModeSwitcher: View {
    @Binding var mode: SidebarMode
    /// Read here, not by the sidebar, so unread changes only redraw the switcher.
    var unread: UnreadStore?

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(macOS)
    private let height: CGFloat = 24
    #else
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 30
    #endif

    /// Each segment shows the other mode's unread chats (`docs/inbox.md` §5).
    private func unreadCount(_ value: SidebarMode) -> Int {
        guard let unread, mode != value else { return 0 }
        return unread.unreadCount(inBots: value == .bots)
    }

    /// At the accessibility sizes "Chats" and its count no longer fit half the list, so the two
    /// sides stack and the pill slides down instead of across (`docs/inbox.md` §6).
    private var isStacked: Bool {
        #if os(macOS)
        false
        #else
        dynamicTypeSize.isAccessibilitySize
        #endif
    }

    var body: some View {
        let layout = isStacked ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        track(layout {
            tab(.chats, title: "Chats", badge: unreadCount(.chats))
            tab(.bots, title: "Bots", badge: unreadCount(.bots))
        }
        .padding(3))
        .animation(reduceMotion ? nil : Theme.snappy, value: mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: unreadCount(.chats) + unreadCount(.bots))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }

    /// Stacked, the track keeps the pill's rounding so the two stay concentric.
    @ViewBuilder
    private func track(_ content: some View) -> some View {
        if isStacked {
            let shape = RoundedRectangle(cornerRadius: height / 2 + 3, style: .continuous)
            content
                .background(Theme.surface, in: shape)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 0.5))
        } else {
            content
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
    }

    private func tab(_ value: SidebarMode, title: LocalizedStringKey, badge: Int = 0) -> some View {
        let isSelected = mode == value
        return Button {
            guard mode != value else { return }
            mode = value
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(segmentFont.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                if badge > 0 {
                    UnreadCountBadge(count: badge)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: height)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Palette.segmentSelected)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        .matchedGeometryEffect(id: "pill", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(badge > 0 ? Text("\(badge) unread") : Text(""))
        #if os(macOS)
        .help(value == .chats ? "Chats (⌘1)" : "Bots (⌘2)")
        #endif
    }

    private var segmentFont: Font {
        #if os(macOS)
        .system(size: 12)
        #else
        .subheadline
        #endif
    }
}

/// A tiny Bot face in the current foreground colour: a squircle with two eyes cut out.
struct BotGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let eye = side * 0.2
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                    .fill(.foreground)
                HStack(spacing: side * 0.2) {
                    Capsule().frame(width: eye, height: eye * 1.25)
                    Capsule().frame(width: eye, height: eye * 1.25)
                }
                .offset(y: -side * 0.04)
                .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}
