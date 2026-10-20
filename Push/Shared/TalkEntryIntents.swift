import AppIntents
import Foundation
import HermesPush

/// Starts a call (`docs/voice.md` §4.4): Siri and Shortcuts ("Talk to Hermes", "Talk to Ada in
/// Hermes"), the Control Center control, the Lock Screen and the Action button. It opens the
/// app, which opens the chat and calls.
struct StartTalkIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Hermes"
    static let description = IntentDescription("Starts a call with Hermes or one of your Bots.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Bot") var bot: BotEntity?

    init() {}

    init(bot: BotEntity?) {
        self.bot = bot
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Talk to \(\.$bot)")
    }

    func perform() async throws -> some IntentResult {
        #if !HERMES_WIDGET
        let name = bot?.id
        await MainActor.run { TalkCenter.shared.pendingStart = .init(botName: name) }
        #endif
        return .result()
    }
}

/// A Bot to call: its profile name and title.
struct BotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Bot"
    static let defaultQuery = BotQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct BotQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [BotEntity] {
        TalkDirectory.bots().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [BotEntity] {
        TalkDirectory.bots().filter { $0.title.localizedStandardContains(string) || $0.id.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [BotEntity] {
        TalkDirectory.bots()
    }
}

/// The Bots the app last saw, kept where Shortcuts and the control can read them (the App Group).
/// Names only: nothing a Bot said.
nonisolated enum TalkDirectory {
    private static let key = "talk.bots"

    static func bots() -> [BotEntity] {
        let saved = PushShared.current.defaults.array(forKey: key) as? [[String]] ?? []
        return saved.compactMap { pair in pair.count == 2 ? BotEntity(id: pair[0], title: pair[1]) : nil }
    }

    static func save(_ bots: [(id: String, title: String)]) {
        let pairs = bots.map { [$0.id, $0.title] }
        guard pairs != (PushShared.current.defaults.array(forKey: key) as? [[String]] ?? []) else { return }
        PushShared.current.defaults.set(pairs, forKey: key)
    }
}
