import ActivityKit
import AppIntents
import HermesPush
import SwiftUI
import WidgetKit

/// A call on the Lock Screen (`liveActivityTalk`) and in the Dynamic Island (`islandTalk`,
/// `islandTalkExpanded`): who you're talking with, what's happening and for how long, what was
/// last said, and Mute and End (`docs/voice.md` §4.4).
struct TalkActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TalkActivityAttributes.self) { context in
            TalkLockScreen(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TalkFace(attributes: attributes, state: state, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(attributes.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        TalkStatusLine(attributes: attributes, state: state)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TalkWave(isActive: state.phase == .speaking || state.phase == .listening)
                        .frame(width: 44, height: 18)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let line = state.line {
                            Text("“\(line)”")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                        }
                        HStack(spacing: 10) {
                            Button(intent: TalkMuteIntent()) {
                                Label(state.isMuted ? "Unmute" : "Mute", systemImage: state.isMuted ? "mic.slash.fill" : "mic.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .tint(.white.opacity(0.18))
                            Button(intent: TalkEndIntent()) {
                                Label("End", systemImage: "phone.down.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .tint(Palette.danger)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                TalkFace(attributes: attributes, state: state, size: 20)
                    .accessibilityLabel(attributes.title)
            } compactTrailing: {
                HStack(spacing: 4) {
                    TalkWave(isActive: true)
                        .frame(width: 18, height: 12)
                    Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 40)
                }
            } minimal: {
                TalkFace(attributes: attributes, state: state, size: 18)
                    .accessibilityLabel(attributes.title)
            }
            .keylineTint(state.phase == .needsYou ? Palette.warning : nil)
        }
    }
}

/// `liveActivityTalk`: the face, the name, "Listening · 2:14", the last words, Mute and End.
struct TalkLockScreen: View {
    let attributes: TalkActivityAttributes
    let state: TalkActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            TalkFace(attributes: attributes, state: state, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title)
                    .font(.headline)
                    .lineLimit(1)
                TalkStatusLine(attributes: attributes, state: state)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let line = state.line {
                    Text("“\(line)”")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(intent: TalkMuteIntent()) {
                Image(systemName: state.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.isMuted ? Color.white : Color.primary)
            .background(state.isMuted ? Color.black : Color.secondary.opacity(0.16), in: Circle())
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")
            Button(intent: TalkEndIntent()) {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(Palette.danger, in: Circle())
            .accessibilityLabel("End call")
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Listening · 2:14": the state and the call's length, counting by itself.
struct TalkStatusLine: View {
    let attributes: TalkActivityAttributes
    let state: TalkActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            Text(phase + " · ")
            Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        }
        .lineLimit(1)
    }

    private var phase: String {
        if state.isMuted, state.phase == .listening { return String(localized: "Muted") }
        return switch state.phase {
        case .connecting: String(localized: "Connecting")
        case .listening: String(localized: "Listening")
        case .working: String(localized: "Working")
        case .speaking: String(localized: "Speaking")
        case .needsYou: String(localized: "Needs you")
        case .onHold: String(localized: "On hold")
        }
    }
}

/// The Bot's face on its tile, or the Hermes wing. Activities don't animate: one frame.
struct TalkFace: View {
    let attributes: TalkActivityAttributes
    let state: TalkActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Group {
            if let face = attributes.face {
                StillFace(look: face, mood: state.phase == .working ? .working : .listening, size: size * 0.8, time: 0.6)
                    .frame(width: size, height: size)
                    .background(Color(face.color).opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                AppTile()
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Seven bars: the call's sound, drawn still (activities don't animate).
struct TalkWave: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach([0.4, 0.8, 0.55, 1, 0.5, 0.75, 0.35], id: \.self) { height in
                Capsule()
                    .fill(.white.opacity(isActive ? 1 : 0.5))
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: height, anchor: .center)
            }
        }
        .accessibilityHidden(true)
    }
}
