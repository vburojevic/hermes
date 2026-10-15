import HermesKit
import SwiftUI

/// Voice mode for a running ``VoiceSession``.
struct VoiceModeView: View {
    let session: VoiceSession
    /// Back to the chat with the composer focused.
    let onKeyboard: () -> Void
    let onEnd: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        VoiceScreen(
            state: VoiceScreen.State(
                phase: session.phase,
                title: session.title,
                status: session.status,
                caption: session.caption,
                captionIsSecondary: session.captionIsSecondary,
                hint: session.hint,
                speakerName: session.speakerName,
                botAppearance: session.botAppearance,
                level: session.listener.levels.last ?? 0,
                turnMood: session.conversation.turnMood,
                voiceLevel: { [speaker = session.speaker] date in speaker.level(at: date) },
                isMuted: session.isMuted,
                prefersSpeaker: session.prefersSpeaker,
                showsCaptions: session.showsCaptions,
                approval: session.conversation.pendingApproval
            ),
            actions: VoiceScreen.Actions(
                minimise: { session.isMinimised = true },
                toggleCaptions: { session.showsCaptions.toggle() },
                interrupt: session.interrupt,
                toggleMute: session.toggleMute,
                toggleSpeaker: { session.prefersSpeaker.toggle() },
                keyboard: onKeyboard,
                end: onEnd,
                retry: session.retry,
                openSettings: {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    #endif
                },
                respond: session.respond
            )
        )
    }
}

/// Voice mode (`screens/iphone/voice.elyx`): the wing (or the Bot's face) over a soft aura, what
/// is being said in large type, and Mute · Keyboard · Speaker · End. Swipe down or the chevron
/// minimises it; the conversation keeps going in the chat.
struct VoiceScreen: View {
    struct State {
        var phase: VoiceSession.Phase
        var title: String
        var status: String
        var caption: String?
        var captionIsSecondary = false
        var hint: String?
        var speakerName = "Hermes"
        var botAppearance: BotAppearance?
        var level: Float = 0
        /// What the turn is doing while it thinks: thinking, or working with a tool.
        var turnMood: BotMood = .thinking
        /// The Bot's own voice level at a moment, while it speaks (0…1).
        var voiceLevel: (Date) -> Double = { _ in 0 }
        var isMuted = false
        var prefersSpeaker = true
        var showsCaptions = true
        var approval: ApprovalRequest?
    }

    struct Actions {
        var minimise: () -> Void = {}
        var toggleCaptions: () -> Void = {}
        var interrupt: () -> Void = {}
        var toggleMute: () -> Void = {}
        var toggleSpeaker: () -> Void = {}
        var keyboard: () -> Void = {}
        var end: () -> Void = {}
        var retry: () -> Void = {}
        var openSettings: () -> Void = {}
        var respond: (ApprovalChoice) -> Void = { _ in }
    }

    let state: State
    let actions: Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragDown: CGFloat = 0

