import AVFoundation
import HermesKit
import HermesMarkdown
import Observation
import os
import SwiftUI

/// Where a chat's replies are read from (`docs/voice.md` §3): who's speaking, with which voice,
/// for the mini player and Now Playing. Set by the chat screen.
struct ListenContext: Equatable {
    /// The chat's title, for Now Playing.
    var title: String
    /// "Hermes" or the Bot.
    var speaker: String
    var appearance: BotAppearance
    /// The gateway that speaks in the Bot's voice; `nil` reads with the device's voice.
    var backend: BackendClient?
    var profile: String?
    /// Listen's setup when it falls back to the device's voice, for the mini player's note.
    var setupNote: SetupStatus?
    /// The gateway's voice failed mid-reply (`docs/voice.md` §6.1).
    var onSpeechFailure: ((String) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.speaker == rhs.speaker && lhs.appearance == rhs.appearance
            && lhs.backend === rhs.backend && lhs.profile == rhs.profile && lhs.setupNote == rhs.setupNote
    }
}

extension EnvironmentValues {
    @Entry var listenContext: ListenContext?
}

/// Listen (`docs/voice.md` §3): reads one reply aloud at a time, in the Bot's own voice from the
/// gateway (`speak-stream`, a sentence at a time) or the device's best voice when the gateway has
/// none. It holds the coordinator's Listen role, keeps playing when the chat is left (the mini
/// player follows), and shows in Now Playing.
@MainActor
@Observable
final class ListenPlayer {
    static let shared = ListenPlayer()

    /// What's being read.
    struct Reading: Equatable {
        /// The reply (its turn id).
        var id: String
        /// The reply's Markdown, as the chat draws it, its widgets as words (`SpokenWidgets`).
        var text: String
        var context: ListenContext
        /// It reads a private widget: the mini player shows the chat, not the sentence, which the
        /// app switcher would keep (`docs/widgets.md` §8).
        var isPrivate = false
    }

    private(set) var reading: Reading?
    private(set) var script: SpokenScript?
    /// The sentence being heard, by its place in `script`.
    private(set) var sentence: Int?
    private(set) var isPaused = false
    /// Waiting for the first audio.
    private(set) var isStarting = false
    /// Seconds heard so far (the gateway gives no timings: counted while it plays).
    private(set) var elapsed: TimeInterval = 0
    /// Where it was at the last change (start, pause, skip, speed): Now Playing runs the clock
    /// on from here rather than being told every second.
    private(set) var timeline = Timeline(elapsed: 0, date: .now)

    struct Timeline: Equatable {
        var elapsed: TimeInterval
        var date: Date
    }
    /// 1, 1.5 or 2, shared with voice messages.
    var rate: Double {
        get { ClipPlayer.shared.rate }
        set {
            ClipPlayer.shared.rate = newValue
            player?.rate = Float(newValue)
            mark()
        }
    }

    var isActive: Bool { reading != nil }
    var isPlaying: Bool { reading != nil && !isPaused }

    func isReading(_ id: String) -> Bool { reading?.id == id }

    /// The sentence to light up in reply `id`.
    func highlight(for id: String) -> SpokenSentence? {
        guard reading?.id == id, let sentence, let script, script.sentences.indices.contains(sentence) else { return nil }
        return script.sentences[sentence]
    }

    /// The words being read, for the mini player.
    var currentText: String? {
        guard let script else { return nil }
        let index = sentence ?? 0
        return script.sentences.indices.contains(index) ? script.sentences[index].text : nil
    }

    /// About how long the whole reply takes at 1× (for Now Playing and the strip).
    var estimatedDuration: TimeInterval {
        guard let script else { return 0 }
        return Self.estimate(script.text)
    }

