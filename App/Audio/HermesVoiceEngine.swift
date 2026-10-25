@preconcurrency import AVFoundation
import Foundation
import HermesKit
import HermesMarkdown
import Observation
import os

/// Talk's own audio path (`docs/voice.md` §4.2): transcription (on the device, or the gateway's
/// with Transcribe on: The gateway) and endpointing in, the Bot's voice out, through one engine
/// with voice processing for the whole call.
///
/// - The coordinator's Talk role is held from start to end, and the analyzer stays up: nothing is
///   rebuilt between turns, so it never goes deaf.
/// - What it hears is decided by `TalkEars`, frame by frame: the person's voice near the
///   microphone lowers the Bot at once, their words (or a stop word) stop it, and the room's
///   noise, a TV or the Bot's own echo do neither. A turn ends after the pause setting from the
///   person's voice and words only (`docs/voice.md` §4.2).
/// - Mute is the system's input mute (`AVAudioApplication`), so an AirPods stem press mutes too.
///   It never stops the Bot.
@MainActor
@Observable
final class HermesVoiceEngine {
    enum State: Equatable {
        case idle
        case starting
        case running
        /// The microphone is off for Hermes.
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What the person is saying in this turn: settled, then still being heard.
    private(set) var heardFinal = ""
    private(set) var heardVolatile = ""
    /// The microphone's level, 0…1.
    private(set) var inputLevel: Float = 0
    private(set) var isMuted = false
    /// The person is talking (voice activity), for the rings.
    private(set) var isHearingSpeech = false
    /// The room is about as loud as the person, so talking over the Bot may not stop it
    /// (`TalkEars.isLoud`).
    private(set) var isLoudRoom = false
    /// The speech model is downloading, 0…1.
    private(set) var downloadProgress: Double?
    /// The person talked while muted ("You're muted").
    private(set) var mutedSpeechAt: Date?
    /// The audio is paused by the system (a phone call).
    private(set) var isInterrupted = false
    private(set) var route = AudioRoute.unknown

    var heard: String { (heardFinal + heardVolatile).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The Bot's voice.
    private(set) var player: SpokenPlayer?
    var isSpeaking: Bool { player?.isSpeaking ?? false }
    var outputLevel: Float { player?.level ?? 0 }

    var pause: Endpointer.Pause = .normal {
        didSet { ears.endpointer.pause = pause }
    }

    /// Barge-in and end-of-turn decisions with what they were decided on, never the words:
    /// `log show --predicate 'subsystem == "co.caffeinatedcode.hermes" && category == "talk"'`.
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "talk")

    /// A spoken turn ended: its words, and when the speech ended (system uptime).
    var onTurn: ((String, TimeInterval) -> Void)?
    /// The first audio of a reply started playing (system uptime): the latency the person hears.
    var onFirstAudio: ((TimeInterval) -> Void)?
    /// The person talked over the Bot, which has been stopped.
    var onBargeIn: (() -> Void)?
    /// The Bot finished everything it was given.
    var onFinishedSpeaking: (() -> Void)?
    /// The gateway's voice failed and the device's took over (`docs/voice.md` §6.1).
    var onVoiceFellBack: ((String) -> Void)?
    /// The gateway couldn't transcribe and the device took over, with Hermes's reason.
    var onTranscriptionFellBack: ((String) -> Void)?
    /// A phone call or Siri took the audio (true) or gave it back (false).
    var onInterruption: ((Bool) -> Void)?
    /// Muted or unmuted, from the call or the system (Realtime follows).
    var onMuteChanged: ((Bool) -> Void)?
    /// The engine restarted (a route change, a media services reset): Realtime's nodes follow.
    var onEngineRestarted: (() -> Void)?

    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var input: (any TalkTranscriber)?
    @ObservationIgnored private var contextualStrings: [String] = []
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var ears = TalkEars()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var prefersSpeaker = true
    @ObservationIgnored private var endingTurn = false
    @ObservationIgnored private var cueChain: AudioPlayerChain?

    /// The call's sounds (`docs/voice.md` §4.2), quiet, in the same engine. Off with Sounds and
    /// haptics off.
    enum Cue {
        /// A soft rise when the call starts or carries on.
        case start
        /// A tick when a turn is sent.
        case sent
        /// A low pulse while Hermes works.
        case working
        /// A fall when the call ends.
        case end
    }

    func cue(_ cue: Cue) {
        guard TalkPreferences.sounds, let graph = lease?.graph else { return }
        if cueChain == nil { cueChain = try? graph.makePlayer(format: SpokenPlayer.format) }
        guard let chain = cueChain, let buffer = Self.tone(for: cue) else { return }
        chain.schedule(buffer)
        try? chain.play()
    }

