import Foundation

// The app's own plugins (`docs/plugins.md` §2): one entry each. Capability lists come from each
// published version's `plugin.yaml` and `register()` in `Tools/<plugin>`; a test checks the pinned
// one against the manifest.

extension AppPlugin {
    /// What the app says about one of its plugins: in the ask, the offers, the review and the
    /// result. Words that name the gateway take its name.
    public struct Words: Sendable {
        /// "Hermes App Push": how rows and the review name it.
        public var title = ""
        /// "Notifications": the feature, as the ask lists it.
        public var feature = ""
        /// "Notifications when the app is closed": under the name in the review.
        public var tagline = ""
        /// An offer row's sentence.
        public var summary = ""
        /// The ask's line after the name.
        public var askLine = ""
        /// Its feature glyph, drawn on ink.
        public var symbol = "puzzlepiece.extension"
        public var maker = "Caffeinated Code"
        /// "What you get".
        public var benefits: [Benefit] = []
        /// "What it can do on <gateway>", one line per thing it can reach. Every hook of the
        /// pinned version is named on one of them.
        public var review: @Sendable (_ gateway: String) -> [CapabilityLine] = { _ in [] }
        /// The disclosure, labelled "From Caffeinated Code".
        public var promise: @Sendable (_ gateway: String) -> String = { _ in "" }
        /// The offer card in context while it's missing (`pluginOffer`).
        public var offer: @Sendable (_ gateway: String) -> Offer = { _ in Offer(title: "", body: "") }
        /// The offer card while it's installed but turned off (`pluginOfferTurnOn`).
        public var offerOff: @Sendable (_ gateway: String) -> Offer = { _ in Offer(title: "", body: "") }
        /// The getting-started checklist's row, for plugins offered there.
        public var checklist: @Sendable (_ gateway: String) -> Offer = { _ in Offer(title: "", body: "") }
        /// What a Bot misses while the plugin isn't there (`pluginProfiles`' summary).
        public var missingEffect = ""
        /// After it installs: the chat "Try It in a New Chat" starts, if it has one.
        public var tryPrompt: String?
        /// Part of it starts only with the gateway (a delivery platform, a watcher): installing it
        /// in the root offers Restart Gateway, and this says why.
        public var restartReason: String?

        public init() {}
    }

    /// Push notifications (`Tools/hermes-app-push`, `docs/notifications.md`). 1.4.8 counts only requests
    /// the person can still answer (none whose process a restart ended, past its deadline or, without
    /// one, six hours old) and closes a question or approval when its turn ends, same access. 1.4.7 counts a chat Hermes
    /// never marked only once it's read, as the app's list does (`presence away` with `unmarked`), and
    /// takes a chat deleted or archived anywhere off every badge (`on_session_delete`, more access, so
    /// moving to it shows the consent card). 1.4.6 keeps the badge the
    /// true unread count (news read before its notice goes isn't sent, reads ride on background pushes and
    /// on each device's check-in), same access; 1.4.5 sets a badge left
    /// showing a count the person can't see, same access; 1.4.4 seals a card fill
    /// as flagged too, for older app builds, same access; 1.4.3 sends a card fill's notification as
    /// open-only, same access; 1.4.2 counts only chats the app lists in a sleeping
    /// device's badge, same access; 1.4.1 clips notices by
    /// bytes, so a long command in any script still fits the relay, same access; 1.4.0 passes reads on
    /// to the person's other devices (`read`, read pushes, badge-only pushes) with the same access;
    /// 1.3.2 is 1.3.1 from the
    /// repository rewritten to one commit (no personal data in its history), same access; 1.3.1 reads reply,
    /// room and cron text in one pass (patterns that stalled the gateway on crafted text) with the
    /// same access; 1.3.0 answers `/app-push host` (how the gateway's Mac schedules Hermes,
    /// Settings → Setup → Priority); 1.2.1 sent no notice for a turn that ends in "[SILENT]".
    public static let push = AppPlugin(
        name: "hermes-app-push", repo: "vburojevic/hermes-app-push",
        ref: "52c5d51a5452b43537e67c6b6016236491648461", version: "1.4.8", minimumVersion: "1.4.8",
        capabilities: ["1.0.0": pushAccess, "1.1.0": pushAccess, "1.2.0": pushAccess, "1.2.1": pushAccess, "1.3.0": pushAccess,
                       "1.3.1": pushAccess, "1.3.2": pushAccess, "1.4.0": pushAccess, "1.4.1": pushAccess, "1.4.2": pushAccess,
                       "1.4.3": pushAccess, "1.4.4": pushAccess, "1.4.5": pushAccess, "1.4.6": pushAccess,
                       "1.4.7": pushCapabilities(since147: true), "1.4.8": pushCapabilities(since147: true)],
        moments: [.ask, .notificationsPrime],
        words: pushWords
    )

