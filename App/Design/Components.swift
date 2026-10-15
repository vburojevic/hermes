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

/// Two offset bars, the drawer/sidebar affordance used by Grok-style apps.
struct SidebarGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().frame(width: 18, height: 2.2)
            Capsule().frame(width: 11, height: 2.2)
        }
        .frame(width: 22, height: 22, alignment: .leading)
        // A custom shape in a toolbar is drawn dimmed unless it has its own colour.
        .foregroundStyle(Theme.primaryText)
        .accessibilityHidden(true)
    }
}

/// A status dot with a soft halo.
struct StatusDot: View {
    let color: Color
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background {
                Circle()
                    .fill(color.opacity(0.35))
                    .scaleEffect(animate ? 2.2 : 1)
                    .opacity(animate ? 0 : 1)
            }
            .onAppear(perform: updatePulse)
            .onChange(of: motionPaused) { updatePulse() }
            .onChange(of: pulsing) { updatePulse() }
            .onDisappear { animate = false }
            .accessibilityHidden(true)
    }

    /// Pulses only while it means something and the window is in front.
    private func updatePulse() {
        if pulsing, !reduceMotion, !motionPaused {
            guard !animate else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
        } else if animate {
            withAnimation(nil) { animate = false }
        }
    }
}

/// Text with a moving highlight, for "Thinking…" style labels.
struct ShimmerText: View {
    let text: String
    var font: Font = .subheadline.weight(.medium)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pausesDecorativeMotion) private var motionPaused
    @State private var sweeping = false

    var body: some View {
        // One line, always: a long status is a headline here, not a paragraph.
        let label = Text(text).font(font).lineLimit(1).truncationMode(.tail)
        if reduceMotion {
            label.foregroundStyle(Theme.secondaryText)
        } else {
            label
                .foregroundStyle(Theme.tertiaryText)
                .overlay {
                    // The text is drawn once and masks a highlight that only moves: no text is laid
                    // out or drawn again per frame (that redrew it 30 times a second).
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: Theme.primaryText, location: 0.5), .init(color: .clear, location: 1)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.5)
                        .offset(x: sweeping ? width : -width * 0.5)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
                .onAppear { sweep() }
                .onChange(of: motionPaused) { sweep() }
        }
    }

    private func sweep() {
        if motionPaused {
            withAnimation(nil) { sweeping = false }
        } else if !sweeping {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { sweeping = true }
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
    func prominentGlassButton() -> some View {
        buttonStyle(.glassProminent)
            .tint(Theme.ink)
            .foregroundStyle(Theme.inkForeground)
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
