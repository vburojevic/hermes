import HermesKit
import SwiftUI

/// What a primitive's body gets from its card (`docs/widgets.md` §9): the payload, where its
/// request stands, the density, and the ways it can act. A body draws itself and calls these; the
/// card owns the round trip, confirmations, Face ID and the widget menu.
@MainActor
struct WidgetContext {
    let payload: WidgetPayload
    let interaction: WidgetInteraction
    let density: WidgetDensity
    let now: Date
    /// The host, for batches (ticks, ratings) and suggestions.
    let host: WidgetHost?
    /// Sends an answer through the card: Face ID first when it must, then Send Next.
    let answer: (WidgetAnswer) -> Void
    /// Shows where a link goes, then opens it (contract §6.1 `open`).
    let open: (String) -> Void
    /// Copies a value, with a "Copied" note.
    let copy: (String) -> Void

    /// Its buttons can be tapped.
    var canAnswer: Bool { interaction.acceptsAnswers }

    /// The action a tap of this device is waiting on: its control shows the hourglass.
    var pendingAction: String? {
        switch interaction {
        case .sending(let action, _): action
        case .waiting(let action, true, _): action
        default: nil
        }
    }

    /// The values of the answer waiting on this revision (this device's or another's): the
    /// selection shows at once, pending, until the agent's update.
    var pendingValues: JSONValue? {
        guard let answer = host?.facts.answer(to: payload.id, rev: payload.rev) else { return nil }
        switch interaction {
        case .waiting, .sending: return WidgetAnswer.parse(answer.text)?.values
        default: return nil
        }
    }

    var view: WidgetViewState {
        host?.store.view(payload.id) ?? WidgetViewState()
    }

    func updateView(_ change: (inout WidgetViewState) -> Void) {
        host?.store.updateView(payload.id, change)
    }

    /// A payload's own action: reply, open or copy.
    func perform(_ action: WidgetAction, item: (id: String, title: String)? = nil, step: String? = nil) {
        switch action.kind {
        case .open:
            if let url = action.url { open(url) }
        case .copy:
            if let value = action.value { copy(value) }
        case .reply:
            answer(.custom(payload, action, item: item, step: step))
        }
    }
}

extension EnvironmentValues {
    @Entry var widgetContext: WidgetContext?
}

/// A button for a widget's action, in the card's styles (`Parts.actionRow`): the one primary in
/// ink, the rest grey, a destructive one with a red label. The control the person tapped shows an
/// hourglass, then a spinner after 0.4 s.
struct WidgetActionButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, destructive }

    var role: Role = .secondary
    var isPending = false
    var fillsWidth = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if isPending {
                PendingGlyph(color: role == .primary ? Theme.inkForeground : Theme.secondaryText)
            }
            // A long label wraps rather than losing its end ("Clean Up Sna…").
            configuration.label
                .font(WidgetFont.body.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
        .background(background, in: Capsule())
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Capsule())
        .animation(Theme.snappy, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch role {
        case .primary: Theme.inkForeground
        case .secondary: isEnabled ? Theme.primaryText : Theme.tertiaryText
        case .destructive: isEnabled ? Theme.danger : Theme.tertiaryText
        }
    }

    private var background: Color {
        switch role {
        case .primary: isEnabled || isPending ? Theme.ink : Theme.controlFill
        case .secondary, .destructive: Theme.controlFill
        }
    }
}

/// Pending: the hourglass at once, a spinner after 400 ms (design README §5).
struct PendingGlyph: View {
    var color: Color = Theme.secondaryText

    @State private var spins = false

    var body: some View {
        Group {
            if spins {
                ProgressView()
                    .controlSize(.small)
                    .tint(color)
            } else {
                Image(systemName: "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: 16, height: 16)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            spins = true
        }
        .accessibilityLabel(String(localized: "Sending"))
    }
}
