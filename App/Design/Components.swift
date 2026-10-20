import HermesKit
import SwiftUI

/// A bot's avatar: its accent colour with the Hermes wing.
struct BotAvatar: View {
    let bot: BotConfiguration
    var size: CGFloat = 28

    private var accent: BotAccent { BotAccent(rawValue: bot.accent) ?? .graphite }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [accent.color, accent.deep], startPoint: .top, endPoint: .bottom))
            HermesMark()
                .fill(Palette.Accents.wing)
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The drawer/sidebar button: two offset bars, the affordance used by Grok-style apps, with the
/// count of unread chats elsewhere.
struct SidebarButton: View {
    let action: () -> Void
    @Environment(\.unreadStore) private var unread

    var body: some View {
        #if os(iOS)
        // Its own glass, the toolbar's hidden (`sidebarButtonGlass`): pressed, the toolbar's glass
        // grows and clips its label to the circle, which cut the badge in half. The badge sits
        // outside the label, on top of the glass, and stays whole and solid while pressed.
        Button(action: action) {
            bars
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) { badge.offset(x: 1, y: 2).allowsHitTesting(false) }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: unread?.unreadElsewhere ?? 0)
        .accessibilityLabel("Show sidebar")
        .modifier(UnreadElsewhereValue())
        #else
        Button(action: action) {
            bars
                .overlay(alignment: .topTrailing) { badge.offset(x: 12, y: -9) }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: unread?.unreadElsewhere ?? 0)
        }
        .accessibilityLabel("Show sidebar")
        .modifier(UnreadElsewhereValue())
        #endif
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().frame(width: 18, height: 2.2)
            Capsule().frame(width: 11, height: 2.2)
        }
        .frame(width: 22, height: 22, alignment: .leading)
        // A custom shape in a toolbar is drawn dimmed unless it has its own colour.
        .foregroundStyle(Theme.primaryText)
        .accessibilityHidden(true)
    }

    /// Unread chats elsewhere, muted ones and the open one left out (`unreadBadgeCutout`,
    /// `docs/inbox.md` §5).
    @ViewBuilder private var badge: some View {
        let count = unread?.unreadElsewhere ?? 0
        if count > 0 {
            UnreadCountBadge(count: count, cutout: true)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

extension ToolbarContent {
    /// The drawer button's toolbar item: on iPhone and iPad its glass is `SidebarButton`'s own.
    func sidebarButtonGlass() -> some ToolbarContent {
        #if os(iOS)
        sharedBackgroundVisibility(.hidden)
        #else
        self
        #endif
    }
}

/// "4 unread chats" on the drawer and sidebar buttons.
struct UnreadElsewhereValue: ViewModifier {
    @Environment(\.unreadStore) private var unread

    func body(content: Content) -> some View {
        let count = unread?.unreadElsewhere ?? 0
        content.accessibilityValue(count == 0 ? Text("") : count == 1 ? Text("1 unread chat") : Text("\(count) unread chats"))
    }
}

extension EnvironmentValues {
    /// The gateway's unread store, for counts drawn outside the list.
    @Entry var unreadStore: UnreadStore?
}

/// A status dot with a soft halo. It pulses only while it means something and can be seen.
struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        DecorativeLoop { runs in
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .background {
                    if pulsing, runs {
                        PulseHalo(color: color.opacity(0.35), scale: 2.2, period: 1.4)
                    }
                }
        }
        .accessibilityHidden(true)
    }
}

/// A dot's halo while it pulses: it grows and fades from the moment it appears, and stops by
/// going away (`DecorativeLoop`). At rest it would sit behind the dot, so none is drawn. Core
/// Animation plays it (`HaloLayer`): the app does nothing per frame.
struct PulseHalo: View {
    let color: Color
    let scale: CGFloat
    let period: Double

    var body: some View {
        HaloLayer(color: color, scale: scale, period: period)
    }
}

/// What Hermes or a Bot is doing, in words that shimmer (`Chips.shimmerText`, `docs/chat.md` §4a):
/// the one moving thing in its place. A `thinking-shimmer` band sweeps across the words every
/// 1.6 s while they can be seen; Reduce Motion, Low Power Mode and a window behind hold them still.
/// Its accessibility label is its words.
struct ShimmerText: View {
    /// The colour under the band: tertiary in a chat, secondary in rows, ink in the jump pill.
    enum Tone {
        case chat, row, ink

