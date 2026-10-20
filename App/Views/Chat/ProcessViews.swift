import HermesKit
import SwiftUI

/// A process's state as a glyph (`docs/background-processes.md` §4), never colour alone: a
/// still green dot while it runs (only the chat's live line moves, `docs/chat.md` §4a), a green check when it finished, a red triangle when it failed
/// (the step's red node says it there), a grey square when it was stopped.
struct ProcessStateGlyph: View {
    let state: BackgroundProcess.State
    /// The failed triangle (rows, the chip); the step shows its failure on its node.
    var showsFailure = false
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch state {
            case .running:
                StatusDot(color: Theme.success)
                    .frame(width: size, height: size)
            case .finished:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(Theme.success)
            case .failed:
                if showsFailure {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: size))
                        .foregroundStyle(Theme.danger)
                }
            case .stopped:
                Image(systemName: "stop.fill")
                    .font(.system(size: size * 0.75))
                    .foregroundStyle(Theme.tertiaryText)
            case .ended:
                EmptyView()
            }
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }
}

/// The composer's chip for the chat's background processes (`processChip`, §5): what runs, what
/// just finished (4 s), what failed (until the Terminal showed it). Part of the composer's glass,
/// after Think. Tap: the Terminal. Long-press: Stop for each running process, and Show Terminal.
struct ProcessChipView: View {
    let conversation: ConversationModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chip: ProcessChip { conversation.processChip }

    var body: some View {
        if chip != .hidden {
            Menu {
                let running = conversation.stoppableProcesses
                ForEach(running) { process in
                    Button(String(localized: "Stop \(process.name)"), systemImage: "stop.fill", role: .destructive) {
                        conversation.stopProcess(process.id)
                    }
                    .disabled(process.isStopping)
                }
                if !running.isEmpty { Divider() }
                Button("Show Terminal", systemImage: "apple.terminal") { showTerminal() }
            } label: {
                // Only "Docs site · 3 min" changes with time.
                TimelineView(.periodic(from: .now, by: isOne ? 30 : 86_400)) { context in
                    label(now: context.date)
                }
            } primaryAction: {
                showTerminal()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Background processes")
            .accessibilityLabel(Text(spoken))
            .accessibilityHint(Text("Shows the Terminal"))
            .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
        }
    }

    private func label(now: Date) -> some View {
        HStack(spacing: 6) {
            glyph
            Text(title(now: now))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isFailure ? Theme.danger : Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(reduceMotion ? .opacity : (isCount ? .numericText() : .interpolate))
        }
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .frame(minHeight: 32)
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .contentShape(Capsule())
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3), value: chip)
    }

    @ViewBuilder private var glyph: some View {
        switch chip {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.success)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.danger)
                .symbolEffect(.wiggle, options: .nonRepeating, isActive: !reduceMotion)
                .transition(.opacity)
        default:
            StatusDot(color: Theme.success)
                .frame(width: 14, height: 14)
                .transition(.opacity)
        }
    }

    private var isFailure: Bool {
        if case .failed = chip { return true }
        return false
    }

    private var isOne: Bool {
        if case .one = chip { return true }
        return false
    }

    /// "2 running" and "1 failed" roll their count.
    private var isCount: Bool {
        switch chip {
        case .several, .failed: true
        default: false
        }
    }

    /// "Docs site · 3 min", "2 running", "Release build", "1 failed".
    private func title(now: Date) -> String {
        switch chip {
        case .hidden: ""
        case .one(_, let name, let startedAt):
            startedAt.map { "\(name) · \(BackgroundProcess.durationText(now.timeIntervalSince($0)))" } ?? name
        case .several(let count): String(localized: "\(count) running")
        case .finished(_, let name): name
        case .failed(let count): String(localized: "\(count) failed")
        }
    }

    /// "2 background processes running. Show Terminal." (§9)
    private var spoken: String {
        switch chip {
        case .hidden: ""
        case .one(_, let name, _): String(localized: "\(name), running in the background")
        case .several(let count): String(localized: "\(count) background processes running")
        case .finished(_, let name): String(localized: "\(name) finished")
        case .failed(let count): count == 1 ? String(localized: "1 background process failed") : String(localized: "\(count) background processes failed")
        }
    }

    private func showTerminal() {
        conversation.inspector.openTerminal()
    }
}
