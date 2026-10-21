import HermesKit
import HermesMarkdown
import SwiftUI
#if os(iOS)
import AVKit
#endif

/// Talk (`screens/iphone/talk.elyx`, `docs/voice.md` §4.3): the face in its rings, the state and
/// what's being said, and the call controls. Full screen on iPhone and iPad portrait; the iPad
/// landscape panel and the Mac window use `TalkPanel`.
struct TalkScreen: View {
    let session: any TalkDisplay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTranscript = false
    @GestureState private var dragDown: CGFloat = 0

    private var center: TalkCenter { .shared }
    private var compactFigure: Bool { session.phase == .approval || session.pendingRequest != nil && session.phase == .needsTyping }

    var body: some View {
        VStack(spacing: 0) {
            TalkTopBar(session: session, showsTranscript: $showsTranscript)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            #if DEBUG
            // `-HERMES_TALK_LATENCY YES`: from the end of speech to the first audio (`docs/voice.md` §12).
            if UserDefaults.standard.bool(forKey: "HERMES_TALK_LATENCY"), let latency = (session as? TalkSession)?.lastLatency {
                Text("First audio \(latency, format: .number.precision(.fractionLength(2))) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(latency < 2 ? Theme.success : Theme.danger)
            }
            #endif
            Spacer(minLength: 8)
            TalkFigure(session: session, size: compactFigure ? 84 : 160)
            TalkTexts(session: session, large: !compactFigure)
                .padding(.horizontal, 32)
                .padding(.top, compactFigure ? 14 : 26)
            if let step = session.runningStep {
                StepChip(title: step.title, since: step.since)
                    .padding(.top, 36)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            if let card = session.card, session.phase == .speaking || session.phase == .listening {
                CallCard(markdown: card, speaker: session.speakerName)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            TalkBottom(session: session)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .contentShape(Rectangle())
        // A tap anywhere stops the Bot, like talking over it.
        .onTapGesture { if session.phase == .speaking { session.interrupt() } }
        .offset(y: max(0, dragDown))
        .gesture(
            DragGesture(minimumDistance: 20)
                .updating($dragDown) { value, state, _ in
                    if value.translation.height > 0 { state = value.translation.height * 0.6 }
                }
                .onEnded { value in
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 260 { center.isExpanded = false }
                }
        )
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Theme.spring, value: session.phase)
        .animation(Theme.snappy, value: dragDown == 0)
        .accessibilityAction(.escape) { center.isExpanded = false }
        .sheet(isPresented: $showsTranscript) {
            TalkTranscript(session: session)
        }
        .sensoryFeedback(.start, trigger: session.startedAt)
    }
}

/// The chevron (minimise), who and how long ("2:14 · Realtime"), and the transcript.
private struct TalkTopBar: View {
    let session: any TalkDisplay
    @Binding var showsTranscript: Bool

    var body: some View {
        HStack {
            Button {
                TalkCenter.shared.isExpanded = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(nil)
            .accessibilityLabel("Minimise")
            .accessibilityHint("Keeps the call going while you read the chat")
            Spacer()
            VStack(spacing: 1) {
                Text(session.speakerName)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                TalkMeta(session: session)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button {
                showsTranscript = true
            } label: {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(nil)
            .accessibilityLabel("Transcript")
        }
        .foregroundStyle(Theme.primaryText)
    }
}

/// "2:14 · Realtime": the call's length counts by itself, without redrawing the screen.
struct TalkMeta: View {
    let session: any TalkDisplay

    var body: some View {
        HStack(spacing: 0) {
            if let started = session.startedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                Text(" · ")
            }
            Text(session.engineName)
        }
        .lineLimit(1)
    }
}

/// The face in its rings (`docs/bot-faces.md` §5.3): rings follow the microphone while listening,
/// the body squashes with the real output level while speaking, the face works while working.
struct TalkFigure: View {
    let session: any TalkDisplay
    var size: CGFloat = 160

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(
                    stops: [
                        .init(color: Palette.aura, location: 0),
                        .init(color: Palette.auraSoft, location: 0.55),
                        .init(color: Palette.auraSoft.opacity(0), location: 1),
                    ],
                    center: .center, startRadius: 0, endRadius: size
                ))
                .frame(width: size * 2, height: size * 2)
                .opacity(session.phase == .listening ? 0.6 : 1)
            if session.phase == .listening || session.phase == .connecting {
                TalkRings(level: session.isMuted ? 0 : session.inputLevel, size: size, color: session.figureAppearance.color, moves: !reduceMotion)
                    .transition(.opacity)
            }
            TalkFace(session: session, size: size, moves: !reduceMotion)
        }
        .frame(width: size * 1.9, height: size * 1.9)
        .accessibilityHidden(true)
    }
}

/// Only the face reads the output level (30 a second while speaking), so nothing else redraws.
private struct TalkFace: View {
    let session: any TalkDisplay
    let size: CGFloat
    let moves: Bool

    var body: some View {
        BotFace(
            appearance: session.figureAppearance, size: size, mood: mood,
            needsYou: session.phase == .approval || session.phase == .needsTyping,
            look: session.phase == .working ? nil : CGVector(dx: 0, dy: 0.3),
            voiceLevel: session.phase == .speaking && moves ? Double(session.outputLevel) : nil,
            dots: true
        )
    }

    private var mood: BotMood {
        switch session.phase {
        case .listening, .connecting, .question: .listening
        case .working: .working
        case .offline, .onHold: .sleeping
        default: .idle
        }
    }
}

/// Three rings (`ring0`…`ring2`) that grow with the microphone's level.
private struct TalkRings: View {
    let level: Float
    let size: CGFloat
    let color: Color
    let moves: Bool

    var body: some View {
        ZStack {
            ForEach(Array([(1.875, 2.0, 0.35), (1.475, 2.0, 0.5), (1.1, 3.0, 0.8)].enumerated()), id: \.offset) { index, ring in
                Circle()
                    .strokeBorder(color.opacity(ring.2 * 0.35), lineWidth: ring.1)
                    .frame(width: size * ring.0, height: size * ring.0)
                    .scaleEffect(moves ? 1 + CGFloat(level) * (0.08 + 0.05 * CGFloat(index)) : 1)
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// The state, the words (settled ink, the rest lighter) and a hint.
struct TalkTexts: View {
    let session: any TalkDisplay
    var large = true
    var centered = true

    var body: some View {
        VStack(spacing: 10) {
            if let notice = session.notice {
                Text(notice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.controlFill, in: Capsule())
            }
            Text(session.status)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .contentTransition(.opacity)
            if session.showsCaptions || session.phase != .listening && session.phase != .speaking, let caption = session.caption {
                Text.caption(caption)
                    .font(large ? .title3 : .body)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .lineLimit(large ? 6 : 4)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let note = session.setupNote {
                // Talk answers in this device's voice: why, and Set Up… (`docs/voice.md` §6.1).
                VoiceSetupNote(status: note, beforeOpening: { TalkCenter.shared.isExpanded = false })
                    .multilineTextAlignment(centered ? .center : .leading)
                    .padding(.horizontal, 24)
            }
            if let hint = session.hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
    }
}

/// The step running ("df -h /volume1 · 3 s"), a quiet chip.
private struct StepChip: View {
    let title: String
    let since: Date

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("·")
                .foregroundStyle(Theme.tertiaryText)
            Text(timerInterval: since...Date.distantFuture, countsDown: false, showsHours: false)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: 48, alignment: .leading)
        }
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.controlFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// "Hermes showed you a card": the table or code the reply put in the chat (`talkCard`).
private struct CallCard: View {
    let markdown: String
    let speaker: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(speaker) showed you a card")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
            MarkdownView(text: markdown)
                .frame(maxHeight: 180, alignment: .top)
                .clipped()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The controls, or what replaces them: the approval card, a request card, Open Settings, Try Again.
private struct TalkBottom: View {
    let session: any TalkDisplay

    var body: some View {
        switch session.phase {
        case .noMicrophone:
            ChoiceButtons(
                primary: String(localized: "Open Settings"), primaryAction: TalkActions.openSettings,
                secondary: String(localized: "Type Instead"), secondaryAction: { TalkActions.type(session) }
            )
        case .offline, .failed:
            ChoiceButtons(
                primary: String(localized: "Try Again"), primaryAction: session.retry,
                secondary: String(localized: "End"), secondaryAction: TalkCenter.shared.end
            )
        case .approval:
            if let approval = session.pendingApproval {
                ApprovalCard(approval: approval, asker: session.speakerName) { choice in session.respond(choice, to: approval) }
                    .id(approval.id)
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
            }
        case .needsTyping:
            if let request = session.pendingRequest {
                if let chat = session.chat {
                    RequestCard(request: request, conversation: chat)
                        .id(request.id)
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.composer))
                }
            }
        default:
            CallControls(session: session)
        }
    }
}

private struct ChoiceButtons: View {
    let primary: String
    let primaryAction: () -> Void
    let secondary: String
    let secondaryAction: () -> Void

    var body: some View {
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
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

/// `callControls`: Mute, the audio route, Type, Captions, End, on a glass bar.
struct CallControls: View {
    let session: any TalkDisplay
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            CallButton(
                symbol: session.isMuted ? "mic.slash.fill" : "mic.fill",
                label: session.isMuted ? "Muted" : "Mute",
                isOn: session.isMuted, compact: compact,
                action: session.toggleMute
            )
            .accessibilityLabel(session.isMuted ? "Unmute" : "Mute")
            .keyboardShortcut(.space, modifiers: [])
            #if os(iOS)
            RouteControl(session: session, compact: compact)
            #endif
            if !compact {
                CallButton(symbol: "keyboard", label: "Type", compact: compact) { TalkActions.type(session) }
                    .accessibilityHint("Minimises the call and puts the cursor in the field")
            }
            CallButton(symbol: session.showsCaptions ? "captions.bubble.fill" : "captions.bubble", label: "Captions",
                       isOn: false, compact: compact) { session.showsCaptions.toggle() }
                .accessibilityValue(session.showsCaptions ? Text("On") : Text("Off"))
            CallButton(symbol: "phone.down.fill", label: "End", tint: Theme.danger, compact: compact, action: TalkCenter.shared.end)
                .accessibilityLabel("End call")
        }
        .padding(.top, compact ? 0 : 12)
        .padding(.horizontal, compact ? 0 : 10)
        .padding(.bottom, compact ? 0 : 10)
        .modifier(GlassBar(isOn: !compact))
    }
}

private struct GlassBar: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.glassEffect(.regular, in: .rect(cornerRadius: 36))
        } else {
            content
        }
    }
}

/// A round control with its label under it (44 pt or more, `docs/voice.md` §9).
struct CallButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var isOn = false
    var tint: Color?
    var compact = false
    let action: () -> Void

    private var diameter: CGFloat { compact ? 44 : 56 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 17 : 20, weight: .medium))
                    .foregroundStyle(tint != nil || isOn ? Theme.inkForeground : Theme.primaryText)
                    .frame(width: diameter, height: diameter)
                    .background(tint ?? (isOn ? Theme.ink : Theme.controlFill), in: Circle())
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: compact ? 54 : 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

#if os(iOS)
/// The audio route: shows where the call is (AirPods, Speaker, iPhone) and opens the system's
/// picker. An iPad has no earpiece, and the picker never offers one there.
private struct RouteControl: View {
    let session: any TalkDisplay
    let compact: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Theme.controlFill)
                Image(systemName: symbol)
                    .font(.system(size: compact ? 17 : 20, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                RoutePicker()
                    .opacity(0.02)
            }
            .frame(width: compact ? 44 : 56, height: compact ? 44 : 56)
            Text(name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .frame(width: compact ? 54 : 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio: \(name)")
        .accessibilityHint("Chooses where the call plays")
    }

    private var route: AudioRoute { session.route }

    private var name: String {
        switch route.output {
        case .bluetooth, .headphones: route.name.contains("AirPods") ? "AirPods" : route.name
        case .receiver: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        case .speaker: String(localized: "Speaker")
        case .car: String(localized: "Car")
        case .airPlay: route.name
        default: String(localized: "Audio")
        }
    }

    private var symbol: String {
        switch route.output {
        case .bluetooth: route.name.contains("AirPods") ? "airpods.pro" : "headphones"
        case .headphones: "headphones"
        case .receiver: "iphone"
        case .car: "car.fill"
        case .airPlay: "airplayaudio"
        default: "speaker.wave.2.fill"
        }
    }
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

/// What the controls do beyond the session.
enum TalkActions {
    /// Type: minimise and put the cursor in the call's composer ("Type into the call").
    static func type(_ session: any TalkDisplay) {
        TalkCenter.shared.isExpanded = false
        TalkCenter.shared.typeRequests += 1
    }

    static func openSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        #endif
    }
}

/// The iPad landscape panel (`ipadTalk`) and the Mac window (`macTalk`): the face in its rings,
/// the name and state, what's said, and Mute, Audio, Captions, End. Every state has its buttons.
struct TalkPanel: View {
    let session: any TalkDisplay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            TalkFigure(session: session, size: 84)
                .frame(height: 150)
            VStack(spacing: 2) {
                Text(session.speakerName)
                    .font(.headline)
                    .foregroundStyle(Theme.primaryText)
                HStack(spacing: 0) {
                    Text(session.status + " · ")
                    TalkMeta(session: session)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            }
            if let caption = session.caption, session.showsCaptions || session.phase != .listening {
                Text.caption(caption)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            panelBottom
        }
        .padding(18)
        .frame(width: 340)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if session.phase == .speaking { session.interrupt() } }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : Theme.spring, value: session.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(session.speakerName)
    }

    @ViewBuilder private var panelBottom: some View {
        switch session.phase {
        case .approval:
            if let approval = session.pendingApproval {
                ApprovalCard(approval: approval, asker: session.speakerName) { choice in session.respond(choice, to: approval) }
                    .id(approval.id)
            }
        case .needsTyping:
            if let request = session.pendingRequest, let chat = session.chat {
                RequestCard(request: request, conversation: chat)
                    .id(request.id)
            }
        case .noMicrophone:
            PanelButtons(primary: String(localized: "Open Settings"), action: TalkActions.openSettings)
        case .offline, .failed:
            PanelButtons(primary: String(localized: "Try Again"), action: session.retry)
        default:
            CallControls(session: session, compact: true)
        }
    }
}

private struct PanelButtons: View {
    let primary: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                Text(primary)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .inkFilledButton()
            Button(action: TalkCenter.shared.end) {
                Text("End")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Theme.danger, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("End call")
        }
    }
}

/// The call's words so far (`docs/voice.md` §9: captions one tap away): the chat's messages
/// since the call started.
private struct TalkTranscript: View {
    let session: any TalkDisplay
    @Environment(\.dismiss) private var dismiss

    private var lines: [TalkLine] { session.transcriptLines }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(lines, id: \.id) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.isUser ? String(localized: "You") : session.speakerName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                            Text(line.text)
                                .font(.body)
                                .foregroundStyle(Theme.primaryText)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if !session.heard.isEmpty {
                        Text(session.heard)
                            .font(.body)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Transcript")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension Text {
    /// The call's words: what's settled in ink, the rest lighter.
    static func caption(_ caption: (settled: String, lighter: String)) -> Text {
        Text("\(Text(caption.settled).foregroundStyle(Theme.primaryText))\(Text(caption.lighter).foregroundStyle(Theme.tertiaryText))")
    }
}
