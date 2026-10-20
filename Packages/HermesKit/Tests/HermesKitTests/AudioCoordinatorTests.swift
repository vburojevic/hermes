import Foundation
import Testing
@testable import HermesKit

/// A stand-in for `AVAudioSession`: records what the coordinator asks for and lets a test play
/// the system's part.
final class FakeAudioPlatform: AudioPlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var _applied: [AudioSessionProfile] = []
    private var _deactivations = 0
    private var continuation: AsyncStream<AudioPlatformEvent>.Continuation?
    var failNextApply = false
    var currentRoute = AudioRoute(output: .speaker, name: "iPhone")

    var applied: [AudioSessionProfile] { lock.withLock { _applied } }
    var deactivations: Int { lock.withLock { _deactivations } }

    func apply(_ profile: AudioSessionProfile, graph: AudioGraph) async throws {
        try lock.withLock {
            if failNextApply {
                failNextApply = false
                throw NSError(domain: "AVAudioSessionErrorDomain", code: 561_015_905)
            }
            _applied.append(profile)
        }
    }

    func deactivate(graph: AudioGraph) async {
        lock.withLock { _deactivations += 1 }
    }

    func route() async -> AudioRoute { currentRoute }

    func events() -> AsyncStream<AudioPlatformEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioPlatformEvent.self)
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func send(_ event: AudioPlatformEvent) {
        lock.withLock { continuation }?.yield(event)
    }
}

/// Collects a lease's events as they arrive.
final class LeaseEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AudioLeaseEvent] = []
    private var task: Task<Void, Never>?

    init(_ lease: AudioLease) {
        task = Task { [weak self] in
            for await event in lease.events { self?.append(event) }
        }
    }

    private func append(_ event: AudioLeaseEvent) {
        lock.withLock { _events.append(event) }
    }

    var events: [AudioLeaseEvent] { lock.withLock { _events } }

    /// Waits (briefly) until `count` events have arrived.
    func waitFor(_ count: Int) async -> [AudioLeaseEvent] {
        for _ in 0..<200 where events.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events
    }
}

