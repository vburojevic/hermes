import HermesKit
import SwiftUI
import UniformTypeIdentifiers

/// The gateway that serves a chat's audio files (`/api/files/stream`), for voice messages and the
/// Bot's audio further down the view tree.
extension EnvironmentValues {
    @Entry var clipBackend: BackendClient?
}

/// The waveform drawn for sound everywhere (`blocks/audio.elyx`): rounded bars, ink for what has
/// played (or everything, live), tertiary for the rest.
struct WaveformBars: View {
    let levels: [Float]
    /// 0…1 played; `nil` draws none played.
    var progress: Double?
    var barWidth: CGFloat = 3
    var gap: CGFloat = 2
    /// Recording: the newest levels, one per bar, all ink.
    var isLive = false

    var body: some View {
        Canvas { context, size in
            let step = barWidth + gap
            let count = max(1, Int((size.width + gap) / step))
            let bars = isLive ? Self.recent(levels, count: count) : Waveform.bars(levels, count: count)
            let playedBars = isLive ? count : Int((progress ?? 0) * Double(count) + 0.5)
            for (index, level) in bars.enumerated() {
                let height = max(3, size.height * CGFloat(min(1, max(0, level))))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2, width: barWidth, height: height)
                let color = index < playedBars ? Theme.ink : Theme.tertiaryText
                context.fill(Capsule().path(in: rect), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }

    /// The newest `count` levels, quiet bars before them while the recording is young.
    private static func recent(_ levels: [Float], count: Int) -> [Float] {
        let tail = Array(levels.suffix(count))
        return Array(repeating: 0, count: count - tail.count) + tail
    }
}

/// 1×, 1.5×, 2×: the speed every clip plays at, pitch kept.
struct ClipSpeedButton: View {
    let player: ClipPlayer

    var body: some View {
        Button {
            player.rate = player.rate < 1.25 ? 1.5 : player.rate < 1.75 ? 2 : 1
        } label: {
            Text(Self.label(player.rate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Theme.controlFill, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Speed")
        .accessibilityValue(Self.label(player.rate))
    }

    static func label(_ rate: Double) -> String {
        rate == 1 ? "1×" : rate == 2 ? "2×" : "1.5×"
    }
}

/// Plays, scrubs and shows a clip's bars: what the bubble and the strip share.
@MainActor
@Observable
final class ClipModel {
    let id: String
    let path: String
    private(set) var levels: [Float] = []
    private(set) var duration: TimeInterval?
    private(set) var isLoading = false
    private(set) var failure: String?
    /// The file on this device, once it's here.
    private(set) var localURL: URL?
    /// Dragging along the waveform: where the finger is, 0…1.
    var scrubbing: Double?

    init(path: String) {
        self.id = path
        self.path = path
        if let shape = ClipShapes.cached(path) {
            levels = shape.levels
            duration = shape.duration
        }
    }

    var player: ClipPlayer { .shared }
    var isPlaying: Bool { player.isPlaying(id) }

    /// 0…1 played.
    var progress: Double? {
        scrubbing ?? player.progress(of: id)
    }

    /// The length, or how far it's played while it plays.
    var timeLabel: String {
        if let scrubbing, let duration { return Waveform.time(scrubbing * duration) }
        if player.clipID == id, player.position > 0 { return Waveform.time(player.position) }
        return duration.map(Waveform.time) ?? "–:––"
    }

    /// Fetches the clip (small; voice messages are fetched as they come into view) and reads its bars.
    func load(backend: BackendClient?) async {
        guard localURL == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let url = try await ClipFetcher.url(for: path, backend: backend)
            localURL = url
            if let shape = await ClipShapes.shape(of: url, id: id) {
                levels = shape.levels
                duration = shape.duration
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func toggle(backend: BackendClient?) async {
        if localURL == nil { await load(backend: backend) }
        guard let localURL else { return }
        await player.toggle(id, url: localURL)
        if let problem = player.failure, problem.id == id { failure = problem.message }
    }

    func seek(to fraction: Double, backend: BackendClient?) async {
        guard let duration else { return }
        let time = fraction * duration
        if player.clipID == id {
            player.seek(id, to: time)
        } else if let localURL {
            await player.play(id, url: localURL, from: time)
        } else {
            await load(backend: backend)
            if let localURL { await player.play(id, url: localURL, from: time) }
        }
    }

    /// Five seconds either way (VoiceOver's adjust).
    func skip(by seconds: TimeInterval, backend: BackendClient?) async {
        guard let duration, duration > 0 else { return }
        let now = player.clipID == id ? player.position : 0
        await seek(to: min(1, max(0, (now + seconds) / duration)), backend: backend)
    }
}

/// Tap the waveform to jump; while the clip is loaded, drag along it to scrub. A drag on a clip
/// that isn't playing is left to the chat's scrolling.
///
/// On iPhone and iPad the scrub is UIKit's pan, begun only by a sideways drag: a SwiftUI drag
/// on the waveform took the chat's vertical drags too, so the chat didn't scroll under a finger
/// that started on a loaded clip.
private struct Scrubbing: ViewModifier {
    let clip: ClipModel
    let backend: BackendClient?
    @State private var width: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                Task { await clip.seek(to: fraction(point.x), backend: backend) }
            }
            #if os(iOS)
            .gesture(SidewaysSwipePan(tracksLocation: true, isEnabled: clip.player.clipID == clip.id,
                                      changed: { x in clip.scrubbing = fraction(x) },
                                      ended: { x, _ in seek(to: fraction(x)) },
                                      cancelled: { clip.scrubbing = nil }))
            #else
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in clip.scrubbing = fraction(value.location.x) }
                    .onEnded { _ in seek(to: clip.scrubbing ?? 0) },
                isEnabled: clip.player.clipID == clip.id
            )
            #endif
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    private func seek(to target: Double) {
        clip.scrubbing = nil
        Task { await clip.seek(to: target, backend: backend) }
    }

    private func fraction(_ x: CGFloat) -> Double {
        Double(min(1, max(0, x / max(1, width))))
    }
}

/// The person's voice message (`voiceMessage`): play, the waveform, the length and the speed, and
/// under it the transcript, which is what Hermes read.
struct VoiceMessageBubble: View {
    let entry: UserEntry
    let path: String
    var fill = Theme.surface

    @Environment(\.clipBackend) private var backend
    @State private var clip: ClipModel
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0
    @State private var exporting = false

    init(entry: UserEntry, path: String, fill: Color = Theme.surface) {
        self.entry = entry
        self.path = path
        self.fill = fill
        _clip = State(initialValue: ClipModel(path: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await clip.toggle(backend: backend) }
                } label: {
                    ZStack {
                        Circle().fill(Theme.ink)
                        if clip.isLoading, !clip.isPlaying {
                            Spinner(size: .mini).tint(Theme.inkForeground)
                        } else {
                            Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.inkForeground)
                        }
                    }
                    .frame(width: 32, height: 32)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHidden(true)
                WaveformBars(levels: clip.levels, progress: clip.progress)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity)
                    .modifier(Scrubbing(clip: clip, backend: backend))
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.timeLabel)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText)
                    ClipSpeedButton(player: clip.player)
                }
                .frame(width: 44, alignment: .leading)
            }
            if let failure = clip.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Theme.danger)
            }
            if !entry.text.isEmpty {
                transcript
            }
        }
        .padding(EdgeInsets(top: 10, leading: 10, bottom: 12, trailing: 12))
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        .task(id: path) { await clip.load(backend: backend) }
        .contextMenu {
            Button("Copy Transcript", systemImage: "doc.on.doc") { Pasteboard.copy(entry.text) }
                .disabled(entry.text.isEmpty)
            if let url = clip.localURL {
                Button("Save Audio…", systemImage: "square.and.arrow.down") { exporting = true }
                ShareLink(item: url)
            }
        }
        .fileExporter(isPresented: $exporting, item: clip.localURL.map(AudioFileItem.init), contentTypes: [.mpeg4Audio], defaultFilename: (path as NSString).lastPathComponent) { _ in }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Your voice message, \(clip.duration.map(Waveform.time) ?? ""): \(entry.text)"))
        .accessibilityValue(clip.isPlaying ? Text("Playing, \(clip.timeLabel)") : Text(verbatim: ""))
        .accessibilityAction { Task { await clip.toggle(backend: backend) } }
        .accessibilityAdjustableAction { direction in
            Task { await clip.skip(by: direction == .increment ? 5 : -5, backend: backend) }
        }
        .accessibilityAction(named: "Speed \(ClipSpeedButton.label(clip.player.rate))") {
            clip.player.rate = clip.player.rate < 1.25 ? 1.5 : clip.player.rate < 1.75 ? 2 : 1
        }
    }

    /// Three lines, then More.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(isExpanded ? nil : 3)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { shownHeight = $0 }
                .background(alignment: .top) {
                    Text(entry.text)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullHeight = $0 }
                }
            if !isExpanded, fullHeight > shownHeight + 1 {
                Button("More") { withAnimation(Theme.gentle) { isExpanded = true } }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.primaryText)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }
}

