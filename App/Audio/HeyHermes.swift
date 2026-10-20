@preconcurrency import AVFoundation
import Foundation
import HermesKit
import Observation
import os
#if os(iOS)
import UIKit
#endif

/// Hey Hermes (`docs/voice.md` §4.6). While it's on (Settings → Voice & Audio, off by default), the
/// microphone streams to the gateway's wake word engine (`wake.start {surface: "gui",
/// client_capture: true}`, then `wake.feed`, 80 ms frames four at a time), and `wake.detected`
/// opens Talk with the Bot it names.
///
/// - Where: on the Mac whenever Hermes runs; on iPhone and iPad while charging with Hermes in
///   front (the app's connection to the gateway closes in the background).
/// - The microphone is the coordinator's lowest role (`.wake`): a call, a recording, dictation or
///   a reply read aloud pause it, and it listens again after.
/// - It never turns the gateway's wake word on by itself: `wake.start` goes without `persist`, and
///   a gateway with it off says so in the setup, whose Turn On is the person's.
@MainActor
@Observable
final class HeyHermes {
    static let shared = HeyHermes()

    enum State: Equatable {
        case off
        /// Waiting for what it needs: Bot Mode, charging, the app in front, the microphone.
        case waiting
        case starting
        /// The app streams the microphone to the gateway.
        case listening
        /// The gateway's own microphone listens.
        case listeningOnGateway
        /// A call, a recording or a reply has the microphone.
        case paused
        /// The gateway said no; the setup says why.
        case refused(WakeStart.Refusal)
        case failed(String)
    }

    private(set) var state: State = .off
    static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    @ObservationIgnored private weak var workspace: BotWorkspace?
    @ObservationIgnored private weak var startedOn: BotRoster?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lease: AudioLease?
    @ObservationIgnored private var consumer: UUID?
    @ObservationIgnored private var audio: AsyncStream<Data>.Continuation?
    /// The microphone's framing and feeding: stopped on a pause.
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// The lease's events: kept through a pause, so it hears `resumed`.
    @ObservationIgnored private var leaseEvents: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var afterDetection: Task<Void, Never>?
    @ObservationIgnored private var frameLength = 1_280
    @ObservationIgnored private var refusedFeeds = 0
    #if os(iOS)
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    #endif

    private init() {}

    // MARK: When it listens

    /// Why this device isn't listening now, when that's the device's doing.
    var pauseReason: String? {
        #if os(iOS)
        guard isCharging, UIApplication.shared.applicationState == .active else {
            return String(localized: "Listens while this \(VoiceSetup.device) is charging and Hermes is open")
        }
        #endif
        return nil
    }

    #if os(iOS)
    private var isCharging: Bool {
        #if DEBUG
        // Simulators don't charge: `-HERMES_CHARGING YES` stands in.
        if UserDefaults.standard.bool(forKey: "HERMES_CHARGING") { return true }
        #endif
        return [.charging, .full].contains(UIDevice.current.batteryState)
    }
    #endif

    /// Starts or stops to match the setting, the gateway and the device. Called when any of them
    /// changes (`RootView`, Settings, the battery, the app coming to the front). A refusal is asked
    /// again only with `retry` (a reconnect, Check Again, the setting turned on).
    func update(workspace: BotWorkspace?, retry: Bool = false) {
        watchDevice()
        if let workspace { self.workspace = workspace }
        let roster = self.workspace?.roster
        let wanted = TalkPreferences.heyHermes && roster?.isConnected == true && pauseReason == nil
        // Another gateway now, or it shouldn't listen: let go first, then listen on the new one.
        if let startedOn, startedOn !== roster || !wanted {
            Task {
                await stop()
                if wanted, let roster { await start(on: roster, persist: false) }
            }
            return
        }
        guard wanted, let roster else {
            if !isStarted { state = TalkPreferences.heyHermes ? .waiting : .off }
            return
        }
        switch state {
        case .off, .waiting, .failed:
            Task { await start(on: roster, persist: false) }
        case .refused where retry:
            Task { await start(on: roster, persist: false) }
        case .starting, .listening, .listeningOnGateway, .paused, .refused:
            break
        }
    }

    /// The setup's Turn On: `wake.start` with `persist`, which turns on `wake_word.enabled` on the
    /// gateway. Only on the person's tap.
    func turnOnOnGateway(workspace: BotWorkspace) async {
        self.workspace = workspace
        guard let roster = workspace.roster, roster.isConnected else { return }
        await stop()
        await start(on: roster, persist: true)
    }

    private var isStarted: Bool { startedOn != nil }

    // MARK: Starting and stopping

