import HermesKit
import HermesMarkdown
import SwiftUI

/// A reply to a voice message opens with the Bot's voice reading it (`listenStrip`, replies in
/// kind, `docs/voice.md` §2). The newest one plays by itself when only its listener can hear it
/// (headphones), or when the phone comes to the ear (Raise to Listen).
struct ReplyListenStrip: View {
    let reading: ListenPlayer.Reading
    /// The chat's newest reply: the one that may play by itself.
    var isLatest = false
    /// It just arrived (not a reply from before the chat was opened).
    var isFresh = false

    private var player: ListenPlayer { .shared }
    private var isReading: Bool { player.isReading(reading.id) }
    private var isPlaying: Bool { isReading && !player.isPaused }

    private var duration: TimeInterval {
        ListenPlayer.estimate(MarkdownDocumentText.spoken(reading.text))
    }

    private var progress: Double? {
        guard isReading else { return nil }
        return min(1, player.elapsed / max(1, player.estimatedDuration))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isReading { player.togglePause() } else { player.play(reading) }
            } label: {
                ZStack {
                    Circle().fill(isPlaying ? Theme.ink : Theme.controlFill)
                    if isReading, player.isStarting {
                        Spinner(size: .mini)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isPlaying ? Theme.inkForeground : Theme.primaryText)
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(PressableStyle())
            .accessibilityHidden(true)
            WaveformBars(levels: SpeechShape.levels(for: reading.text), progress: progress, barWidth: 2.5)
                .frame(height: 20)
                .frame(maxWidth: .infinity)
            Text(Waveform.time(isReading ? player.elapsed : duration))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
            ClipSpeedButton(player: .shared)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12))
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Listen to the reply, \(Waveform.time(duration))"))
        .accessibilityValue(isReading ? Text(player.isPaused ? "Paused" : "Playing") : Text(verbatim: ""))
        .accessibilityAction {
            if isReading { player.togglePause() } else { player.play(reading) }
        }
        .task(id: reading.id) {
            if isLatest, isFresh { player.autoplay(reading) }
        }
        #if os(iOS)
        .modifier(RaiseToListen(reading: reading, isOn: isLatest && TalkPreferences.raiseToListen))
        #endif
    }
}

/// The spoken text of a reply, for its length: parsed once per reply.
@MainActor
enum MarkdownDocumentText {
    private static var cache: [String: String] = [:]

    static func spoken(_ text: String) -> String {
        if let known = cache[text] { return known }
        let spoken = MarkdownDocument(parsing: text).spokenScript(detail: TalkPreferences.codeAndTables, descriptions: .app).text
        if cache.count > 64 { cache.removeAll() }
        cache[text] = spoken
        return spoken
    }
}

/// A waveform for words that haven't been synthesised yet: one bar a quarter second, shaped by
/// the words (a dip between sentences), the same every time for the same reply.
@MainActor
enum SpeechShape {
    private static var cache: [String: [Float]] = [:]

    static func levels(for text: String) -> [Float] {
        if let known = cache[text] { return known }
        let levels = shape(text)
        if cache.count > 64 { cache.removeAll() }
        cache[text] = levels
        return levels
    }

    private static func shape(_ text: String) -> [Float] {
        let spoken = MarkdownDocumentText.spoken(text)
        let count = max(8, min(400, Int(ListenPlayer.estimate(spoken) * 4)))
        let characters = Array(spoken.unicodeScalars)
        guard !characters.isEmpty else { return Array(repeating: 0.1, count: count) }
        return (0..<count).map { bar in
            let index = bar * characters.count / count
            let scalar = characters[index]
            if ".!?".unicodeScalars.contains(scalar) { return 0.05 }
            let seed = Float((scalar.value &* 2_654_435_761) % 1000) / 1000
            return 0.25 + 0.6 * seed
        }
    }
}

#if os(iOS)
/// Raise to Listen (`docs/voice.md` §2): with the phone at the ear, the reply plays to the
/// receiver; taken away, it pauses. The sensor is on only while the newest such reply shows.
private struct RaiseToListen: ViewModifier {
    let reading: ListenPlayer.Reading
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { if isOn { UIDevice.current.isProximityMonitoringEnabled = true } }
            .onDisappear { if isOn { UIDevice.current.isProximityMonitoringEnabled = false } }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)) { _ in
                guard isOn else { return }
                let player = ListenPlayer.shared
                if UIDevice.current.proximityState {
                    if player.isReading(reading.id) {
                        player.useReceiver(true)
                        player.resume()
                    } else {
                        player.play(reading, receiver: true)
                    }
                } else if player.isReading(reading.id), player.usesReceiver {
                    player.pause()
                    player.useReceiver(false)
                }
            }
    }
}
#endif

/// Listen's mini player (`miniPlayer`): glass, above the composer, in every chat while a reply is
/// read. The Bot's face, what it's reading, Back 15 s, Play/Pause, the speed and Close.
struct ListenMiniPlayer: View {
    private var player: ListenPlayer { .shared }

    var body: some View {
        if let reading = player.reading {
            HStack(spacing: 10) {
                BotFace(appearance: reading.context.appearance, size: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.isPaused ? "Paused" : "Listening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(reading.isPrivate ? reading.context.title : player.currentText ?? "")
                        .font(.footnote)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    player.back()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Theme.controlFill, in: Circle())
                }
                .accessibilityLabel("Back 15 seconds")
                Button {
                    player.togglePause()
                } label: {
                    Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.inkForeground)
                        .frame(width: 38, height: 38)
                        .background(Theme.ink, in: Circle())
                }
                .accessibilityLabel(player.isPaused ? "Play" : "Pause")
                ClipSpeedButton(player: .shared)
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(Theme.controlFill, in: Circle())
                }
                .accessibilityLabel("Stop Listening")
            }
            .buttonStyle(PressableStyle())
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10))
            .frame(height: 58)
            .glassEffect(.regular, in: Capsule())
            // Read in this device's voice: why, and Set Up… (`docs/voice.md` §6.1).
            .overlay(alignment: .top) {
                if let note = reading.context.setupNote {
                    VoiceSetupNote(status: note)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .offset(y: -40)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