    /// Short sine sweeps with soft edges.
    static func tone(for cue: Cue) -> AVAudioPCMBuffer? {
        let (from, to, seconds, volume): (Double, Double, Double, Float) = switch cue {
        case .start: (520, 880, 0.18, 0.18)
        case .sent: (1250, 1250, 0.035, 0.12)
        case .working: (220, 200, 0.12, 0.08)
        case .end: (880, 470, 0.22, 0.18)
        }
        let format = SpokenPlayer.format
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var phase = 0.0
        for index in 0..<Int(frames) {
            let progress = Double(index) / Double(frames)
            let frequency = from + (to - from) * progress
            phase += 2 * .pi * frequency / format.sampleRate
            let edge = min(1, min(progress, 1 - progress) * 12)
            samples[index] = Float(sin(phase)) * volume * Float(edge)
        }
        return buffer
    }

    /// Where a call's words come from when the gateway transcribes (`transcribe-stream`).
    struct GatewayTranscription {
        var backend: BackendClient
        var profile: String?
    }

    /// Starts listening. `voice` speaks replies; `fallback` takes over if it fails. With
    /// `transcription` the gateway hears the words.
    func start(voice: any SentenceVoice, fallback: (any SentenceVoice)?, contextualStrings: [String], speaker: Bool, transcription: GatewayTranscription? = nil) async {
        guard await takeAudio(speaker: speaker) else { return }
        await listen(voice: voice, fallback: fallback, contextualStrings: contextualStrings, transcription: transcription)
    }

    /// Takes the call's audio (the microphone and the coordinator's Talk role), so the call gets
    /// ready while it finds out which engine runs. `listen` or `runRealtime` carries on from here.
    func takeAudio(speaker: Bool) async -> Bool {
        if lease != nil { return true }
        return await acquire(speaker: speaker)
    }

    #if DEBUG
    /// The call is listening: the simulated microphone's clips count from now.
    func simulatedListeningStarted() {
        lease?.graph.simulatedListeningStarted()
    }
    #endif

    /// The audio already taken goes to Realtime, which brings its own ears. Returns the engine to
    /// play and record through.
    func runRealtime() -> AudioGraph? {
        guard let lease else { return nil }
        state = .running
        return lease.graph
    }

