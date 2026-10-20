@preconcurrency import AVFoundation
import Foundation
import HermesKit
import Observation
import os

/// Plays a voice message or a Bot's audio file (`docs/voice.md` §2): one at a time, through the
/// coordinator's playback role (`docs/voice.md` §7) and the one engine, at 1–2× with the pitch
/// kept (`AVAudioUnitTimePitch`). Starting another clip stops this one.
@MainActor
@Observable
final class ClipPlayer {
    /// The chat's player: every bubble and strip shares it, so only one plays.
    static let shared = ClipPlayer()

    /// The clip loaded: playing, or paused part-way.
    private(set) var clipID: String?
    private(set) var isPlaying = false
    /// Seconds into the clip.
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// What went wrong playing the last clip, in a sentence.
    private(set) var failure: (id: String, message: String)?
    /// 1, 1.5 or 2.
    var rate: Double = TalkPreferences.listenSpeed {
        didSet {
            chain?.rate = Float(rate)
            UserDefaults.standard.set(rate, forKey: TalkPreferences.Key.listenSpeed)
        }
    }

    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var chain: AudioPlayerChain?
    @ObservationIgnored private var file: AVAudioFile?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var leaseEvents: Task<Void, Never>?
    /// Bumped by every schedule: a completion from an earlier one (a stop, a seek) is ignored.
    @ObservationIgnored private var schedule = 0
    /// The player still holds the clip from `position` (paused, not seeked since).
    @ObservationIgnored private var isQueued = false

    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    func isPlaying(_ id: String) -> Bool { clipID == id && isPlaying }

    /// Where `id` is, 0…1, if it's the clip loaded.
    func progress(of id: String) -> Double? {
        guard clipID == id, duration > 0 else { return nil }
        return min(1, position / duration)
    }

    /// Plays or pauses `id`.
    func toggle(_ id: String, url: URL) async {
        if clipID == id {
            if isPlaying { pause() } else { await resume() }
        } else {
            await play(id, url: url, from: 0)
        }
    }

    func play(_ id: String, url: URL, from start: TimeInterval) async {
        stop()
        failure = nil
        do {
            let file = try AVAudioFile(forReading: url)
            let lease = try await AudioCoordinator.shared.acquire(.playback, owner: "clip")
            let chain = try lease.graph.makePlayer(format: file.processingFormat)
            chain.rate = Float(rate)
            self.lease = lease
            self.chain = chain
            self.file = file
            clipID = id
            duration = Double(file.length) / file.processingFormat.sampleRate
            position = min(start, duration)
            follow(lease)
            try begin(at: position)
        } catch {
            Self.logger.error("clip didn't play: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            failure = (id, String(localized: "Can't play this audio."))
            stop()
        }
    }

    func pause() {
        guard isPlaying else { return }
        position = chain?.currentTime ?? position
        chain?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    func resume() async {
        guard let chain, !isPlaying else { return }
        do {
            if isQueued {
                try chain.play()
                isPlaying = true
                tick()
            } else {
                try begin(at: position)
            }
        } catch {
            stop()
        }
    }

    /// Jumps to `time` seconds, playing on if it was playing.
    func seek(_ id: String, to time: TimeInterval) {
        guard clipID == id, chain != nil else { return }
        let target = min(max(0, time), duration)
        let wasPlaying = isPlaying
        position = target
        if wasPlaying {
            try? begin(at: target)
        } else {
            // Paused: the next play starts from here.
            schedule += 1
            isQueued = false
            chain?.stop()
        }
    }

    /// Stops `id`, if it's the clip loaded.
    func stop(ifPlaying id: String) {
        if clipID == id { stop() }
    }

    /// Stops and lets the audio go.
    func stop() {
        schedule += 1
        isQueued = false
        ticker?.cancel()
        leaseEvents?.cancel()
        chain?.stop()
        if let chain, let lease { lease.graph.removePlayer(chain) }
        let lease = lease
        chain = nil
        file = nil
        self.lease = nil
        isPlaying = false
        clipID = nil
        position = 0
        duration = 0
        if let lease { Task { await AudioCoordinator.shared.release(lease) } }
    }

    // MARK: Internals

    private func begin(at start: TimeInterval) throws {
        guard let chain, let file else { return }
        schedule += 1
        let token = schedule
        chain.stop()
        chain.schedule(file: file, from: start) { [weak self] in
            Task { @MainActor in self?.finished(token) }
        }
        isQueued = true
        try chain.play()
        isPlaying = true
        tick()
    }

    private func finished(_ token: Int) {
        guard token == schedule else { return }
        // Played to the end: back to the start, the audio given back.
        stop()
    }

    /// The position, while playing: 20 times a second is smooth enough for a bar.
    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isPlaying, let chain = self.chain else { return }
                self.position = min(self.duration, chain.currentTime)
            }
        }
    }

    private func follow(_ lease: AudioLease) {
        leaseEvents = Task { [weak self] in
            for await event in lease.events {
                guard let self else { return }
                switch event {
                case .paused:
                    // A call, Siri, or the headphones coming out.
                    self.pause()
                case .ended:
                    self.stop()
                case .engineRestarted:
                    // The engine came back without our player's queue: start again from here.
                    if self.isPlaying { try? self.begin(at: self.position) }
                default:
                    break
                }
            }
        }
    }
}

/// Fetches a message's audio from the gateway once and keeps it (`GET /api/files/stream`).
@MainActor
enum ClipFetcher {
    private static var running: [String: Task<URL, any Error>] = [:]

    static func url(for path: String, backend: BackendClient?) async throws -> URL {
        if let local = VoiceMessageStore.existing(path) { return local }
        guard let backend, path.hasPrefix("/") else { throw ClipError.unavailable }
        if let task = running[path] { return try await task.value }
        let task = Task<URL, any Error> {
            let data = try await backend.downloadFile(path: path)
            let url = VoiceMessageStore.localURL(for: path)
            try data.write(to: url, options: .atomic)
            return url
        }
        running[path] = task
        defer { running[path] = nil }
        return try await task.value
    }

    enum ClipError: LocalizedError {
        case unavailable

        var errorDescription: String? { String(localized: "This audio isn't on this device, and the gateway can't send it.") }
    }
}

/// A clip's bars and length, read once.
@MainActor
enum ClipShapes {
    private static var cache: [String: (levels: [Float], duration: TimeInterval)] = [:]

    static func cached(_ id: String) -> (levels: [Float], duration: TimeInterval)? { cache[id] }

    static func shape(of url: URL, id: String) async -> (levels: [Float], duration: TimeInterval)? {
        if let known = cache[id] { return known }
        guard let shape = await read(url) else { return nil }
        cache[id] = shape
        return shape
    }

    @concurrent private static func read(_ url: URL) async -> (levels: [Float], duration: TimeInterval)? {
        try? Waveform.levels(of: url)
    }
}
