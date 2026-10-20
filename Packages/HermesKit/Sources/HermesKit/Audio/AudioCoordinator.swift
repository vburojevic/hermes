import Foundation
import os

/// The one owner of the app's audio (`docs/voice.md` §7): the audio session and the engine.
/// Talk, recording, dictation, Listen and playback ask it for a role and get a lease; nothing else
/// configures the session. A higher role pauses or stops a lower one, and the lower one carries
/// on when the higher one is done. Interruptions, route changes, engine configuration changes
/// and media-services resets are handled here and passed on to whoever holds the audio, and every
/// role change is logged:
/// `log show --last 1h --predicate 'subsystem == "co.caffeinatedcode.hermes" && category == "audio"'`
public actor AudioCoordinator {
    public static let shared = AudioCoordinator(platform: LiveAudioPlatform())

    /// The engine every role plays and records through.
    public nonisolated let graph: AudioGraph

    private let platform: any AudioPlatform
    private var active: AudioLease?
    private var activeOptions = AudioRoleOptions()
    /// Leases paused by a higher role, most recent last.
    private var suspended: [(lease: AudioLease, options: AudioRoleOptions)] = []
    private var applied: AudioSessionProfile?
    private var interrupted = false
    private var route = AudioRoute.unknown
    private var listening: Task<Void, Never>?
    private(set) var entries: [AudioLogEntry] = []

    // One role change at a time: applying a profile awaits the system, and a second request
    // arriving meanwhile must see the first one's outcome.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated static let logger = Logger(subsystem: "co.caffeinatedcode.hermes", category: "audio")

    public init(platform: any AudioPlatform, graph: AudioGraph? = nil) {
        self.platform = platform
        self.graph = graph ?? AudioGraph()
    }

    // MARK: Roles

    /// Takes the audio for `role`. The same role, or one output replacing another (Listen and a
    /// voice message), ends the one before; a lower role holding it is paused or stopped
    /// (`AudioRole.whenPreempted(by:)`). A lower role than a microphone role is refused.
    public func acquire(_ role: AudioRole, owner: String, options: AudioRoleOptions = .init()) async throws -> AudioLease {
        startListening()
        await lock()
        defer { unlock() }

        if let current = active {
            if role == current.role || (!role.usesMicrophone && !current.role.usesMicrophone) {
                current.end(.replaced)
                record(.replaced(current.role), owner: current.owner)
            } else if role > current.role {
                switch current.role.whenPreempted(by: role) {
                case .pause:
                    suspended.append((current, activeOptions))
                    current.send(.paused(.role(role)))
                    record(.preempted(current.role, by: role, paused: true), owner: current.owner)
                case .stop:
                    current.end(.role(role))
                    record(.preempted(current.role, by: role, paused: false), owner: current.owner)
                }
            } else {
                record(.refused(role, busy: current.role), owner: owner)
                throw AudioCoordinatorError.busy(current.role)
            }
            active = nil
        }

        let lease = AudioLease(role: role, owner: owner, graph: graph)
        do {
            try await apply(.for(role, options: options))
        } catch {
            record(.failed(role, error: Self.describe(error)), owner: owner)
            lease.end(.failed)
            await resumeSuspended()
            throw AudioCoordinatorError.sessionFailed(Self.describe(error))
        }
        active = lease
        activeOptions = options
        record(.acquired(role), owner: owner)
        if interrupted { lease.send(.paused(.interruption)) }
        return lease
    }

    /// Gives the audio back. A role this one paused carries on; with nothing left the session is
    /// released so other apps' audio comes back up.
    public func release(_ lease: AudioLease) async {
        await lock()
        defer { unlock() }
        if active === lease {
            active = nil
            lease.finish()
            record(.released(lease.role), owner: lease.owner)
            await resumeSuspended()
        } else if let index = suspended.firstIndex(where: { $0.lease === lease }) {
            suspended.remove(at: index)
            lease.finish()
            record(.released(lease.role), owner: lease.owner)
        }
    }

    /// Changes how the role holding the audio wants it: the loudspeaker, the receiver, AirPods
    /// recording quality.
    public func update(_ lease: AudioLease, options: AudioRoleOptions) async throws {
        await lock()
        defer { unlock() }
        guard active === lease, options != activeOptions else { return }
        try await apply(.for(lease.role, options: options))
        activeOptions = options
        record(.updated(lease.role), owner: lease.owner)
    }

    /// The role holding the audio now.
    public var activeRole: AudioRole? { active?.role }

    /// The current output: whether it's private (headphones, the receiver) decides whether replies
    /// play by themselves (`docs/voice.md` §2).
    public var currentRoute: AudioRoute {
        get async {
            startListening()
            route = await platform.route()
            return route
        }
    }

    /// Recent role changes, oldest first: what the debug overlay shows and the tests read.
    public var log: [AudioLogEntry] { entries }

    // MARK: System events

    private func startListening() {
        guard listening == nil else { return }
        let events = platform.events()
        listening = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    func handle(_ event: AudioPlatformEvent) async {
        await lock()
        defer { unlock() }
        switch event {
        case .interruptionBegan:
            interrupted = true
            record(.interruption(began: true), owner: active?.owner ?? "-")
            active?.send(.paused(.interruption))
        case .interruptionEnded(let shouldResume):
            interrupted = false
            record(.interruption(began: false), owner: active?.owner ?? "-")
            guard let active else { return }
            // The session was taken away: take it back before anyone plays.
            applied = nil
            do {
                try await apply(.for(active.role, options: activeOptions))
            } catch {
                record(.failed(active.role, error: Self.describe(error)), owner: active.owner)
                return
            }
            // A call carries on after a phone call; Listen and playback only when the system says so.
            if shouldResume || active.role == .talk {
                active.send(.resumed)
            }
        case .routeChanged(let change):
            let previous = route
            route = change.route
            record(.route(change.reason, change.route), owner: active?.owner ?? "-")
            guard let active else { return }
            // Apple's rule: headphones coming out pause what plays rather than move it to the speaker.
            if change.reason == .oldDeviceUnavailable, previous.isPrivate, !change.route.isPrivate,
               active.role == .listen || active.role == .playback {
                active.send(.paused(.routeLost))
            }
            active.send(.routeChanged(change.route))
        case .engineConfigurationChanged:
            graph.restartAfterConfigurationChange()
            record(.engineRestarted, owner: active?.owner ?? "-")
            active?.send(.engineRestarted)
        case .mediaServicesReset:
            record(.mediaServicesReset, owner: active?.owner ?? "-")
            applied = nil
            graph.rebuild()
            guard let active else { return }
            do {
                try await apply(.for(active.role, options: activeOptions))
                active.send(.engineRestarted)
            } catch {
                record(.failed(active.role, error: Self.describe(error)), owner: active.owner)
                active.end(.failed)
                self.active = nil
            }
        case .inputMuteChanged(let muted):
            active?.send(.inputMuteChanged(muted))
        }
    }

    // MARK: Internals

    private func apply(_ profile: AudioSessionProfile) async throws {
        guard profile != applied else { return }
        try await platform.apply(profile, graph: graph)
        applied = profile
        record(.session(profile), owner: active?.owner ?? "-")
    }

    private func resumeSuspended() async {
        while let (lease, options) = suspended.popLast() {
            guard !lease.isFinished else { continue }
            do {
                try await apply(.for(lease.role, options: options))
            } catch {
                record(.failed(lease.role, error: Self.describe(error)), owner: lease.owner)
                lease.end(.failed)
                continue
            }
            active = lease
            activeOptions = options
            record(.resumed(lease.role), owner: lease.owner)
            if !interrupted { lease.send(.resumed) }
            return
        }
        guard applied != nil else { return }
        applied = nil
        await platform.deactivate(graph: graph)
        record(.deactivated, owner: "-")
    }

    private func record(_ change: AudioLogEntry.Change, owner: String) {
        let entry = AudioLogEntry(date: .now, change: change, owner: owner)
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        Self.logger.info("\(entry.description, privacy: .public)")
    }

    private func lock() async {
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
    }

    private func unlock() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Errors as domain and code: a description can carry a path.
    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

public enum AudioCoordinatorError: Error, Equatable, Sendable {
    /// A role with the microphone holds the audio.
    case busy(AudioRole)
    /// The system refused the audio session ("domain code").
    case sessionFailed(String)
}

/// A role's hold on the audio. Its events say when to pause, carry on or stop; it ends when the
/// holder releases it or a higher role stops it.
public final class AudioLease: Sendable, Identifiable {
    public let id = UUID()
    public let role: AudioRole
    /// Who holds it, for the log ("talk", "listen:<turn>").
    public let owner: String
    public let events: AsyncStream<AudioLeaseEvent>
    /// The engine to play and record through.
    public let graph: AudioGraph
    private let continuation: AsyncStream<AudioLeaseEvent>.Continuation
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(role: AudioRole, owner: String, graph: AudioGraph) {
        self.role = role
        self.owner = owner
        self.graph = graph
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    public var isFinished: Bool { finished.withLock { $0 } }

    func send(_ event: AudioLeaseEvent) {
        guard !isFinished else { return }
        continuation.yield(event)
    }

    func end(_ reason: AudioEndReason) {
        send(.ended(reason))
        finish()
    }

    func finish() {
        finished.withLock { $0 = true }
        continuation.finish()
    }
}

public enum AudioLeaseEvent: Sendable, Equatable {
    /// Stop making sound (and listening) for now.
    case paused(AudioPauseReason)
    /// Carry on.
    case resumed
    /// The lease is over; release nothing, it's already gone.
    case ended(AudioEndReason)
    /// The output or input moved (AirPods connected, headphones out).
    case routeChanged(AudioRoute)
    /// The engine restarted or was rebuilt: schedule again, reinstall what was lost.
    case engineRestarted
    /// The microphone was muted or unmuted from outside the app (AirPods stem, Control Center).
    case inputMuteChanged(Bool)
}

public enum AudioPauseReason: Sendable, Equatable {
    case role(AudioRole)
    case interruption
    /// Headphones came out.
    case routeLost
}

public enum AudioEndReason: Sendable, Equatable {
    case role(AudioRole)
    case replaced
    case failed
}

/// One line of the coordinator's log.
public struct AudioLogEntry: Sendable, Equatable, CustomStringConvertible {
    public enum Change: Sendable, Equatable {
        case acquired(AudioRole)
        case released(AudioRole)
        case resumed(AudioRole)
        case updated(AudioRole)
        case preempted(AudioRole, by: AudioRole, paused: Bool)
        case replaced(AudioRole)
        case refused(AudioRole, busy: AudioRole)
        case failed(AudioRole, error: String)
        case session(AudioSessionProfile)
        case deactivated
        case interruption(began: Bool)
        case route(AudioRouteChangeReason, AudioRoute)
        case engineRestarted
        case mediaServicesReset
    }

    public var date: Date
    public var change: Change
    public var owner: String

    public var description: String {
        switch change {
        case .acquired(let role): "\(role) acquired by \(owner)"
        case .released(let role): "\(role) released by \(owner)"
        case .resumed(let role): "\(role) resumed for \(owner)"
        case .updated(let role): "\(role) options changed by \(owner)"
        case .preempted(let role, let higher, let paused): "\(role) (\(owner)) \(paused ? "paused" : "stopped") for \(higher)"
        case .replaced(let role): "\(role) (\(owner)) replaced"
        case .refused(let role, let busy): "\(role) refused for \(owner): \(busy) holds the audio"
        case .failed(let role, let error): "\(role) failed for \(owner): \(error)"
        case .session(let profile): "session \(profile)"
        case .deactivated: "session released"
        case .interruption(let began): began ? "interrupted" : "interruption ended"
        case .route(let reason, let route): "route \(reason): \(route)"
        case .engineRestarted: "engine restarted"
        case .mediaServicesReset: "media services reset"
        }
    }
}
