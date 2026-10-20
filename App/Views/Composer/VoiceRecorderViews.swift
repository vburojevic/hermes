import HermesKit
import SwiftUI

/// Where the finger is while it holds the microphone (`docs/voice.md` §2).
@MainActor
@Observable
final class HoldGesture {
    /// How far the finger has moved since it went down.
    var offset: CGSize = .zero
    /// Past half the bar: let go and it's gone.
    var cancelArmed = false
    /// Over the lock.
    var lockArmed = false
    /// The finger is down and the recording has begun (or is coming up).
    var isHolding = false

    func reset() {
        offset = .zero
        cancelArmed = false
        lockArmed = false
        isHolding = false
    }

    /// Up past this onto the lock.
    static let lockDistance: CGFloat = 110
}

/// The composer's microphone (`docs/composer.md` §3): tap to dictate; hold to record a voice
/// message, which grows it to 76 pt and turns it red (`recorderButton`). Slide left to cancel,
/// up onto the lock to record hands-free (`recorderLock`).
struct MicButton: View {
    let recorder: VoiceRecorder
    let hold: HoldGesture
    /// Half the composer's width: sliding left this far cancels.
    let cancelDistance: CGFloat
    let onDictate: () -> Void
    let onRecord: () -> Void
    let onSend: () -> Void
    let onCancel: () -> Void
    let onLock: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressedAt: Date?
    @State private var holdTask: Task<Void, Never>?
    /// The press lasted long enough to be a hold, whatever came of it.
    @State private var wasLong = false

    /// A press longer than this is a hold.
    private static let holdDelay: Duration = .milliseconds(280)

    private var isRecordingHeld: Bool { hold.isHolding && recorder.isActive }

    var body: some View {
        Image(systemName: "mic")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .opacity(isRecordingHeld ? 0 : 1)
            .overlay {
                if isRecordingHeld {
                    // Under the finger: 76 pt and red while recording.
                    ZStack {
                        Circle()
                            .fill(Theme.danger)
                            .shadow(color: Theme.dangerHalo, radius: 9)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Theme.inkForeground)
                    }
                    .frame(width: 76, height: 76)
                    .offset(x: max(-cancelDistance, min(0, hold.offset.width)), y: hold.lockArmed ? 0 : min(0, hold.offset.height) * 0.4)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if isRecordingHeld {
                    RecorderLock(progress: min(1, max(0, -hold.offset.height / HoldGesture.lockDistance)))
                        .offset(y: -128)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.2), value: isRecordingHeld)
            .gesture(press)
            .sensoryFeedback(.start, trigger: isRecordingHeld) { _, new in new }
            .sensoryFeedback(.impact, trigger: hold.cancelArmed) { _, new in new }
            .sensoryFeedback(.impact(weight: .light), trigger: hold.lockArmed) { _, new in new }
            .accessibilityElement()
            .accessibilityLabel("Dictate")
            .accessibilityHint("Hold to record a voice message")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onDictate() }
            .accessibilityAction(named: "Record a voice message") {
                // VoiceOver can't hold and slide: it records hands-free.
                onRecord()
                onLock()
            }
            .help("Dictate · hold to record a voice message")
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pressedAt == nil {
                    pressedAt = .now
                    holdTask = Task {
                        try? await Task.sleep(for: Self.holdDelay)
                        guard !Task.isCancelled else { return }
                        wasLong = true
                        hold.isHolding = true
                        onRecord()
                    }
                }
                guard hold.isHolding else { return }
                hold.offset = value.translation
                if !hold.cancelArmed, value.translation.width < -cancelDistance {
                    hold.cancelArmed = true
                    onCancel()
                } else if !hold.lockArmed, value.translation.height < -HoldGesture.lockDistance {
                    hold.lockArmed = true
                    onLock()
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                holdTask = nil
                pressedAt = nil
                if !wasLong {
                    // A tap: dictate.
                    if abs(value.translation.width) < 20, abs(value.translation.height) < 20 { onDictate() }
                } else if hold.isHolding, !hold.cancelArmed, !hold.lockArmed {
                    onSend()
                }
                wasLong = false
                hold.reset()
            }
    }
}

