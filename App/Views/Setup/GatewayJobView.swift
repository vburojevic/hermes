import HermesKit
import SwiftUI

/// A long job on the gateway while it runs and once it's done (`docs/setup.md` §4.2a), the way
/// Telegram streams /update. The step running now is the one moving thing here: its words shimmer
/// (`docs/chat.md` §4a) and its time counts up. The newest lines follow as they arrive, then how
/// it ended. Settings → Setup shows it under the Hermes Agent and Bot-to-Bot Replies sections; a
/// chat shows it as the /update or /restart card (`GatewayJobCard`).
struct GatewayJobView: View {
    let job: GatewayJob
    /// For Run at Full Priority… when the run put Hermes at background priority.
    var setup: SetupCenter?
    /// Lines shown until Show All Lines.
    var recent = 6
    /// Where it sits: Setup's page, under a section, or a chat's card, which is itself the surface.
    var placement = Placement.page
    /// Whether the section above already shows a refusal's message and command: Hermes Agent's
    /// does, Bot-to-Bot Replies' doesn't.
    var sectionShowsRefusal = false

    enum Placement { case page, card }

    @State private var showsAll = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// More than this many lines in a Form row is a long scroll for little; Copy Lines has them all.
    private static let mostShown = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if !repeatsSection, let detail = job.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !repeatsSection, let command = job.command {
                SetupCommand(command: command)
            }
            if let reset = job.priorityReset {
                PriorityResetView(notice: reset, setup: setup)
                    .padding(.top, 2)
            } else if let restore = job.priorityRestore {
                PriorityRestoreView(restore: restore)
                    .padding(.top, 2)
            }
            if !job.log.lines.isEmpty {
                lines
            }
        }
        .environment(\.setupInsetFill, insetFill)
    }

    /// Under Hermes Agent's section a refused update's message and command are already its
    /// fallback and step, so the job keeps only its headline there (`docs/setup.md` §4.2a).
    /// Hermes's own refusal often has no separate command, so this can't hang on one.
    private var repeatsSection: Bool {
        placement == .page && sectionShowsRefusal && job.isRefusal
    }

    /// A card is the surface, so its boxes sit on the chat's background instead.
    private var insetFill: Color { placement == .card ? Theme.canvas : Theme.surface }

    @ViewBuilder
    private var headline: some View {
        if job.isRunning {
            HStack(spacing: 8) {
                Image(systemName: job.kind == .update ? "arrow.down.circle" : "arrow.clockwise.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                ShimmerText(text: job.headline)
                Spacer(minLength: 8)
                // The system counts it; the app does nothing per second.
                Text(timerInterval: job.started...Date.distantFuture, countsDown: false)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
            }
            .accessibilityElement(children: .combine)
        } else {
            // Not a Label: in a Form row its icon takes the list's icon size.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: endSymbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(endColor)
                    .accessibilityHidden(true)
                Text(job.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var endSymbol: String {
        switch job.tone {
        case .done: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .failed, .running: "xmark.circle.fill"
        }
    }

    private var endColor: Color {
        switch job.tone {
        case .done: Theme.success
        case .attention: Theme.warning
        case .failed, .running: Theme.danger
        }
    }

    private var lines: some View {
        let all = job.log.lines
        let shown = Array(all.suffix(showsAll ? Self.mostShown : recent))
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.kind == .failure ? Theme.danger : Theme.secondaryText)
                        .lineLimit(showsAll ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(10)
            .background(insetFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
            .contextMenu {
                Button("Copy Lines", systemImage: "doc.on.doc") { copyLines() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Output, \(all.count) lines"))
            .accessibilityValue(Text(shown.last?.words ?? ""))
            lineActions(count: all.count)
        }
    }

    /// Show All (only past `recent` lines) and Copy Lines, side by side; stacked at the
    /// accessibility sizes, where the two no longer fit on one line.
    private func lineActions(count: Int) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 18))
        return layout {
            if count > recent {
                Button { showsAll.toggle() } label: {
                    // A button centres a label that wraps; these lines read from the leading edge.
                    Text(showsAll ? "Show Fewer Lines" : "Show All \(count) Lines")
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: copyLines) {
                Label("Copy Lines", systemImage: "doc.on.doc")
                    .labelStyle(CopyLinesLabelStyle())
            }
            .help(job.kind == .update ? "Copy the update's output" : "Copy the restart's output")
        }
        .font(.footnote)
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .buttonStyle(.borderless)
    }

    private func copyLines() {
        Pasteboard.copy(job.log.lines.map(\.text).joined(separator: "\n"))
    }
}

/// Copy Lines' glyph and words 4 pt apart, the glyph at the words' own text style.
private struct CopyLinesLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// /update's and /restart's card in a chat (`commandResult`'s shape): the job as it runs, then
/// how it ended. It's the same run Settings → Setup shows.
struct GatewayJobCard: View {
    let job: GatewayJob
    var setup: SetupCenter?

    var body: some View {
        GatewayJobView(job: job, setup: setup, placement: .card)
            .padding(14)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