    /// Widgets agents send to the app (`Tools/hermes-app-widgets`, `docs/widgets.md`). 1.3.0 keeps a
    /// chat Hermes compacted into a new session the app's, says that a short question ("Weather
    /// today?") gets its widget and tells marked chats so again, with the same access, so the app
    /// moves every profile to it quietly. 1.2.2 is 1.2.1
    /// with its examples in a US demo world, from the repository rewritten to one commit, same
    /// access; 1.2.1 closes
    /// ways a reply could plant a widget (look-alike fences, a directive's alt), matches `for` by
    /// user id and treats Discord threads as groups, with the same access; 1.2.0 knows the everyday
    /// cards (quote stats, flights, watched prices, weather alerts), which the app draws; 1.1.1
    /// brought marking many chats in one `session` call and unprompted widgets.
    public static let widgets = AppPlugin(
        name: "hermes-app-widgets", repo: "vburojevic/hermes-app-widgets",
        ref: "23b7a2d5e08e6284dad51b864256afe48fe7c4ff", version: "1.3.0", minimumVersion: "1.3.0",
        capabilities: ["1.0.0": widgetsAccess(since111: false), "1.1.0": widgetsAccess(since111: false),
                       "1.1.1": widgetsAccess(since111: true), "1.2.0": widgetsAccess(since111: true),
                       "1.2.1": widgetsAccess(since111: true), "1.2.2": widgetsAccess(since111: true),
                       "1.3.0": widgetsAccess(since111: true)],
        moments: [.ask, .whatsNew, .checklist],
        words: widgetsWords
    )

    private static let pushAccess = pushCapabilities(since147: false)

    /// 1.4.7 added `on_session_delete`, so a chat deleted or archived elsewhere leaves the badge.
    private static func pushCapabilities(since147: Bool) -> PluginCapabilities {
        PluginCapabilities(
            hooks: ["pre_llm_call", "post_llm_call", "on_session_end", "pre_tool_call", "pre_approval_request",
                    "post_approval_response", "on_human_input_request", "on_human_input_resolved", "on_room_member_activity",
                    "kanban_task_completed", "kanban_task_blocked"] + (since147 ? ["on_session_delete"] : []),
            commands: ["app-push"], platforms: ["apppush"], networkHosts: ["push.hermesapp.dev"]
        )
    }

    /// 1.1.1 added `pre_llm_call`, for app chats whose prompt predates their widgets.
    private static func widgetsAccess(since111: Bool) -> PluginCapabilities {
        PluginCapabilities(
            hooks: (since111 ? ["pre_llm_call"] : []) + ["transform_llm_output", "pre_gateway_dispatch", "subagent_start"],
            tools: ["widget", "widget_examples"], commands: ["app-widgets"], skills: ["widgets"],
            promptSections: ["hermes-app-widgets"]
        )
    }

    private static var deviceName: String {
        #if os(macOS)
        String(localized: "Mac")
        #else
        String(localized: "iPhone")
        #endif
    }

    private static var pushWords: Words {
        var words = Words()
        words.title = String(localized: "Hermes App Push")
        words.feature = String(localized: "Notifications")
        words.tagline = String(localized: "Notifications when the app is closed")
        words.summary = String(localized: "Approvals, questions and finished turns on your Lock Screen, even with the app closed.")
        #if os(macOS)
        words.askLine = String(localized: "approvals, questions and finished turns, even with the app closed")
        #else
        words.askLine = String(localized: "approvals, questions and finished turns on your Lock Screen")
        #endif
        words.symbol = "bell.badge.fill"
        words.benefits = [
            Benefit(symbol: "bell.badge.fill", words: String(localized: "Approvals and questions on your Lock Screen, with Allow Once and Deny")),
            Benefit(symbol: "checkmark.circle", words: String(localized: "A notice when a reply finishes, a task runs or a Board card needs you")),
            Benefit(symbol: "at", words: String(localized: "Messages from your Bots in group chats")),
        ]
        words.review = { _ in
            [
                CapabilityLine(.sees, String(localized: "Sees approvals and questions, and when they’re answered"),
                               names: ["pre_approval_request", "post_approval_response", "on_human_input_request", "on_human_input_resolved"]),
                CapabilityLine(.sees, String(localized: "Sees when replies start and end, and each step’s name"),
                               names: ["pre_llm_call", "post_llm_call", "on_session_end", "pre_tool_call"]),
                CapabilityLine(.sees, String(localized: "Knows when chats are deleted or archived"),
                               names: ["on_session_delete"]),
                CapabilityLine(.sees, String(localized: "Sees Bot messages in group chats and Board cards that need you"),
                               names: ["on_room_member_activity", "kanban_task_completed", "kanban_task_blocked"]),
                CapabilityLine(.tools, String(localized: "Adds /app-push for this app, and a delivery for scheduled tasks"),
                               names: ["command app-push", "platform apppush"]),
                CapabilityLine(.network, String(localized: "Sends encrypted notices to push.hermesapp.dev, which hands them to Apple"),
                               names: [String(localized: "the relay sees only the kind of event")]),
                CapabilityLine(.safe, String(localized: "Never sends passwords, secrets or codes"),
                               names: [String(localized: "Hermes’s redactor"), String(localized: "sealed per device")]),
            ]
        }
        words.promise = { _ in
            String(localized: "Each notice is sealed for one device. The relay keeps only this gateway’s id, a hash of its secret, the plugin’s version and push counts.")
        }
        words.offer = { gateway in
            Offer(title: String(localized: "Get notified when the app is closed"),
                  body: String(localized: "Hermes App Push sends approvals, questions and finished turns to this \(deviceName), encrypted. It installs on \(gateway) in a few seconds."))
        }
        words.offerOff = { gateway in
            Offer(title: String(localized: "Notifications are off"),
                  body: String(localized: "Hermes App Push is installed on \(gateway) but turned off, so this \(deviceName) gets no notifications."))
        }
        words.missingEffect = String(localized: "Their chats, routines and Bot Chats can’t send notifications until it’s there.")
        words.restartReason = String(localized: "Scheduled tasks and Board cards notify once it restarts. Running replies finish first.")
        return words
    }

