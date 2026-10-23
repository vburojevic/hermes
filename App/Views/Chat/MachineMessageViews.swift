import HermesKit
import SwiftUI

/// `compactionDivider` (`docs/chat.md` §2a): where Hermes compacted the chat, a quiet divider in
/// place of its handoff summary, which nobody wrote. Folded by default; it opens to the summary's
/// own words, read-only, without Hermes's instructions to the model.
struct CompactionDivider: View {
    let summary: String

    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.compress.vertical")
                            .accessibilityHidden(true)
                        Text("Earlier messages were summarized")
                        Image(systemName: "chevron.right")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Earlier messages summarized")
            .accessibilityValue(isOpen ? Text("Shown") : Text("Hidden"))
            .accessibilityHint(isOpen ? "Hides the summary" : "Shows the summary")
            .accessibilityIdentifier("compactionDivider")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hermes keeps this summary in place of the earlier messages.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    MarkdownView(text: summary, tone: .secondary)
                        .environment(\.markdownBodyFont, Theme.Typography.compactMessage)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.hairline)
                )
                .transition(.opacity)
            }
        }
    }
}

/// The line over a reply to a delivery (`deliveryReplyCaption`, `docs/chat.md` §2a): the Bot
/// answered the routine or the automation, not the person.
struct DeliveryReplyCaption: View {
    let source: DeliverySource

    private var text: String {
        switch source {
        case .routine(let name): String(localized: "Replying to the routine \(name)")
        case .webhook(let name): String(localized: "Replying to the webhook \(name)")
        case .automation: String(localized: "Replying to an automated message")
        }
    }

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: "arrowshape.turn.up.left")
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityElement(children: .combine)
    }
}
