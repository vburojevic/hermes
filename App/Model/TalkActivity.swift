import Foundation
import HermesKit
import HermesPush
#if os(iOS)
import ActivityKit
#endif

/// The call outside the app (`docs/voice.md` §4.4): a Live Activity on iPhone and iPad (the Lock
/// Screen and the Dynamic Island, with Mute and End), next to background audio. The Mac shows
/// the call in its menu bar instead (`TalkMenuBar`): ActivityKit doesn't run in Mac apps.
@MainActor
final class TalkActivity {
    static let shared = TalkActivity()

    #if os(iOS)
    private var activity: Activity<TalkActivityAttributes>?
    private var lastState: TalkActivityAttributes.ContentState?
    private var lastLineUpdate = Date.distantPast
    /// A newer line held back by the budget, shown when it allows.
    private var trailing: Task<Void, Never>?
    #endif

    func start(for session: TalkSession) {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = TalkActivityAttributes(title: session.speakerName, face: session.botAppearance?.look, startedAt: .now)
        let state = Self.state(of: session)
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        lastState = state
        #endif
    }

    /// Phase and Mute follow at once; the quoted line at most every 4 s (activities have a budget).
    func update(for session: TalkSession) {
        #if os(iOS)
        guard let activity else { return }
        let state = Self.state(of: session)
        guard state != lastState else { return }
        let onlyLine = lastState.map { $0.phase == state.phase && $0.isMuted == state.isMuted } ?? false
        let since = Date.now.timeIntervalSince(lastLineUpdate)
        if onlyLine, since < 4 {
            // The last words still get there, once the budget allows.
            trailing?.cancel()
            trailing = Task { [weak self, weak session] in
                try? await Task.sleep(for: .seconds(4 - since))
                guard !Task.isCancelled, let self, let session else { return }
                self.update(for: session)
            }
            return
        }
        trailing?.cancel()
        trailing = nil
        lastState = state
        lastLineUpdate = .now
        let id = activity.id
        Task { await Self.activity(id)?.update(ActivityContent(state: state, staleDate: nil)) }
        #endif
    }

    /// A call never outlives the app that ran it, but its Live Activity did: after a crash, or the
    /// app being stopped mid-call, the Lock Screen kept a call that was gone, with Mute and End.
    /// The next launch ends them (`docs/voice.md` §4.4).
    func endLeftovers() {
        #if os(iOS)
        let current = activity?.id
        let leftovers = Activity<TalkActivityAttributes>.activities.map(\.id).filter { $0 != current }
        guard !leftovers.isEmpty else { return }
        TalkCenter.logger.info("ending \(leftovers.count) call activities left from before")
        Task {
            for id in leftovers {
                await Self.activity(id)?.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    func end() {
        #if os(iOS)
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        trailing?.cancel()
        trailing = nil
        let id = activity.id
        Task { await Self.activity(id)?.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    #if os(iOS)
    // Activities aren't Sendable: tasks look them up by id instead of carrying them.
    nonisolated private static func activity(_ id: String) -> Activity<TalkActivityAttributes>? {
        Activity<TalkActivityAttributes>.activities.first { $0.id == id }
    }

    static func state(of session: TalkSession) -> TalkActivityAttributes.ContentState {
        let phase: TalkActivityAttributes.ContentState.Phase = switch session.phase {
        case .connecting: .connecting
        case .listening: .listening
        case .working: .working
        case .speaking: .speaking
        case .approval, .question, .needsTyping: .needsYou
        case .onHold, .offline, .noMicrophone, .failed: .onHold
        }
        let caption = session.caption.map { ($0.settled + $0.lighter).trimmingCharacters(in: .whitespaces) }
        let line = caption.flatMap { $0.isEmpty ? nil : SpokenAnswers.tail($0, limit: 90) }
        return .init(phase: phase, isMuted: session.isMuted, line: line)
    }
    #endif
}