    /// Readers manage about 15 characters a second.
    static func estimate(_ text: String) -> TimeInterval {
        max(1, Double(text.count) / 15)
    }

    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var player: SpokenPlayer?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// The script's index of the player's first sentence (after a skip it starts part-way).
    @ObservationIgnored private var base = 0
    /// When each sentence started, in seconds heard.
    @ObservationIgnored private var starts: [Int: TimeInterval] = [:]
    /// Played to the receiver (Raise to Listen).
    @ObservationIgnored private(set) var usesReceiver = false
    @ObservationIgnored private var nowPlaying: NowPlayingPublisher?
    /// Replies that started by themselves once, so they never do again.
    @ObservationIgnored private var autoplayed: Set<String> = []

    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    private init() {}

    // MARK: Control

    /// Listen, or Stop Listening if this reply is the one being read.
    func toggle(_ reading: Reading) {
        if self.reading?.id == reading.id {
            stop()
        } else {
            play(reading)
        }
    }

    func play(_ reading: Reading, receiver: Bool = false) {
        stop()
        let script = MarkdownDocument(parsing: reading.text).spokenScript(detail: TalkPreferences.codeAndTables, descriptions: .app)
        guard !script.sentences.isEmpty else { return }
        self.reading = reading
        self.script = script
        usesReceiver = receiver
        elapsed = 0
        starts = [:]
        start(from: 0)
        nowPlaying = NowPlayingPublisher(player: self)
    }

    /// Plays a reply that answers a voice message by itself, once, when only its listener can
    /// hear it (headphones, or the phone at the ear).
    func autoplay(_ reading: Reading) {
        guard !autoplayed.contains(reading.id), self.reading == nil else { return }
        autoplayed.insert(reading.id)
        Task {
            guard await AudioCoordinator.shared.currentRoute.isPrivate else { return }
            play(reading)
        }
    }

    #if DEBUG
    /// `-HERMES_LISTEN <text>`: the mini player holding a reply, paused before a word is spoken
    /// (screenshots).
    func showPaused(_ reading: Reading) {
        stop()
        let script = MarkdownDocument(parsing: reading.text).spokenScript(detail: TalkPreferences.codeAndTables, descriptions: .app)
        guard !script.sentences.isEmpty else { return }
        self.reading = reading
        self.script = script
        sentence = 0
        isPaused = true
    }
    #endif

    func pause() {
        guard reading != nil, !isPaused else { return }
        player?.pause()
        isPaused = true
        clock?.cancel()
        mark()
    }

    func resume() {
        guard reading != nil, isPaused else { return }
        isPaused = false
        if player?.isPaused == true {
            player?.resume()
            tick()
            mark()
        } else {
            // Stopped by a skip or an interruption: read on from the sentence it was at.
            start(from: sentence ?? base)
        }
    }

    func togglePause() {
        if isPaused { resume() } else { pause() }
    }

    /// Back 15 seconds: to the sentence that was playing then.
    func back(by seconds: TimeInterval = 15) {
        guard reading != nil else { return }
        let target = max(0, elapsed - seconds)
        let index = starts.filter { $0.value <= target }.max { $0.value < $1.value }?.key ?? 0
        elapsed = starts[index] ?? 0
        start(from: index)
    }

    /// Ahead about 15 seconds: by the length of the sentences in between.
    func forward(by seconds: TimeInterval = 15) {
        guard let script, reading != nil else { return }
        var index = sentence ?? base
        var skipped: TimeInterval = 0
        while index + 1 < script.sentences.count, skipped < seconds {
            skipped += Self.estimate(script.sentences[index].text)
            index += 1
        }
        elapsed += skipped
        start(from: index)
    }

    func stop() {
        generation += 1
        clock?.cancel()
        events?.cancel()
        events = nil
        nowPlaying?.end()
        nowPlaying = nil
        let player = player
        let lease = lease
        let reading = reading
        self.player = nil
        self.lease = nil
        self.reading = nil
        script = nil
        sentence = nil
        isPaused = false
        isStarting = false
        Task {
            await player?.stop()
            player?.tearDown()
            if let lease { await AudioCoordinator.shared.release(lease) }
            if let backend = reading?.context.backend {
                await backend.ttsLease("app:listen", active: false, profile: reading?.context.profile)
            }
        }
    }