    /// Asks for the microphone and takes the Talk role.
    private func acquire(speaker: Bool) async -> Bool {
        guard state == .idle || state == .denied || isFailed else { return false }
        generation += 1
        let attempt = generation
        state = .starting
        prefersSpeaker = speaker
        guard await SpeechInput.requestMicrophone() else {
            if attempt == generation { state = .denied }
            return false
        }
        do {
            let lease = try await AudioCoordinator.shared.acquire(.talk, owner: "talk", options: AudioRoleOptions(prefersSpeaker: speaker))
            guard attempt == generation else {
                await AudioCoordinator.shared.release(lease)
                return false
            }
            self.lease = lease
            listenForMutedSpeech()
            route = await AudioCoordinator.shared.currentRoute
            isMuted = AVAudioApplication.shared.isInputMuted
            tasks.append(Task { [weak self] in
                for await event in lease.events { self?.handle(event) }
            })
            return true
        } catch {
            guard attempt == generation else { return false }
            await stop()
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Transcription and the Bot's voice, on the audio already taken: the call's start, or Hermes
    /// Voice taking over from Realtime mid-call.
    func listen(voice: any SentenceVoice, fallback: (any SentenceVoice)?, contextualStrings: [String], transcription: GatewayTranscription? = nil) async {
        guard let lease, input == nil else { return }
        let attempt = generation
        self.contextualStrings = contextualStrings
        if state != .running { state = .starting }
        do {
            // The gateway needs no speech model on the device.
            let prepared = transcription == nil ? try await prepareDevice() : nil
            guard attempt == generation else { return }
            let player = SpokenPlayer(graph: lease.graph, voice: voice, fallback: fallback)
            player.onSpeaking = { [weak self] speaking in self?.speakingChanged(speaking) }
            player.onFellBack = { [weak self] why in self?.onVoiceFellBack?(why) }
            player.onFinished = { [weak self] in self?.onFinishedSpeaking?() }
            player.onSentence = { [weak self] index in
                guard let self else { return }
                self.ears.botSaying(self.player?.textAround ?? "")
                #if DEBUG
                if AudioGraph.simulatedEcho != nil, let player = self.player, index < player.queued.count,
                   let input = self.input as? SpeechInput {
                    let sentence = player.queued[index].text
                    Task { await input.hearEcho(sentence) }
                }
                #endif
            }
            self.player = player
            if let transcription {
                let input = GatewayTranscriber(backend: transcription.backend, profile: transcription.profile)
                let events = try await input.start(on: lease.graph)
                guard attempt == generation else {
                    await input.cancel()
                    return
                }
                attach(input, events: events)
            } else if let prepared {
                let input = SpeechInput(deviceConfiguration)
                let events = try await input.start(on: lease.graph, prepared: prepared)
                guard attempt == generation else {
                    await input.cancel()
                    return
                }
                attach(input, events: events)
            }
            state = .running
        } catch {
            guard attempt == generation else { return }
            downloadProgress = nil
            await stop()
            state = .failed(error.localizedDescription)
        }
    }

    private var deviceConfiguration: SpeechInput.Configuration {
        SpeechInput.Configuration(model: .conversation, locale: TalkPreferences.language ?? .current, contextualStrings: contextualStrings)
    }

    /// The device's speech model, downloaded if it must be (the progress shows on the call).
    private func prepareDevice() async throws -> SpeechInput.Prepared {
        let prepared = try await SpeechInput.prepare(deviceConfiguration) { [weak self] fraction in
            Task { @MainActor in self?.downloadProgress = fraction < 1 ? fraction : nil }
        }
        downloadProgress = nil
        return prepared
    }

    private func attach(_ input: any TalkTranscriber, events: AsyncStream<SpeechInput.Event>) {
        self.input = input
        tasks.append(Task { [weak self] in
            for await event in events { self?.handle(event) }
        })
    }

    /// The gateway can't transcribe: the rest of the call hears on the device.
    private func fallBackToDevice(_ why: String) async {
        guard let lease, let gateway = input as? GatewayTranscriber else { return }
        let attempt = generation
        input = nil
        await gateway.cancel()
        onTranscriptionFellBack?(why)
        do {
            let prepared = try await prepareDevice()
            guard attempt == generation else { return }
            let input = SpeechInput(deviceConfiguration)
            let events = try await input.start(on: lease.graph, prepared: prepared)
            guard attempt == generation else {
                await input.cancel()
                return
            }
            attach(input, events: events)
        } catch {
            guard attempt == generation else { return }
            downloadProgress = nil
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        generation += 1
        if let cueChain { lease?.graph.removePlayer(cueChain) }
        cueChain = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        ears = TalkEars(pause: pause)
        if isMuted { setMuted(false) }
        let input = input
        let player = player
        let lease = lease
        self.input = nil
        self.player = nil
        self.lease = nil
        lease?.graph.setMutedSpeechListener(nil)
        await input?.cancel()
        await player?.stop()
        player?.tearDown()
        if let lease { await AudioCoordinator.shared.release(lease) }
        heardFinal = ""
        heardVolatile = ""
        inputLevel = 0
        isHearingSpeech = false
        isLoudRoom = false
        state = .idle
    }

    // MARK: Speaking

    /// Reads these sentences after what's being read.
    func speak(_ sentences: [SpokenSentence]) {
        player?.enqueue(sentences)
    }

    /// The reply is complete: finish once it's all been heard.
    func finishSpeaking() {
        player?.finishInput()
    }

    /// Stops the Bot at once (a tap, the end of the call). `fade` is barge-in's 80 ms fade.
    func stopSpeaking(fade: Bool = false) async {
        #if DEBUG
        await (input as? SpeechInput)?.stopEcho()
        #endif
        await player?.stop(fade: fade)
    }

    // MARK: Controls

    /// Mute is the microphone only: the Bot keeps talking, and unmuting carries on from there.
    func setMuted(_ muted: Bool) {
        try? AVAudioApplication.shared.setInputMuted(muted)
        mutedChanged(muted)
    }

    /// From the call's Mute, or the system's (an AirPods stem press, Control Center).
    private func mutedChanged(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        if muted {
            apply(ears.muted(at: ProcessInfo.processInfo.systemUptime))
            isHearingSpeech = false
            inputLevel = 0
        }
        onMuteChanged?(muted)
    }

    /// iPhone: the loudspeaker or the earpiece.
    func setSpeaker(_ on: Bool) async {
        guard let lease, on != prefersSpeaker else { return }
        prefersSpeaker = on
        try? await AudioCoordinator.shared.update(lease, options: AudioRoleOptions(prefersSpeaker: on))
    }

    /// Ends the current turn now (a tap on Send while listening).
    func endTurnNow() {
        Task { await endTurn() }
    }

    // MARK: Events

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func handle(_ event: SpeechInput.Event) {
        switch event {
        case .failed(let message):
            state = .failed(message)
            return
        case .unavailable(let why):
            Task { await fallBackToDevice(why) }
            return
        default:
            break
        }
        // Muted, nothing heard counts; a failure still does.
        guard !isMuted else { return }
        switch event {
        case .words(let final, let volatile, let runs):
            heardFinal = final
            heardVolatile = volatile
            apply(ears.heard(HeardWords(final: final, volatile: volatile, runs: runs), at: ProcessInfo.processInfo.systemUptime))
        case .frames(let start, let levels):
            // The Bot's level as the face shows it (0…1 over −50…0 dB), back in dBFS.
            let bot = isSpeaking ? (player?.level).flatMap { $0 > 0 ? $0 * 50 - 50 : nil } : nil
            let wasHearing = ears.isHearingPerson
            for (index, level) in levels.enumerated() {
                apply(ears.frame(level: level, at: start + Double(index) * 0.02, botLevel: bot))
            }
            isHearingSpeech = ears.isHearingPerson
            if ears.isLoud != isLoudRoom {
                isLoudRoom = ears.isLoud
                let ceiling = Int(ears.ceiling.rounded()), person = Int((ears.personLevel ?? 0).rounded())
                Self.logger.info("\(self.isLoudRoom ? "loud room" : "room quieter", privacy: .public): ceiling \(ceiling) dB, person \(person) dB")
            }
            if !wasHearing, ears.isHearingPerson, !ears.isBotSpeaking {
                Task { await input?.personStarted() }
            }
            (input as? SpeechInput)?.setGate(ears.gateThreshold)
        case .level(let level):
            inputLevel = level
        case .failed, .unavailable:
            break
        }
    }

    /// Does what the ears decided, and logs why.
    private func apply(_ decisions: [TalkEars.Decision]) {
        for decision in decisions {
            if decision.action == nil {
                Self.logger.debug("\(decision.description, privacy: .public)")
            } else {
                Self.logger.info("\(decision.description, privacy: .public)")
            }
            switch decision.action {
            case .duck: player?.duck(true)
            case .restore: player?.duck(false)
            case .bargeIn: bargeInNow()
            case .discardHeard: Task { await input?.dropTurn() }
            case .endTurn: Task { await endTurn() }
            case nil: break
            }
        }
    }

    private func handle(_ event: AudioLeaseEvent) {
        switch event {
        case .paused(.interruption):
            isInterrupted = true
            player?.pause()
            onInterruption?(true)
        case .resumed:
            isInterrupted = false
            player?.resume()
            onInterruption?(false)
        case .paused, .ended:
            break
        case .routeChanged(let route):
            self.route = route
        case .engineRestarted:
            if let cueChain, let graph = lease?.graph, !graph.contains(cueChain) { self.cueChain = nil }
            listenForMutedSpeech()
            player?.engineRestarted()
            onEngineRestarted?()
        case .inputMuteChanged(let muted):
            // AirPods stem, Control Center: the system's mute is the call's mute.
            mutedChanged(muted)
        }
    }

    /// "You're muted" when the person talks while muted. Set on the engine's input, so again after
    /// the engine is rebuilt.
    private func listenForMutedSpeech() {
        lease?.graph.setMutedSpeechListener { [weak self] started in
            guard started else { return }
            Task { @MainActor in self?.mutedSpeechAt = .now }
        }
    }

    private func speakingChanged(_ speaking: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if speaking {
            onFirstAudio?(now)
            apply(ears.botStarted(at: now, saying: player?.textAround ?? ""))
        } else {
            // Words heard over the Bot that didn't stop it ("mm-hm") are dropped; what someone
            // stopping it says is their turn.
            apply(ears.botStopped(at: now))
        }
    }

    private func bargeInNow() {
        #if DEBUG
        if let input = input as? SpeechInput { Task { await input.stopEcho() } }
        #endif
        Task {
            await player?.stop(fade: true)
            onBargeIn?()
        }
    }

    private func endTurn() async {
        guard !endingTurn else { return }
        guard let input else {
            ears.turnEnded(at: ProcessInfo.processInfo.systemUptime, sent: false)
            return
        }
        endingTurn = true
        defer { endingTurn = false }
        let endedAt = ears.endpointer.lastActivity ?? ProcessInfo.processInfo.systemUptime
        let words = await input.endTurn()
        ears.turnEnded(at: ProcessInfo.processInfo.systemUptime, sent: !words.isEmpty)
        heardFinal = ""
        heardVolatile = ""
        guard !words.isEmpty else { return }
        onTurn?(words, endedAt)
    }
}