/// Audio the Bot sent (`listenStrip`, `docs/voice.md` §2): a voice message from
/// `[[audio_as_voice]]`, or a file a tool wrote, titled with its name. Played from the gateway.
struct ListenStrip: View {
    let audio: AgentAudio

    @Environment(\.clipBackend) private var backend
    @State private var clip: ClipModel

    init(audio: AgentAudio) {
        self.audio = audio
        _clip = State(initialValue: ClipModel(path: audio.path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !audio.isVoice {
                Label(audio.fileName, systemImage: "waveform")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await clip.toggle(backend: backend) }
                } label: {
                    ZStack {
                        Circle().fill(clip.isPlaying ? Theme.ink : Theme.controlFill)
                        if clip.isLoading, !clip.isPlaying {
                            Spinner(size: .mini)
                        } else {
                            Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(clip.isPlaying ? Theme.inkForeground : Theme.primaryText)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHidden(true)
                WaveformBars(levels: clip.levels, progress: clip.progress, barWidth: 2.5)
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
                    .modifier(Scrubbing(clip: clip, backend: backend))
                Text(clip.timeLabel)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                ClipSpeedButton(player: clip.player)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12))
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let failure = clip.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        // Fetched when played: a tool's file can be long.
        .task(id: audio.path) {
            if audio.isVoice { await clip.load(backend: backend) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(audio.isVoice ? Text("Voice message, \(clip.duration.map(Waveform.time) ?? "")") : Text("Audio, \(audio.fileName)"))
        .accessibilityValue(clip.isPlaying ? Text("Playing, \(clip.timeLabel)") : Text(verbatim: ""))
        .accessibilityAction { Task { await clip.toggle(backend: backend) } }
        .accessibilityAdjustableAction { direction in
            Task { await clip.skip(by: direction == .increment ? 5 : -5, backend: backend) }
        }
    }
}

/// A recording to save with Save Audio….
nonisolated struct AudioFileItem: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { item in SentTransferredFile(item.url) }
    }
}