    private static var widgetsWords: Words {
        var words = Words()
        words.title = String(localized: "Hermes App Widgets")
        words.feature = String(localized: "Cards in replies")
        words.tagline = String(localized: "Cards in replies")
        words.summary = String(localized: "Replies with cards you can tap: weather, charts, checklists, approvals.")
        #if os(macOS)
        words.askLine = String(localized: "weather, charts, checklists and approvals you can click")
        #else
        words.askLine = String(localized: "weather, charts, checklists and approvals you can tap")
        #endif
        words.symbol = "widget.small"
        words.benefits = [
            Benefit(symbol: "widget.small", words: String(localized: "Hermes answers with cards: weather, charts, lists, timers, routes")),
            Benefit(symbol: "checklist", words: String(localized: "Tap to answer. Hermes gets your choice as a message and confirms it")),
            Benefit(symbol: "text.quote", words: String(localized: "Telegram, Slack and other chats get the same answer as text")),
        ]
        words.review = { gateway in
            [
                CapabilityLine(.tools, String(localized: "Adds 2 tools, a skill and /app-widgets for this app"),
                               names: ["widget", "widget_examples", "skill widgets", "command app-widgets"]),
                CapabilityLine(.prompt, String(localized: "Adds card rules to Hermes’s instructions in this app’s chats"),
                               names: ["prompt section", "pre_llm_call"]),
                CapabilityLine(.reaches, String(localized: "Can change replies before they’re saved, to turn cards into text elsewhere"),
                               names: ["transform_llm_output"]),
                CapabilityLine(.reaches, String(localized: "Reads messages on other platforms, to turn a plain answer into the card’s action"),
                               names: ["pre_gateway_dispatch"]),
                CapabilityLine(.sees, String(localized: "Knows when helpers start, so they don’t send cards"),
                               names: ["subagent_start"]),
                CapabilityLine(.files, String(localized: "Keeps cards in ~/.hermes/widgets on \(gateway)"),
                               names: [String(localized: "owner-only"), String(localized: "per gateway")]),
                CapabilityLine(.safe, String(localized: "Needs no keys and sends nothing off \(gateway)"),
                               names: ["no network", "store_media is off"]),
            ]
        }
        words.promise = { gateway in
            String(localized: "Cards are checked before anyone sees them, stored only on \(gateway), and acted on once: the first answer wins.")
        }
        words.offer = { gateway in
            Offer(title: String(localized: "Turn on cards for \(gateway)"),
                  body: String(localized: "Weather, charts, checklists and approvals you can tap. Hermes App Widgets adds them on \(gateway); other chats keep getting text."))
        }
        words.offerOff = { gateway in
            Offer(title: String(localized: "Cards in replies are off"),
                  body: String(localized: "Hermes App Widgets is installed on \(gateway) but turned off, so Hermes answers in text."))
        }
        words.checklist = { gateway in
            Offer(title: String(localized: "Let Hermes answer with cards"),
                  body: String(localized: "Installs a plugin on \(gateway) · you review it first"))
        }
        words.missingEffect = String(localized: "Their chats answer in plain text until it’s there.")
        words.tryPrompt = String(localized: "What’s the weather like this weekend?")
        return words
    }
}