        var color: Color {
            switch self {
            case .chat: Theme.tertiaryText
            case .row: Theme.secondaryText
            case .ink: Theme.primaryText
            }
        }

        /// Still, with Reduce Motion: easier to read than tertiary.
        var stillColor: Color {
            self == .ink ? Theme.primaryText : Theme.secondaryText
        }
    }

    let text: String
    var font: Font = .subheadline.weight(.medium)
    var tone = Tone.chat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // One line, always: a long status is a headline here, not a paragraph.
        let label = Text(text).font(font).lineLimit(1).truncationMode(.tail)
        if reduceMotion {
            label.foregroundStyle(tone.stillColor)
        } else {
            DecorativeLoop { runs in
                label
                    .foregroundStyle(tone.color)
                    .overlay {
                        if runs {
                            ShimmerSweep(label: label)
                        }
                    }
            }
        }
    }
}

/// The band moving across a `ShimmerText` while it's seen. The text is drawn once and masks a
/// band that only moves, and Core Animation moves it (`ShimmerLayer`) at 30 frames a second:
/// neither the text nor the app does anything per frame.
private struct ShimmerSweep<Label: View>: View {
    let label: Label

    var body: some View {
        sweep
            .mask(label)
            .allowsHitTesting(false)
            #if DEBUG
            .onAppear { MotionProbe.shared.sweeps += 1 }
            .onDisappear { MotionProbe.shared.sweeps -= 1 }
            #endif
    }

    @ViewBuilder
    private var sweep: some View {
        #if DEBUG
        if Self.drawsEachFrame {
            TimelineSweep()
        } else {
            ShimmerLayer(color: Theme.thinkingShimmer)
        }
        #else
        ShimmerLayer(color: Theme.thinkingShimmer)
        #endif
    }

    #if DEBUG
    /// `-HERMES_SHIMMER_TIMELINE YES`: the band drawn by SwiftUI each frame, to measure against the
    /// layer (`docs/design-to-swiftui.md` §8, Loading).
    static var drawsEachFrame: Bool { UserDefaults.standard.bool(forKey: "HERMES_SHIMMER_TIMELINE") }
    #endif
}

#if DEBUG
/// The same band from a `TimelineView` at most 30 times a second, for the measurement only.
private struct TimelineSweep: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let into = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: ShimmerLayer.period) / ShimmerLayer.period
            // Ease in and out, as the layer's timing function.
            let eased = into < 0.5 ? 2 * into * into : 1 - pow(-2 * into + 2, 2) / 2
            let centre = -0.15 + eased * 1.3
            LinearGradient(
                stops: [
                    .init(color: Theme.thinkingShimmer.opacity(0), location: centre - 0.15),
                    .init(color: Theme.thinkingShimmer, location: centre),
                    .init(color: Theme.thinkingShimmer.opacity(0), location: centre + 0.15),
                ],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }
}
#endif

/// The app's own waiting that the person started (`Chips.spinner`, `docs/chat.md` §4a):
/// connecting, pairing, signing in, installing, restarting, saving. It shows after half a second,
/// so a quick answer never flashes it, inside the control that started it or centred on an empty
/// page. Never for what Hermes or a Bot is doing: that's `ShimmerText`.
struct Spinner: View {
    var size: ControlSize = .small

    @State private var shows = false

    var body: some View {
        ProgressView()
            .controlSize(size)
            .opacity(shows ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeOut(duration: 0.15)) { shows = true }
            }
    }
}

/// A list or card that's loading (`docs/chat.md` §4a): grey lines in the shape of what's coming,
/// still, so an idle placeholder doesn't wake the CPU. It waits a beat before showing, so a fast
/// load doesn't flash it.
struct SkeletonRows: View {
    var count = 3
    /// One line per row, or a title and a shorter second line.
    var twoLines = true