    private var isApproval: Bool { state.phase == .approval }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, 6)
            Spacer(minLength: 12)
            figure
            texts
                .padding(.horizontal, 32)
                .padding(.top, isApproval ? 18 : 30)
            Spacer(minLength: 16)
            bottom
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture {
            if state.phase == .speaking { actions.interrupt() }
        }
        .offset(y: max(0, dragDown))
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($dragDown) { value, state, _ in
                    if value.translation.height > 0 { state = value.translation.height * 0.6 }
                }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 260 {
                        actions.minimise()
                    }
                }
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Theme.spring, value: state.phase)
        .animation(Theme.snappy, value: dragDown == 0)
        .accessibilityAction(.escape) { actions.minimise() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button {
                actions.minimise()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(nil)
            .accessibilityLabel("Minimise")
            .accessibilityHint("Keeps the conversation going while you read the chat")
            Spacer()
            Text(state.title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                actions.toggleCaptions()
            } label: {
                Image(systemName: state.showsCaptions ? "text.bubble" : "text.bubble.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(nil)
            .accessibilityLabel("Captions")
            .accessibilityValue(state.showsCaptions ? Text("On") : Text("Off"))
        }
        .foregroundStyle(Theme.primaryText)
    }

    // MARK: Figure

    private var figureSize: CGFloat { isApproval ? 150 : 300 }

    private var figure: some View {
        Group {
            if let appearance = state.botAppearance {
                botFigure(appearance)
            } else {
                hermesFigure
            }
        }
        .frame(width: figureSize, height: figureSize)
        .accessibilityHidden(true)
    }

    /// A Bot is the voice (`docs/bot-faces.md` §5.3): rings in its colour follow the microphone
    /// while it listens, its body squashes with its own voice while it talks, and its eyes stay on
    /// the person.
    private func botFigure(_ appearance: BotAppearance) -> some View {
        let faceSize: CGFloat = isApproval ? 60 : 160
        return ZStack {
            VoiceRings(color: appearance.color, level: state.phase == .listening ? state.level : 0, faceSize: faceSize, enabled: !reduceMotion)
                .opacity(state.phase == .listening ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: state.phase == .listening)
            TimelineView(.animation(minimumInterval: 1 / 60, paused: state.phase != .speaking || reduceMotion)) { context in
                BotFace(
                    appearance: appearance, size: faceSize, mood: mood, needsYou: isApproval,
                    look: state.phase == .thinking ? nil : CGVector(dx: 0, dy: 0.3),
                    voiceLevel: state.phase == .speaking && !reduceMotion ? state.voiceLevel(context.date) : nil
                )
            }
        }
    }

    private var hermesFigure: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: Palette.aura, location: 0),
                        .init(color: Palette.auraSoft, location: 0.55),
                        .init(color: Palette.auraSoft.opacity(0), location: 1),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: figureSize / 2
                ))
                .frame(width: figureSize, height: figureSize)
                .modifier(AuraPulse(phase: state.phase, level: state.level, enabled: !reduceMotion))
            HermesMarkView(isAnimating: state.phase == .thinking)
                .frame(width: figureSize * 0.4, height: figureSize * 0.4)
        }
    }

    private var mood: BotMood {
        switch state.phase {
        case .listening: .listening
        case .thinking: state.turnMood == .working ? .working : .thinking
        case .offline: .sleeping
        default: .idle
        }
    }

    // MARK: Texts

    private var texts: some View {
        VStack(spacing: 10) {
            Text(state.status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.opacity)
            if state.showsCaptions || state.phase == .noMicrophone || state.phase == .offline || isApproval,
               let caption = state.caption {
                Text(caption)
                    .font(isApproval ? .body : .title3)
                    .foregroundStyle(state.captionIsSecondary ? Theme.secondaryText : Theme.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(isApproval ? 4 : 6)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let hint = state.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottom: some View {
        switch state.phase {
        case .noMicrophone:
            choiceButtons(
                primary: String(localized: "Open Settings"),
                primaryAction: actions.openSettings,
                secondary: String(localized: "Type Instead"),
                secondaryAction: actions.keyboard
            )
        case .offline, .failed:
            choiceButtons(
                primary: String(localized: "Try Again"),
                primaryAction: actions.retry,
                secondary: String(localized: "Back to Chat"),
                secondaryAction: actions.keyboard
            )
        case .approval:
            if let approval = state.approval {
                ApprovalCard(approval: approval, asker: state.speakerName) { choice in
                    actions.respond(choice)
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
                .padding(.horizontal, 10)
            }
        default:
            controls
        }
    }

    private func choiceButtons(primary: String, primaryAction: @escaping () -> Void, secondary: String, secondaryAction: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                Text(primary)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .inkFilledButton()
            Button(action: secondaryAction) {
                Text(secondary)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Theme.controlFill, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 32)
    }

    private var controls: some View {
        HStack {
            VoiceControl(
                symbol: state.isMuted ? "mic.slash.fill" : "mic",
                label: state.isMuted ? "Unmute" : "Mute",
                isOn: state.isMuted,
                action: actions.toggleMute
            )
            Spacer()
            VoiceControl(symbol: "keyboard", label: "Keyboard", action: actions.keyboard)
            Spacer()
            VoiceControl(
                symbol: state.prefersSpeaker ? "speaker.wave.2" : "iphone",
                label: state.prefersSpeaker ? "Speaker" : "Earpiece",
                action: actions.toggleSpeaker
            )
            Spacer()
            Button(action: actions.end) {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Theme.danger)
            .accessibilityLabel("End Voice")
        }
        .frame(maxWidth: 300)
        .padding(.horizontal, 24)
    }
}

/// A round Voice control on glass.
private struct VoiceControl: View {
    let symbol: String
    let label: LocalizedStringKey
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(isOn ? Theme.inkForeground : Theme.primaryText)
                .frame(width: 58, height: 58)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(isOn ? Theme.ink : nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Three rings in the Bot's colour (40%, 28% and 18%) that grow with the microphone level.
private struct VoiceRings: View {
    let color: Color
    let level: Float
    let faceSize: CGFloat
    let enabled: Bool

    var body: some View {
        ZStack {
            ForEach(Array([(1.32, 0.4), (1.62, 0.28), (1.92, 0.18)].enumerated()), id: \.offset) { index, ring in
                Circle()
                    .fill(color.opacity(ring.1))
                    .frame(width: faceSize * ring.0, height: faceSize * ring.0)
                    .scaleEffect(enabled ? 1 + CGFloat(level) * (0.12 + 0.06 * CGFloat(index)) : 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The aura follows the voice while listening and breathes while Hermes speaks.
private struct AuraPulse: ViewModifier {
    let phase: VoiceSession.Phase
    let level: Float
    let enabled: Bool

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if phase == .speaking || phase == .thinking {
            content.phaseAnimator([1.0, phase == .speaking ? 1.08 : 1.04]) { view, scale in
                view.scaleEffect(scale)
            } animation: { _ in
                .easeInOut(duration: phase == .speaking ? 0.9 : 1.6)
            }
        } else {
            content
                .scaleEffect(phase == .listening ? 1 + CGFloat(level) * 0.22 : 1)
                .animation(.easeOut(duration: 0.12), value: level)
        }
    }
}

/// Voice mode minimised: a glass pill above the composer, to open it again or end it.
struct VoiceMiniBar: View {
    let session: VoiceSession
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let appearance = session.botAppearance {
                    BotFace(appearance: appearance, size: 24, mood: session.phase == .thinking ? .thinking : .listening)
                } else {
                    HermesMark()
                        .fill(Theme.primaryText)
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: 28, height: 28)
            Button {
                session.isMinimised = false
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.status)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if let caption = session.caption, session.phase != .approval {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Voice")
            Button(action: session.toggleMute) {
                Image(systemName: session.isMuted ? "mic.slash.fill" : "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(session.isMuted ? "Unmute" : "Mute")
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.danger, in: Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("End Voice")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
