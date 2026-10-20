import Foundation
import Observation

/// Onboarding on this device (`docs/onboarding.md`): what the person told setup, and which of the
/// getting-started checklist's items they've done. Per device, never synced.
@MainActor
@Observable
final class WelcomeProgress {
    static let shared = WelcomeProgress()

    /// The getting-started checklist (`getStartedCard`).
    enum Item: String, CaseIterable, Identifiable {
        /// Connected to a gateway.
        case connect
        /// Told Hermes about themselves (setup's About You, or any memory saved).
        case aboutYou
        /// Answered a first approval.
        case runCommand
        /// Opened a Bot Chat, or made a project when Bot Mode is off.
        case meetBots
        /// Turned checkpoints on.
        case checkpoints
        /// The widgets plugin is on (`pluginChecklist`): shown while it's missing or off.
        case cards

        var id: String { rawValue }
    }

    private let defaults: UserDefaults

    /// What Hermes should call them (setup's About You).
    var name: String {
        didSet { defaults.set(name, forKey: Keys.name) }
    }

    private(set) var done: Set<Item> {
        didSet { defaults.set(done.map(\.rawValue), forKey: Keys.done) }
    }

    /// ✕ on the card, or every item done: it stays hidden.
    private(set) var checklistHidden: Bool {
        didSet { defaults.set(checklistHidden, forKey: Keys.hidden) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Keys.name) ?? ""
        done = Set((defaults.stringArray(forKey: Keys.done) ?? []).compactMap(Item.init(rawValue:)))
        checklistHidden = defaults.bool(forKey: Keys.hidden)
    }

    func isDone(_ item: Item) -> Bool { done.contains(item) }

    /// The card shows the widgets row (`.cards`): the plugin is missing or off on the gateway.
    /// Set by the card; the row only counts toward "all done" while it's there or ticked.
    var showsCards = false

    /// The rows the card shows now.
    var shownItems: [Item] { Item.allCases.filter { $0 != .cards || showsCards || done.contains(.cards) } }

    /// Something on the checklist happened; the card hides itself once all its rows have.
    func mark(_ item: Item) {
        guard !done.contains(item) else { return }
        done.insert(item)
        if shownItems.allSatisfy(done.contains) { checklistHidden = true }
    }

    func hideChecklist() {
        checklistHidden = true
    }

    private enum Keys {
        static let name = "welcome.name"
        static let done = "welcome.checklist.done"
        static let hidden = "welcome.checklist.hidden"
    }
}