    @State private var shows = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// Ink, faint: it reads on the canvas, a grouped cell and a sheet alike, light or dark.
    private var fill: Color { Theme.primaryText.opacity(contrast == .increased ? 0.16 : 0.08) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 7) {
                    Capsule()
                        .fill(fill)
                        .frame(height: 11)
                        .frame(maxWidth: [0.62, 0.48, 0.56][index % 3] * 360)
                    if twoLines {
                        Capsule()
                            .fill(fill)
                            .frame(height: 9)
                            .frame(maxWidth: [0.86, 0.7, 0.78][index % 3] * 360)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .opacity(shows ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Loading"))
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            withAnimation(.easeOut(duration: 0.25)) { shows = true }
        }
    }
}

/// A capsule chip (`controls/chips.elyx` `chip` / `chipActive`): the composer's Think control
/// and filters. Inactive is outlined; active fills with the raised surface.
struct ChipLabel: View {
    let title: String
    var symbol: String?
    var isActive = false
    var showsChevron = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? Theme.primaryText : Theme.secondaryText)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        .background(Capsule().fill(isActive ? Theme.surfaceRaised : .clear))
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .contentShape(Capsule())
    }
}

/// A small tag (`controls/chips.elyx` `tag`…`tagInk`): "Default", "Free", "Paused", "Aside".
struct TagLabel: View {
    enum Style { case neutral, success, warning, danger, ink }

    let title: String
    var symbol: String?
    var style: Style = .neutral

    private var foreground: Color {
        switch style {
        case .neutral: Theme.secondaryText
        case .success: Theme.success
        case .warning: Theme.warning
        case .danger: Theme.danger
        case .ink: Theme.inkForeground
        }
    }

    private var fill: Color {
        switch style {
        case .neutral: Theme.surface
        case .success: Theme.successTint
        case .warning: Theme.warningTint
        case .danger: Theme.dangerTint
        case .ink: Theme.ink
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(minHeight: 20)
        .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Icon-only toolbar-style button with a generous hit area.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .background {
                Circle()
                    .fill(Theme.surfaceRaised)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// Subtle press feedback for rows and cards.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.snappy, value: configuration.isPressed)
    }
}

/// A rounded, filled container for secondary content (code, tool output).
struct SurfaceBackground: ViewModifier {
    var radius: CGFloat = Theme.Radius.code

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
    }
}

extension View {
    func surface(radius: CGFloat = Theme.Radius.code) -> some View {
        modifier(SurfaceBackground(radius: radius))
    }
}

/// A full-area message for empty or failed states.
struct StateMessage: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.bottom, 4)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .glassButton()
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 420)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InkDefaultButton: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(Theme.ink)
            .foregroundStyle(appearsActive && isEnabled ? Theme.inkForeground : Theme.primaryText)
    }
}

private struct ProminentGlassButton: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .buttonStyle(.glassProminent)
            .tint(Theme.ink)
            #if os(macOS)
            .foregroundStyle(appearsActive ? Theme.inkForeground : Theme.primaryText)
            #else
            .foregroundStyle(Theme.inkForeground)
            #endif
    }
}

extension View {
    /// A quiet Liquid Glass button, only for controls that float over content or media.
    /// `.glass` fills itself with any tint around it while a Mac window is active, so the tint
    /// is cleared to keep it plain glass.
    func glassButton() -> some View {
        buttonStyle(.glass)
            .tint(nil)
    }

    /// The one prominent action in a group: Liquid Glass filled with ink, labelled in the
    /// contrasting colour (a white tint in dark mode would otherwise swallow a white label).
    /// An inactive Mac window drops the ink, so the label goes back to the text colour there.
    func prominentGlassButton() -> some View {
        modifier(ProminentGlassButton())
    }

    /// A Mac window's default action (Run Now, Create Project, Restore All…): filled with ink
    /// while the window is active. An inactive window drops the fill, so the label goes back to
    /// the text colour rather than ink-on-nothing.
    func inkDefaultButton() -> some View {
        modifier(InkDefaultButton())
    }

    /// The prominent action inside a glass card: a solid ink capsule (glass on glass would haze).
    func inkFilledButton() -> some View {
        buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.ink)
            .foregroundStyle(Theme.inkForeground)
    }

    /// The secondary button (Elyx `borderedButton`): a grey capsule with a primary-text label,
    /// for cards, sheets, alerts and empty states. Destructive ones (`role: .destructive`) get a
    /// red label.
    func cardButton() -> some View {
        buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(Theme.primaryText)
    }
}
