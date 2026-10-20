import Foundation
import HermesKit
import Observation

/// On-device speech to text for the composer (`docs/composer.md` §3, `docs/voice.md` §5): the
/// words land in the field as they're heard; nothing is sent until the person sends. It holds
/// the coordinator's dictation role while it listens (`docs/voice.md` §7), so it never
/// configures the audio session itself and can't run during a call.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        /// Asking for the microphone or fetching the speech model.
        case preparing
        case listening
        /// The microphone is off for Hermes.
        case denied
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Recent input levels, 0…1, newest last: the live meter (about 20 a second).
    private(set) var levels: [Float] = Array(repeating: 0, count: DictationController.meterBars)
    private(set) var startedAt: Date?
    /// Finished words so far.
    private(set) var finalized = ""
    /// Words still being heard; they may change.
    private(set) var volatile = ""
    /// The speech model downloading for this language, 0…1 (`docs/voice.md` §5).
    private(set) var downloadProgress: Double?
    /// Words to recognise: Bot names, projects, skills.
    var contextualStrings: [String] = []
    /// The language to dictate in; `nil` follows the device.
    var locale: Locale?

    var transcript: String {
        (finalized + volatile).trimmingCharacters(in: .whitespaces)
    }

    var isActive: Bool { state == .preparing || state == .listening }

    var failure: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    static let meterBars = 24

    @ObservationIgnored private var input: SpeechInput?
    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// Bumped by every stop: a start still waiting (permission, the model download) gives up
    /// when it wakes to a newer one, so the microphone never comes on after the person stopped.
    @ObservationIgnored private var generation = 0

    // MARK: Start, finish, cancel

    func start() async {
        guard !isActive else { return }
        generation += 1
        let attempt = generation
        func superseded() -> Bool { attempt != generation || Task.isCancelled }
        state = .preparing
        finalized = ""
        volatile = ""
        levels = Array(repeating: 0, count: Self.meterBars)
        guard await SpeechInput.requestMicrophone() else {
            if !superseded() { state = .denied }
            return
        }
        guard !superseded() else { return }
        let configuration = SpeechInput.Configuration(model: .dictation, locale: locale ?? .current, contextualStrings: contextualStrings)
        do {
            let prepared = try await SpeechInput.prepare(configuration) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, attempt == self.generation else { return }
                    self.downloadProgress = fraction < 1 ? fraction : nil
                }
            }
            downloadProgress = nil
            guard !superseded() else { return }
            let lease = try await AudioCoordinator.shared.acquire(.dictation, owner: "dictation")
            guard !superseded() else {
                await AudioCoordinator.shared.release(lease)
                return
            }
            let input = SpeechInput(configuration)
            let stream = try await input.start(on: lease.graph, prepared: prepared)
            guard !superseded() else {
                await input.cancel()
                await AudioCoordinator.shared.release(lease)
                return
            }
            self.lease = lease
            self.input = input
            startedAt = .now
            state = .listening
            events = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        for await event in stream { await self?.handle(event) }
                    }
                    group.addTask { [weak self] in
                        for await event in lease.events { await self?.handle(event) }
                    }
                }
            }
        } catch AudioCoordinatorError.busy {
            guard !superseded() else { return }
            await tearDown()
            state = .failed(String(localized: "Dictation is off during a call. Talking is the input."))
        } catch {
            guard !superseded() else { return }
            await tearDown()
            downloadProgress = nil
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and waits for the last words. Returns the whole transcript.
    @discardableResult
    func finish() async -> String {
        guard state == .listening, let input else {
            await tearDown()
            if case .failed = state {} else { state = .idle }
            return transcript
        }
        generation += 1
        let words = await input.stop()
        if !words.isEmpty { finalized = words; volatile = "" }
        let text = transcript
        await tearDown()
        state = .idle
        return text
    }

    func cancel() {
        generation += 1
        state = .idle
        finalized = ""
        volatile = ""
        downloadProgress = nil
        Task { await tearDown() }
    }

    /// Clears a failure so the row can offer Try Again.
    func dismissFailure() {
        if case .failed = state { state = .idle }
    }

    // MARK: Internals

    private func handle(_ event: SpeechInput.Event) {
        switch event {
        case .words(let final, let volatile):
            finalized = final
            self.volatile = volatile
        case .level(let level):
            guard state == .listening else { return }
            levels.removeFirst()
            levels.append(level)
        case .voice, .unavailable:
            break
        case .failed(let message):
            state = .failed(message)
            Task { await tearDown() }
        }
    }

    private func handle(_ event: AudioLeaseEvent) {
        switch event {
        case .ended, .paused:
            // A call or a recording took the microphone: keep the words, stop listening.
            guard isActive else { return }
            Task { _ = await finish() }
        default:
            break
        }
    }

    private func tearDown() async {
        events?.cancel()
        events = nil
        let input = input
        let lease = lease
        self.input = nil
        self.lease = nil
        startedAt = nil
        await input?.cancel()
        if let lease { await AudioCoordinator.shared.release(lease) }
    }
}