@Suite("Audio coordinator")
struct AudioCoordinatorTests {
    @Test func aRoleConfiguresTheSessionOnceAndReleasingGivesItBack() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let lease = try await coordinator.acquire(.listen, owner: "listen")
        #expect(platform.applied == [.for(.listen)])
        #expect(await coordinator.activeRole == .listen)
        await coordinator.release(lease)
        #expect(await coordinator.activeRole == nil)
        #expect(platform.deactivations == 1)
        #expect(lease.isFinished)
    }

    @Test func recordingPausesListenAndListenCarriesOnAfter() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let listenEvents = LeaseEvents(listen)
        let recording = try await coordinator.acquire(.recording, owner: "recorder")
        #expect(await listenEvents.waitFor(1) == [.paused(.role(.recording))])
        #expect(await coordinator.activeRole == .recording)

        await coordinator.release(recording)
        #expect(await listenEvents.waitFor(2) == [.paused(.role(.recording)), .resumed])
        #expect(await coordinator.activeRole == .listen)
        // Listen, recording, Listen again: one configuration per role change, and the session
        // stayed up in between.
        #expect(platform.applied == [.for(.listen), .for(.recording), .for(.listen)])
        #expect(platform.deactivations == 0)
    }

    @Test func talkStopsAVoiceMessageAndDictation() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        let playback = try await coordinator.acquire(.playback, owner: "message")
        let playbackEvents = LeaseEvents(playback)
        _ = try await coordinator.acquire(.talk, owner: "talk")
        #expect(await playbackEvents.waitFor(1) == [.ended(.role(.talk))])
        #expect(playback.isFinished)

        let other = AudioCoordinator(platform: FakeAudioPlatform())
        let dictation = try await other.acquire(.dictation, owner: "composer")
        _ = try await other.acquire(.talk, owner: "talk")
        #expect(dictation.isFinished)
    }

    @Test func dictationIsRefusedDuringTalk() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        _ = try await coordinator.acquire(.talk, owner: "talk")
        await #expect(throws: AudioCoordinatorError.busy(.talk)) {
            _ = try await coordinator.acquire(.dictation, owner: "composer")
        }
        await #expect(throws: AudioCoordinatorError.busy(.talk)) {
            _ = try await coordinator.acquire(.listen, owner: "listen")
        }
        #expect(await coordinator.activeRole == .talk)
        let refusals = await coordinator.log.filter { if case .refused = $0.change { true } else { false } }
        #expect(refusals.count == 2)
    }

    @Test func oneOutputReplacesAnother() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let message = try await coordinator.acquire(.playback, owner: "message")
        #expect(listen.isFinished)
        let again = try await coordinator.acquire(.listen, owner: "listen:2")
        #expect(message.isFinished)
        #expect(await coordinator.activeRole == .listen)
        #expect(!again.isFinished)
    }

    @Test func aFailedSessionHandsTheAudioBack() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let events = LeaseEvents(listen)
        platform.failNextApply = true
        await #expect(throws: AudioCoordinatorError.sessionFailed("AVAudioSessionErrorDomain 561015905")) {
            _ = try await coordinator.acquire(.recording, owner: "recorder")
        }
        #expect(await events.waitFor(2) == [.paused(.role(.recording)), .resumed])
        #expect(await coordinator.activeRole == .listen)
    }

    @Test func aPhoneCallPausesTalkAndTalkCarriesOnAfter() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let talk = try await coordinator.acquire(.talk, owner: "talk")
        let events = LeaseEvents(talk)
        platform.send(.interruptionBegan)
        #expect(await events.waitFor(1) == [.paused(.interruption)])
        // The system doesn't suggest resuming after a call; a call carries on anyway.
        platform.send(.interruptionEnded(shouldResume: false))
        #expect(await events.waitFor(2) == [.paused(.interruption), .resumed])
        // The session was taken back before anything played.
        #expect(platform.applied == [.for(.talk), .for(.talk)])
    }

    @Test func listenWaitsAfterAnInterruptionUnlessTheSystemSaysResume() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let events = LeaseEvents(listen)
        platform.send(.interruptionBegan)
        platform.send(.interruptionEnded(shouldResume: false))
        _ = await events.waitFor(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.events == [.paused(.interruption)])
        platform.send(.interruptionBegan)
        platform.send(.interruptionEnded(shouldResume: true))
        #expect(await events.waitFor(3) == [.paused(.interruption), .paused(.interruption), .resumed])
    }

    @Test func headphonesComingOutPauseListen() async throws {
        let platform = FakeAudioPlatform()
        platform.currentRoute = AudioRoute(output: .bluetooth, name: "AirPods")
        let coordinator = AudioCoordinator(platform: platform)
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let events = LeaseEvents(listen)
        _ = await coordinator.currentRoute
        let speaker = AudioRoute(output: .speaker, name: "iPhone")
        platform.send(.routeChanged(AudioRouteChange(reason: .oldDeviceUnavailable, route: speaker)))
        #expect(await events.waitFor(2) == [.paused(.routeLost), .routeChanged(speaker)])
    }

    @Test func airPodsConnectingMidCallMoveTheCall() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let talk = try await coordinator.acquire(.talk, owner: "talk")
        let events = LeaseEvents(talk)
        let airPods = AudioRoute(output: .bluetooth, name: "AirPods Pro")
        platform.send(.routeChanged(AudioRouteChange(reason: .newDeviceAvailable, route: airPods)))
        platform.send(.engineConfigurationChanged)
        #expect(await events.waitFor(2) == [.routeChanged(airPods), .engineRestarted])
        #expect(!talk.isFinished)
    }

    @Test func aMediaServicesResetRebuildsAndKeepsTheRole() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let talk = try await coordinator.acquire(.talk, owner: "talk")
        let events = LeaseEvents(talk)
        platform.send(.mediaServicesReset)
        #expect(await events.waitFor(1) == [.engineRestarted])
        #expect(platform.applied == [.for(.talk), .for(.talk)])
    }

    @Test func theSpeakerChoiceReconfiguresOnlyWhenItChanges() async throws {
        let platform = FakeAudioPlatform()
        let coordinator = AudioCoordinator(platform: platform)
        let talk = try await coordinator.acquire(.talk, owner: "talk")
        try await coordinator.update(talk, options: AudioRoleOptions(prefersSpeaker: true))
        try await coordinator.update(talk, options: AudioRoleOptions(prefersSpeaker: false))
        #expect(platform.applied.count == 2)
        #expect(platform.applied.last?.options.contains(.defaultToSpeaker) == false)
    }

    @Test func everyRoleChangeIsLogged() async throws {
        let coordinator = AudioCoordinator(platform: FakeAudioPlatform())
        let listen = try await coordinator.acquire(.listen, owner: "listen")
        let talk = try await coordinator.acquire(.talk, owner: "talk")
        await coordinator.release(talk)
        await coordinator.release(listen)
        let lines = await coordinator.log.filter { if case .session = $0.change { false } else { true } }.map(\.description)
        #expect(lines == [
            "listen acquired by listen",
            "listen (listen) stopped for talk",
            "talk acquired by talk",
            "talk released by talk",
            "session released",
        ])
    }

    @Test func profilesFollowTheSpec() {
        // docs/voice.md §4.2: voice chat, Bluetooth, speaker, ducking, voice processing.
        let talk = AudioSessionProfile.for(.talk)
        #expect(talk.category == .playAndRecord && talk.mode == .voiceChat && talk.voiceProcessing)
        #expect(talk.options == [.allowBluetoothHFP, .defaultToSpeaker, .duckOthers])
        // Studio-quality AirPods recording for voice messages, never for Talk.
        #expect(AudioSessionProfile.for(.recording, options: .init(highQualityBluetoothRecording: true)).options.contains(.bluetoothHighQualityRecording))
        #expect(!AudioSessionProfile.for(.talk, options: .init(highQualityBluetoothRecording: true)).options.contains(.bluetoothHighQualityRecording))
        // Listen: spoken audio that pauses podcasts and ducks music.
        let listen = AudioSessionProfile.for(.listen)
        #expect(listen.category == .playback && listen.mode == .spokenAudio)
        #expect(listen.options.isEmpty)
        // Raise to Listen: through the receiver.
        #expect(AudioSessionProfile.for(.playback, options: .init(receiver: true)).category == .playAndRecord)
        // Hey Hermes: the microphone, mixed with what plays, no call mode.
        let wake = AudioSessionProfile.for(.wake)
        #expect(wake.category == .playAndRecord && !wake.voiceProcessing)
        #expect(wake.options.contains(.mixWithOthers) && !wake.options.contains(.allowBluetoothHFP))
        #expect(AudioRole.wake < .playback && AudioRole.wake.whenPreempted(by: .listen) == .pause)
    }
}