    private func start(on roster: BotRoster, persist: Bool) async {
        generation += 1
        let attempt = generation
        state = .starting
        var params: [String: JSONValue] = ["surface": .string("gui"), "client_capture": .bool(true)]
        if persist { params["persist"] = .bool(true) }
        do {
            // The first start can install the engine on the gateway: give it time.
            let start = WakeStart(json: try await roster.request("wake.start", params, timeout: .seconds(180)))
            guard attempt == generation else { return }
            if let refusal = start.refusal {
                state = .refused(refusal)
                return
            }
            startedOn = roster
            frameLength = start.frameLength
            refusedFeeds = 0
            if start.listensLocally {
                state = .listeningOnGateway
            } else {
                await openMicrophone(on: roster, attempt: attempt)
            }
        } catch let error as GatewayRPCError where error.code == -32601 {
            state = .failed(String(localized: "This gateway's Hermes has no wake word. Update Hermes Agent."))
        } catch {
            guard attempt == generation else { return }
            Self.logger.error("wake.start failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            state = .failed(String(localized: "The gateway didn't start listening."))
        }
        if let workspace = roster.workspace ?? workspace { await VoiceSetup.of(workspace).check(profile: nil) }
    }

    func stop() async {
        generation += 1
        let roster = startedOn
        startedOn = nil
        closeMicrophone()
        leaseEvents?.cancel()
        leaseEvents = nil
        if let lease { await AudioCoordinator.shared.release(lease) }
        lease = nil
        retry?.cancel()
        afterDetection?.cancel()
        if let roster, roster.isConnected {
            _ = try? await roster.request("wake.stop", [:], timeout: .seconds(10))
        }
        state = TalkPreferences.heyHermes ? .waiting : .off
    }

    // MARK: The microphone

    private func openMicrophone(on roster: BotRoster, attempt: Int) async {
        guard await SpeechInput.requestMicrophone() else {
            state = .failed(String(localized: "The microphone is off for Hermes."))
            return
        }
        do {
            let lease = try await AudioCoordinator.shared.acquire(.wake, owner: "wake")
            guard attempt == generation else {
                await AudioCoordinator.shared.release(lease)
                return
            }
            self.lease = lease
            leaseEvents = Task { [weak self] in
                for await event in lease.events { self?.handle(event) }
            }
            attach(to: lease.graph, roster: roster)
            state = .listening
        } catch AudioCoordinatorError.busy {
            // A call or a recording has it: listen when it's done.
            state = .paused
            retry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, attempt == self.generation else { return }
                await self.openMicrophone(on: roster, attempt: attempt)
            }
        } catch {
            Self.logger.error("wake microphone failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            state = .failed(error.localizedDescription)
        }
    }

    private func attach(to graph: AudioGraph, roster: BotRoster) {
        guard consumer == nil else { return }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let converter = PCM16Converter()
        do {
            consumer = try graph.addInputConsumer { buffer, _ in
                if let pcm = converter.convert(buffer) { continuation.yield(pcm) }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        audio = continuation
        let frameLength = frameLength
        // Framed off the main actor: it hears about each batch (about three a second), not each buffer.
        tasks.append(Task.detached(priority: .utility) { [weak self] in
            var frames = WakeFrames(frameLength: frameLength)
            for await pcm in stream {
                for batch in frames.append(pcm) {
                    await self?.feed(batch, to: roster)
                }
            }
        })
    }

    private func closeMicrophone() {
        // The graph drops its input only with no consumers left, so Listen can take the speaker.
        if let consumer { lease?.graph.removeInputConsumer(consumer) }
        consumer = nil
        audio?.finish()
        audio = nil
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func feed(_ batch: Data, to roster: BotRoster) async {
        guard state == .listening else { return }
        do {
            let result = try await roster.request("wake.feed", ["pcm": .string(batch.base64EncodedString()), "sample_rate": .number(16_000)], timeout: .seconds(10))
            if result["fed"]?.boolValue == false, result["reason"]?.stringValue == "not_owner" {
                refusedFeeds += 1
                // Someone else's detector now: start over, which the setup explains.
                if refusedFeeds >= 3 {
                    await stop()
                    update(workspace: workspace)
                }
            } else {
                refusedFeeds = 0
            }
        } catch {
            Self.logger.error("wake.feed failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    private func handle(_ event: AudioLeaseEvent) {
        switch event {
        case .paused:
            closeMicrophone()
            if state == .listening { state = .paused }
        case .resumed:
            guard let lease, let roster = startedOn else { return }
            attach(to: lease.graph, roster: roster)
            state = .listening
        case .ended:
            closeMicrophone()
            lease = nil
            Task { await stop() }
        case .routeChanged, .engineRestarted, .inputMuteChanged:
            break
        }
    }

    // MARK: Detection

    /// `wake.detected`: Talk opens with the Bot it names; the gateway's detector waits until the
    /// call is over (`wake.resume`).
    func detected(_ detection: WakeDetection) {
        guard state == .listening || state == .listeningOnGateway else { return }
        Self.logger.info("wake word heard: \(detection.phrase, privacy: .public)")
        TalkCenter.shared.pendingStart = .init(botName: detection.profile)
        afterDetection?.cancel()
        afterDetection = Task { [weak self] in
            // The call starts within moments; listen again once it's over (or if it never began).
            var started = false
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if TalkCenter.shared.isActive { started = true; break }
            }
            if started {
                for await active in Observations({ TalkCenter.shared.isActive }) where !active { break }
            }
            guard !Task.isCancelled, let self, let roster = self.startedOn else { return }
            _ = try? await roster.request("wake.resume", [:], timeout: .seconds(10))
        }
    }

    // MARK: The device

    @ObservationIgnored private var watching = false

    private func watchDevice() {
        guard !watching else { return }
        watching = true
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        let names = [UIDevice.batteryStateDidChangeNotification, UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { HeyHermes.shared.update(workspace: nil) }
            }
        }
        #endif
    }
}