/// The lock above the finger while it holds (`recorderLock`): slide up onto it to record
/// hands-free.
struct RecorderLock: View {
    /// How close the finger is, 0…1.
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .opacity(1 - progress)
        }
        .frame(width: 44, height: 92 - 24 * progress)
        .glassEffect(.regular, in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Words as they're heard: settled ones ink, the newest lighter until they settle.
struct RecorderWords: View {
    let settled: String
    let volatile: String
    var placeholder: String?

    var body: some View {
        Group {
            if settled.isEmpty, volatile.isEmpty, let placeholder {
                Text(placeholder)
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Text("\(Text(settled.isEmpty ? "" : settled + " ").foregroundStyle(Theme.primaryText))\(Text(volatile).foregroundStyle(Theme.tertiaryText))")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text("\(settled) \(volatile)"))
    }
}

/// Holding (`recorder`): the red dot and the time, the live waveform and "Slide to cancel",
/// which follows the finger. The microphone stays where the finger is, at the end.
struct RecorderHoldBar: View {
    let recorder: VoiceRecorder
    let hold: HoldGesture

    var body: some View {
        HStack(spacing: 10) {
            RecordingDot(size: 10)
            Text(Waveform.time(recorder.duration))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
            // The waveform gives way first: "Slide to cancel" is always whole.
            WaveformBars(levels: recorder.levels, isLive: true)
                .frame(minWidth: 24, maxWidth: 116)
                .frame(height: 22)
            Text("‹ Slide to cancel")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .offset(x: min(0, hold.offset.width * 0.5))
                .opacity(1 + min(0, hold.offset.width) / 160)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        // The red microphone reaches this far left of its own place.
        .padding(.trailing, 22)
        .frame(height: 36)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording, \(Waveform.time(recorder.duration))"))
    }
}

/// The red dot of a recording. It doesn't pulse: the time and the waveform already move.
struct RecordingDot: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A round control in the recorder's bar: 36 pt.
private struct RecorderControl: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color = Theme.primaryText
    var fill: Color = Theme.controlFill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(fill, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .help(Text(label))
    }
}

/// Locked (`recorderLocked`): recording hands-free. The transcript builds above; Delete, Pause
/// (into Review) and Send below. A banner from 9:30; at 10:00 it pauses.
struct RecorderLockedPanel: View {
    let recorder: VoiceRecorder
    let onDelete: () -> Void
    let onPause: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if recorder.isNearLimit {
                Label("Recording stops at 10:00", systemImage: "clock")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
            ScrollView {
                RecorderWords(settled: recorder.settled, volatile: recorder.volatile, placeholder: String(localized: "Listening…"))
                    .padding(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 12))
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            .defaultScrollAnchor(.bottom)
            HStack(spacing: 10) {
                RecorderControl(symbol: "trash.fill", label: "Delete", tint: Theme.danger, action: onDelete)
                RecordingDot(size: 8)
                Text(Waveform.time(recorder.duration))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .accessibilityLabel(Text("Recording, \(Waveform.time(recorder.duration))"))
                WaveformBars(levels: recorder.levels, isLive: true)
                    .frame(width: 96, height: 20)
                Spacer(minLength: 0)
                RecorderControl(symbol: "pause.fill", label: "Pause", action: onPause)
                RecorderControl(symbol: "arrow.up", label: "Send", tint: Theme.inkForeground, fill: Theme.ink, action: onSend)
            }
            .padding(.horizontal, 2)
            .frame(height: 44)
        }
        .animation(.easeOut(duration: 0.2), value: recorder.isNearLimit)
    }
}

/// Paused (`recorderReview`): listen back, scrub, fix a word in the transcript (Hermes reads the
/// transcript), keep recording, or send.
struct RecorderReviewPanel: View {
    @Bindable var recorder: VoiceRecorder
    let onDelete: () -> Void
    let onResume: () -> Void
    let onSend: () -> Void

    @FocusState private var editing: Bool
    @State private var scrubbing: Double?
    @State private var width: CGFloat = 1

    private var player: ClipPlayer { recorder.playback }
    private static let clipID = "review"

    private var progress: Double {
        if let scrubbing { return scrubbing }
        guard player.clipID == Self.clipID, recorder.duration > 0 else { return 0 }
        return min(1, player.position / recorder.duration)
    }

    private var transcript: Binding<String> {
        Binding(get: { recorder.transcript }, set: { recorder.editTranscript($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                TextField("No words heard. Type what you said.", text: transcript, axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1...6)
                    .focused($editing)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Transcript")
                    .accessibilityHint("What Hermes reads. Fix a word here.")
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.top, 3)
                    .opacity(editing ? 0 : 1)
                    .accessibilityHidden(true)
            }
            .padding(EdgeInsets(top: 2, leading: 12, bottom: 4, trailing: 12))
            HStack(spacing: 10) {
                RecorderControl(symbol: "trash.fill", label: "Delete", tint: Theme.danger, action: onDelete)
                RecorderControl(symbol: player.isPlaying(Self.clipID) ? "pause.fill" : "play.fill",
                                label: player.isPlaying(Self.clipID) ? "Pause" : "Play") {
                    togglePlayback()
                }
                ZStack(alignment: .leading) {
                    WaveformBars(levels: recorder.levels, progress: progress)
                        .frame(height: 20)
                    Capsule()
                        .fill(Theme.ink)
                        .frame(width: 3, height: 24)
                        .offset(x: max(0, min(width - 3, width * progress - 1.5)))
                        .accessibilityHidden(true)
                }
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in scrubbing = Double(min(1, max(0, value.location.x / max(1, width)))) }
                        .onEnded { _ in
                            let target = scrubbing ?? 0
                            scrubbing = nil
                            seek(to: target)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Recording")
                .accessibilityValue(Text("\(Waveform.time(progress * recorder.duration)) of \(Waveform.time(recorder.duration))"))
                .accessibilityAdjustableAction { direction in
                    let step = 5 / max(1, recorder.duration)
                    seek(to: min(1, max(0, progress + (direction == .increment ? step : -step))))
                }
                Text("\(Waveform.time(progress * recorder.duration)) / \(Waveform.time(recorder.duration))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                    .accessibilityHidden(true)
                RecorderControl(symbol: "mic.fill", label: "Keep Recording", action: onResume)
                RecorderControl(symbol: "arrow.up", label: "Send", tint: Theme.inkForeground, fill: Theme.ink, action: onSend)
                    .disabled(recorder.transcript.isEmpty && recorder.duration < VoiceRecorder.minimum)
            }
            .padding(.horizontal, 2)
            .frame(height: 44)
        }
    }

    private func togglePlayback() {
        guard let file = recorder.reviewFile else { return }
        Task { await player.toggle(Self.clipID, url: file) }
    }

    private func seek(to fraction: Double) {
        let time = fraction * recorder.duration
        if player.clipID == Self.clipID {
            player.seek(Self.clipID, to: time)
        } else if let file = recorder.reviewFile {
            Task { await player.play(Self.clipID, url: file, from: time) }
        }
    }
}

/// The dictation language (`docs/voice.md` §5): the languages on this device, the device's own,
/// and Add Language for the ones it can download. Picking one restarts dictation in it.
struct DictationLanguageMenu: View {
    let onChange: () -> Void

    @AppStorage(TalkPreferences.Key.language) private var language = ""
    @State private var installed: [Locale] = []
    @State private var available: [Locale] = []

    private var current: Locale { language.isEmpty ? .current : Locale(identifier: language) }

    var body: some View {
        Menu {
            Button {
                pick("")
            } label: {
                if language.isEmpty { Label("Device Language", systemImage: "checkmark") } else { Text("Device Language") }
            }
            Divider()
            ForEach(installed, id: \.identifier) { locale in
                Button {
                    pick(locale.identifier)
                } label: {
                    if language == locale.identifier { Label(Self.name(locale), systemImage: "checkmark") } else { Text(Self.name(locale)) }
                }
            }
            if !available.isEmpty {
                Menu("Add Language") {
                    ForEach(available, id: \.identifier) { locale in
                        Button(Self.name(locale)) { pick(locale.identifier) }
                    }
                }
            }
        } label: {
            Text(current.language.languageCode?.identifier.uppercased() ?? "–")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.controlFill, in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Dictation language")
        .accessibilityValue(Self.name(current))
        .task {
            let installedNow = await SpeechInput.installedDictationLocales()
            installed = installedNow.sorted { Self.name($0) < Self.name($1) }
            let have = Set(installedNow.map(\.identifier))
            available = await SpeechInput.supportedDictationLocales()
                .filter { !have.contains($0.identifier) }
                .sorted { Self.name($0) < Self.name($1) }
        }
    }

    private func pick(_ identifier: String) {
        guard identifier != language else { return }
        language = identifier
        onChange()
    }

    static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}
