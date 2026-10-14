import ActivityKit
import HermesPush
import SwiftUI
import WidgetKit

@main
struct HermesWidgets: WidgetBundle {
    var body: some Widget {
        TurnActivityWidget()
    }
}

/// A long turn on the Lock Screen and in the Dynamic Island (`docs/notifications.md` §4). The
/// gateway's updates arrive sealed; the device key opens them here.
struct TurnActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnActivityView(attributes: context.attributes, state: DeviceKey.state(context.state))
                .padding(16)
        } dynamicIsland: { context in
            let state = DeviceKey.state(context.state)
            let attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HermesWing()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .padding(.leading, 6)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title ?? attributes.chatTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandStatus(state: state)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandDetail(attributes: attributes, state: state)
                }
            } compactLeading: {
                HermesWing()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .accessibilityLabel("Hermes")
            } compactTrailing: {
                IslandStatus(state: state)
            } minimal: {
                HermesWing()
                    .fill(state.phase == .needsYou ? Palette.warning : .white)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel(state.phase == .needsYou ? "Hermes needs you" : "Hermes")
            }
            .keylineTint(state.phase == .needsYou ? Palette.warning : nil)
        }
    }
}

/// The device key, read once per process: the widget opens each sealed state with it.
enum DeviceKey {
    nonisolated(unsafe) private static var cached: PushDeviceKey?

    static func state(_ content: TurnActivityAttributes.ContentState) -> TurnActivityState {
        if cached == nil { cached = try? PushShared.current.deviceKey() }
        return content.state(key: cached)
    }
}

// MARK: - Lock Screen

/// `liveActivity`, `liveActivityNeedsYou`, `liveActivityDone`.
struct TurnActivityView: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                AppTile()
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title ?? attributes.chatTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.gateway.map { _ in attributes.gatewayName } ?? attributes.gatewayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                trailing
            }
            switch state.phase {
            case .working:
                if let step = state.step {
                    Label(step, systemImage: "apple.terminal")
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if let progress = state.progress, progress.total > 1 {
                    ProgressSegments(progress: progress)
                }
            case .needsYou:
                if let command = state.command {
                    Label {
                        Text(command)
                            .font(.system(.subheadline, design: .monospaced))
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(Palette.warning)
                    }
                    if let requestID = state.requestID {
                        AnswerButtons(attributes: attributes, requestID: requestID, onDark: false)
                    }
                } else if let question = state.question {
                    Label(question, systemImage: "questionmark.bubble.fill")
                        .font(.subheadline)
                        .lineLimit(2)
                }
            case .done:
                Label {
                    Text(doneLine)
                        .font(.subheadline)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: state.ok == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(state.ok == false ? Palette.danger : Palette.success)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var trailing: some View {
        switch state.phase {
        case .working:
            if let started = state.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72, alignment: .trailing)
            }
        case .needsYou:
            Text("Waiting")
                .font(.title3.weight(.medium))
                .foregroundStyle(Palette.warning)
        case .done:
            if let started = state.startedAt, let ended = state.endedAt {
                Text(Duration.seconds(max(0, ended.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doneLine: String {
        let result = state.result?.trimmingCharacters(in: .whitespaces) ?? ""
        if state.ok == false { return result.isEmpty ? String(localized: "Didn't finish") : result }
        if result.isEmpty { return String(localized: "Done") }
        // Replies often open with "Done." already: don't say it twice.
        return result.lowercased().hasPrefix("done") ? result : String(localized: "Done · \(result)")
    }
}

/// The app icon: the white wing on black.
struct AppTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(.black)
            .frame(width: 40, height: 40)
            .overlay {
                HermesWing()
                    .fill(.white)
                    .padding(9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// Plan steps done, the current one, and the rest.
struct ProgressSegments: View {
    let progress: TurnActivityState.Progress

    var body: some View {
        let total = min(progress.total, 12)
        let done = min(progress.done, total)
        HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index < done ? AnyShapeStyle(.primary) : index == done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(min(done + 1, total)) of \(total)")
    }
}

/// Deny and Allow Once, each after Face ID.
struct AnswerButtons: View {
    let attributes: TurnActivityAttributes
    let requestID: String
    let onDark: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: AnswerFromActivityIntent(gatewayID: attributes.gatewayID, sessionID: attributes.sessionID, requestID: requestID, allow: false)) {
                Text("Deny")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(onDark ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            }
            .buttonStyle(.plain)
            Button(intent: AnswerFromActivityIntent(gatewayID: attributes.gatewayID, sessionID: attributes.sessionID, requestID: requestID, allow: true)) {
                Text("Allow Once")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(onDark ? Color.black : Palette.onInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(onDark ? AnyShapeStyle(Color.white) : AnyShapeStyle(Palette.ink), in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Dynamic Island

struct IslandStatus: View {
    let state: TurnActivityState

    var body: some View {
        switch state.phase {
        case .working:
            if let started = state.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: 52, alignment: .trailing)
            }
        case .needsYou:
            Text("Needs you")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.warning)
        case .done:
            Image(systemName: state.ok == false ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(state.ok == false ? Palette.danger : Palette.success)
                .accessibilityLabel(state.ok == false ? "Didn't finish" : "Done")
        }
    }
}

/// `islandExpanded`: the command and the answers, or the current step.
struct IslandDetail: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state.phase {
            case .needsYou:
                if let command = state.command {
                    Text(command)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    if let requestID = state.requestID {
                        AnswerButtons(attributes: attributes, requestID: requestID, onDark: true)
                    }
                } else if let question = state.question {
                    Text(question)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                }
            case .working:
                if let step = state.step {
                    Text(step)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if let progress = state.progress, progress.total > 1 {
                    ProgressSegments(progress: progress)
                        .environment(\.colorScheme, .dark)
                }
            case .done:
                Text(state.result ?? String(localized: "Done"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}
