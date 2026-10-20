import Foundation

/// Whether a feature that depends on something configured can work, and how to set it up
/// (`docs/setup.md` §1). A feature's producer works this out from what the gateway and the device
/// report; the app's setup views (`SetupSection`, `SetupCard`, `SetupNote`…) draw every feature
/// the same way.
public struct SetupStatus: Identifiable, Hashable, Sendable {
    /// `docs/setup.md` §1.1.
    public enum State: Hashable, Sendable {
        /// Asking the gateway or the device.
        case checking
        /// Set up and working. `detail` says what's in use ("ElevenLabs · Adam").
        case ready
        /// Works in a lesser way. `fallback` says how, and why.
        case limited
        /// Doesn't work until it's set up, and nothing stands in for it.
        case notSetUp
        /// The app can't tell: the gateway can't be reached, or the check needs Bot Mode.
        case unknown

        /// The feature needs the person: something to set up, or a fallback they may not want.
        public var needsAttention: Bool { self == .notSetUp || self == .limited }

        /// Lists show what needs setting up first and what's ready last.
        public var order: Int {
            switch self {
            case .notSetUp: 0
            case .limited: 1
            case .unknown: 2
            case .checking: 3
            case .ready: 4
            }
        }
    }

    /// Stable and unique among the statuses shown together: "push", "voice.talk",
    /// "voice.talk@research".
    public let id: String
    public var state: State
    /// The feature's name: "Talk", "Notifications".
    public var title: String
    /// What the state means for the person, in one sentence; when ready, what's in use.
    public var detail: String?
    /// When `limited`: what still works and why ("Talk uses this iPhone's voice: the gateway has
    /// no voice provider.").
    public var fallback: String?
    /// The words of the fix the app can make itself, where Hermes accepts it. The view that shows
    /// the status supplies the action.
    public var fix: SetupFix?
    /// How to set it up elsewhere, when the app can't (or as well as the fix).
    public var steps: [SetupStep]
    /// Hermes Agent's page about it, opened as a web link.
    public var docs: URL?

    public init(
        id: String,
        state: State,
        title: String,
        detail: String? = nil,
        fallback: String? = nil,
        fix: SetupFix? = nil,
        steps: [SetupStep] = [],
        docs: URL? = nil
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.detail = detail
        self.fallback = fallback
        self.fix = fix
        self.steps = steps
        self.docs = docs
    }

    /// While the app asks.
    public static func checking(id: String, title: String) -> SetupStatus {
        SetupStatus(id: id, state: .checking, title: title)
    }

    /// The app can't ask: the gateway is out of reach, or the answer needs Bot Mode.
    public static func unknown(id: String, title: String, reason: String, docs: URL? = nil) -> SetupStatus {
        SetupStatus(id: id, state: .unknown, title: title, detail: reason, docs: docs)
    }

    /// Producers give steps where they help: to set up what's missing, or for a ready feature
    /// the one thing worth doing (an update). None while checking.
    public var showsSteps: Bool { state != .checking && !steps.isEmpty }

    /// Learn More, beside the steps or while the feature isn't ready.
    public var showsDocs: Bool { docs != nil && (showsSteps || (state != .ready && state != .checking)) }
}

/// A fix the app can make itself (`docs/setup.md` §1.2): "Turn On", "Install…", "Add Key…".
public struct SetupFix: Hashable, Sendable {
    /// What the fix does, for views that show statuses from several features: the same action
    /// (linking Bot Mode) can fix many of them.
    public struct Action: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Edit Gateway, with Bot Mode's link.
        public static let linkBotMode = Action(rawValue: "linkBotMode")
        /// Edit Gateway, to sign in to Bot Mode again.
        public static let signIn = Action(rawValue: "signIn")
        /// The feature's own fix: a setting the app writes for it.
        public static let feature = Action(rawValue: "feature")
        /// System Settings for this app.
        public static let openSettings = Action(rawValue: "openSettings")
    }

    public var title: String
    public var action: Action

    public init(title: String, action: Action = .feature) {
        self.title = title
        self.action = action
    }

    public static var linkBotMode: SetupFix { SetupFix(title: String(localized: "Link Bot Mode…"), action: .linkBotMode) }
    public static var signIn: SetupFix { SetupFix(title: String(localized: "Sign In…"), action: .signIn) }
    public static var openSettings: SetupFix { SetupFix(title: String(localized: "Open Settings"), action: .openSettings) }
}

/// One step to set a feature up outside the app (`docs/setup.md` §1.3): what to do, and the
/// command or config line to run, which the app shows monospaced with a Copy button.
public struct SetupStep: Hashable, Sendable {
    public var text: String
    public var command: String?

    public init(_ text: String, command: String? = nil) {
        self.text = text
        self.command = command
    }

    /// On an older Hermes Agent: the gateway's computer updates it, then restarts the gateway.
    public static var updateHermes: SetupStep {
        SetupStep(String(localized: "On the gateway's computer, update Hermes Agent:"), command: "hermes update")
    }

    /// After a change that the gateway only reads when it starts.
    public static var restartGateway: SetupStep {
        SetupStep(String(localized: "Then restart the gateway:"), command: "hermes gateway restart")
    }
}

extension Array where Element == SetupStatus {
    /// "2 to set up": features that are not set up or only partly.
    public var needingAttention: Int { count(where: { $0.state.needsAttention }) }

    /// Not set up first, ready last, otherwise in the order given.
    public var sortedForAttention: [SetupStatus] {
        enumerated()
            .sorted { ($0.element.state.order, $0.offset) < ($1.element.state.order, $1.offset) }
            .map(\.element)
    }
}

/// Hermes Agent's documentation (https://hermes-agent.nousresearch.com/docs/), for setup steps'
/// Learn More.
public enum HermesDocs {
    public static let root = URL(string: "https://hermes-agent.nousresearch.com/docs/")!

    /// A page by its path under `docs/`: "user-guide/bot-mode", "user-guide/features/kanban".
    public static func page(_ path: String) -> URL {
        root.appending(path: path)
    }
}
