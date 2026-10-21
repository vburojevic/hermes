import HermesKit
import SwiftUI

/// A long job on the gateway while it runs and once it's done (`docs/setup.md` §4.2a), the way
/// Telegram streams /update. The step running now is the one moving thing here: its words shimmer
/// (`docs/chat.md` §4a) and its time counts up. The newest lines follow as they arrive, then how
/// it ended. Settings → Setup shows it under the Hermes Agent section; a chat shows it as the
/// /update or /restart card (`GatewayJobCard`).
struct GatewayJobView: View {
    let job: GatewayJob
    /// For Run at Full Priority… when the run put Hermes at background priority.
    var setup: SetupCenter?
    /// Lines shown until Show All Lines.
    var recent = 6

    @State private var showsAll = false
    /// More than this many lines in a Form row is a long scroll for little; Copy Lines has them all.
    private static let mostShown = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            if let detail = job.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = job.command {
                SetupCommand(command: command)
            }
            if let reset = job.priorityReset {
                PriorityResetView(notice: reset, setup: setup)
                    .padding(.top, 2)
            }
            if !job.log.lines.isEmpty {
                lines
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        if job.isRunning {
            HStack(spacing: 8) {
                Image(systemName: job.kind == .update ? "arrow.down.circle" : "arrow.clockwise.circle")
                    .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14, weight: .semibold))
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
            .surface(radius: 10)
            .contextMenu {
                Button("Copy Lines", systemImage: "doc.on.doc") {
                    Pasteboard.copy(all.map(\.text).joined(separator: "\n"))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Output, \(all.count) lines"))
            .accessibilityValue(Text(shown.last?.words ?? ""))
            if all.count > recent {
                Button(showsAll ? "Show Fewer Lines" : "Show All \(all.count) Lines") { showsAll.toggle() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// /update's and /restart's card in a chat (`commandResult`'s shape): the job as it runs, then
/// how it ended. It's the same run Settings → Setup shows.
struct GatewayJobCard: View {
    let job: GatewayJob
    var setup: SetupCenter?

    var body: some View {
        GatewayJobView(job: job, setup: setup)
            .padding(14)
            .frame(maxWidth: 460, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