    /// Raise to Listen: the phone came to the ear (to the receiver) or went away (pause).
    func useReceiver(_ receiver: Bool) {
        guard usesReceiver != receiver, let lease else { return }
        usesReceiver = receiver
        Task { try? await AudioCoordinator.shared.update(lease, options: AudioRoleOptions(receiver: receiver)) }
    }

    // MARK: Internals

    /// (Re)starts reading at script sentence `index`, on the Listen role.
    private func start(from index: Int) {
        guard let reading, let script else { return }
        generation += 1
        let attempt = generation
        isStarting = true
        isPaused = false
        base = index
        sentence = index
        mark()
        let sentences = Array(script.sentences[index...])
        Task {
            if let player {
                await player.stop()
            }
            guard attempt == generation else { return }
            if lease == nil {
                do {
                    let lease = try await AudioCoordinator.shared.acquire(.listen, owner: "listen", options: AudioRoleOptions(receiver: usesReceiver))
                    guard attempt == generation else {
                        await AudioCoordinator.shared.release(lease)
                        return
                    }
                    self.lease = lease
                    follow(lease)
                    if let backend = reading.context.backend {
                        Task { await backend.ttsLease("app:listen", active: true, profile: reading.context.profile) }
                    }
                } catch {
                    Self.logger.error("listen didn't start: \(String(describing: error), privacy: .public)")
                    stop()
                    return
                }
            }
            guard let lease else { return }
            let player = self.player ?? makePlayer(on: lease.graph, reading: reading, language: DeviceVoice.language(of: script.text))
            self.player = player
            player.rate = Float(rate)
            player.enqueue(sentences)
            player.finishInput()
        }
    }

    private func makePlayer(on graph: AudioGraph, reading: Reading, language: String?) -> SpokenPlayer {
        let device = DeviceVoice(language: language)
        let player: SpokenPlayer
        if let backend = reading.context.backend {
            player = SpokenPlayer(graph: graph, voice: GatewayVoice(backend: backend, profile: reading.context.profile), fallback: device)
        } else {
            player = SpokenPlayer(graph: graph, voice: device)
        }
        player.onSentence = { [weak self] index in self?.heard(index) }
        player.onSpeaking = { [weak self] speaking in
            guard let self else { return }
            if speaking {
                isStarting = false
                tick()
                mark()
            }
        }
        player.onFinished = { [weak self] in self?.stop() }
        player.onFellBack = { why in reading.context.onSpeechFailure?(why) }
        return player
    }

    private func mark() {
        timeline = Timeline(elapsed: elapsed, date: .now)
    }

    private func heard(_ index: Int) {
        let absolute = base + index
        sentence = absolute
        if starts[absolute] == nil { starts[absolute] = elapsed }
    }

    /// Counts the seconds heard while it plays.
    private func tick() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, !self.isPaused, self.player?.isSpeaking == true else { continue }
                self.elapsed += 0.25 * self.rate
            }
        }
    }

    private func follow(_ lease: AudioLease) {
        events = Task { [weak self] in
            for await event in lease.events {
                guard let self else { return }
                switch event {
                case .paused:
                    // A call, Siri, or the headphones coming out (Apple's rule: pause).
                    self.pause()
                case .resumed:
                    self.resume()
                case .ended:
                    self.lease = nil
                    self.stop()
                case .engineRestarted:
                    self.player?.engineRestarted()
                case .routeChanged, .inputMuteChanged:
                    break
                }
            }
        }
    }
}

extension SpokenDescriptions {
    /// The app's wording for code and tables in spoken replies (`docs/voice.md` §3).
    static let app = SpokenDescriptions(
        code: { language in
            if let language, !language.isEmpty {
                let name = SpokenDescriptions.languageName(language)
                return String(localized: "I put the \(name) code in the chat.")
            }
            return String(localized: "I put the code in the chat.")
        },
        table: { rows in
            rows == 1 ? String(localized: "I put a table with 1 row in the chat.") : String(localized: "I put a table with \(rows) rows in the chat.")
        }
    )
}
