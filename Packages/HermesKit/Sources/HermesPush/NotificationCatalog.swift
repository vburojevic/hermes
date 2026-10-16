import Foundation
import UserNotifications

/// The notification categories and actions (`docs/notifications.md` §2–3, §6), shared by the
/// app (which registers them), the service extension (which picks one per notice) and the
/// content extension (which adds a question's choices).
///
/// iOS can't vary the hidden-preview text per notification, only per category, so each base
/// category also exists once per gateway "slot" (`APPROVAL.3`) whose placeholder names that
/// gateway: a locked phone shows "Needs your OK on Home Server" and nothing else.
public enum NotificationCatalog {
    public enum Category: String, CaseIterable, Sendable {
        case approval = "APPROVAL"
        case question = "QUESTION"
        case reply = "REPLY"
        case message = "MESSAGE"
        case task = "TASK"
        case open = "OPEN"
        /// Passwords and sign-ins: `OPEN` with its own placeholder.
        case password = "PASSWORD"
        /// "Save to memory?" (Ask Before Saving on): Save, Don't Save.
        case memory = "MEMORY"
        /// A board card needs you: Reply (answers it and sends it back to Ready), Open.
        case card = "CARD"
        /// A card's other news (ready for review, stopped, done): Open.
        case board = "BOARD"

        /// The category id for a gateway slot.
        public func identifier(slot: Int?) -> String {
            slot.map { "\(rawValue).\($0)" } ?? rawValue
        }

        public init?(identifier: String) {
            let base = identifier.split(separator: ".").first.map(String.init) ?? identifier
            self.init(rawValue: base)
        }
    }

    public enum Action {
        public static let allowOnce = "approval.once"
        public static let deny = "approval.deny"
        public static let moreOptions = "approval.more"
        public static let reply = "reply"
        public static let open = "open"
        public static let choicePrefix = "question.choice."
        /// "Save to memory?": once / deny. Never Always.
        public static let memorySave = "memory.save"
        public static let memoryDontSave = "memory.dontsave"

        public static func choice(_ index: Int) -> String { "\(choicePrefix)\(index)" }

        public static func choiceIndex(_ identifier: String) -> Int? {
            guard identifier.hasPrefix(choicePrefix) else { return nil }
            return Int(identifier.dropFirst(choicePrefix.count))
        }
    }

    /// Per-gateway category sets; the content extension's Info.plist lists the same range.
    public static let slotCount = 16

    /// What a locked phone says for a notice of this category ("Needs your OK on Home Server").
    public static func hiddenText(_ category: Category, gateway: String?, failed: Bool = false) -> String {
        guard let gateway, !gateway.isEmpty else {
            switch category {
            case .approval: return String(localized: "Needs your OK", bundle: .module)
            case .question: return String(localized: "Has a question", bundle: .module)
            case .password: return String(localized: "Needs a password", bundle: .module)
            case .reply: return String(localized: "Reply ready", bundle: .module)
            case .task: return failed ? String(localized: "A task failed", bundle: .module) : String(localized: "A task finished", bundle: .module)
            case .message: return String(localized: "New message", bundle: .module)
            case .open: return String(localized: "Work finished", bundle: .module)
            case .memory: return String(localized: "Wants to remember something", bundle: .module)
            case .card: return String(localized: "A card needs you", bundle: .module)
            case .board: return String(localized: "Board update", bundle: .module)
            }
        }
        switch category {
        case .approval: return String(localized: "Needs your OK on \(gateway)", bundle: .module)
        case .question: return String(localized: "Has a question on \(gateway)", bundle: .module)
        case .password: return String(localized: "Needs a password on \(gateway)", bundle: .module)
        case .reply: return String(localized: "Reply ready on \(gateway)", bundle: .module)
        case .task:
            return failed ? String(localized: "A task failed on \(gateway)", bundle: .module) : String(localized: "A task finished on \(gateway)", bundle: .module)
        case .message: return String(localized: "New message on \(gateway)", bundle: .module)
        case .open: return String(localized: "Work finished on \(gateway)", bundle: .module)
        case .memory: return String(localized: "Wants to remember something on \(gateway)", bundle: .module)
        case .card: return String(localized: "A card needs you on \(gateway)", bundle: .module)
        case .board: return String(localized: "Board update on \(gateway)", bundle: .module)
        }
    }

    /// Every category: the base set plus one set per named gateway slot (`slot → name`).
    public static func categories(slots: [Int: String] = [:], questionChoices: [String: [String]] = [:]) -> Set<UNNotificationCategory> {
        var all = Set<UNNotificationCategory>()
        for category in Category.allCases {
            all.insert(make(category, identifier: category.rawValue, gateway: nil))
            for (slot, name) in slots where slot < slotCount {
                all.insert(make(category, identifier: category.identifier(slot: slot), gateway: name))
            }
        }
        // Mac: local questions carry their choices as a category of their own.
        for (identifier, choices) in questionChoices {
            all.insert(make(.question, identifier: identifier, gateway: nil, choices: choices))
        }
        return all
    }

    static func make(_ category: Category, identifier: String, gateway: String?, choices: [String] = []) -> UNNotificationCategory {
        let actions = actions(for: category, choices: choices)
        #if os(iOS)
        return UNNotificationCategory(
            identifier: identifier, actions: actions, intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: hiddenText(category, gateway: gateway), options: []
        )
        #else
        return UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
        #endif
    }

    /// The actions for a category. Allow and Deny need Face ID; Always Allow is never one tap from
    /// the Lock Screen (More Options… opens the full card).
    public static func actions(for category: Category, choices: [String] = []) -> [UNNotificationAction] {
        switch category {
        case .approval:
            return [
                UNNotificationAction(identifier: Action.allowOnce, title: String(localized: "Allow Once", bundle: .module), options: [.authenticationRequired], icon: .init(systemImageName: "checkmark")),
                UNNotificationAction(identifier: Action.deny, title: String(localized: "Deny", bundle: .module), options: [.authenticationRequired, .destructive], icon: .init(systemImageName: "xmark")),
                UNNotificationAction(identifier: Action.moreOptions, title: String(localized: "More Options…", bundle: .module), options: [.foreground], icon: .init(systemImageName: "ellipsis")),
            ]
        case .memory:
            // Save is the default action.
            return [
                UNNotificationAction(identifier: Action.memorySave, title: String(localized: "Save", bundle: .module), options: [.authenticationRequired], icon: .init(systemImageName: "checkmark")),
                UNNotificationAction(identifier: Action.memoryDontSave, title: String(localized: "Don't Save", bundle: .module), options: [.authenticationRequired, .destructive], icon: .init(systemImageName: "xmark")),
            ]
        case .question:
            return choiceActions(choices) + [replyAction(answer: true)]
        case .reply, .message:
            return [replyAction(answer: false)]
        case .task, .board:
            return [openAction]
        case .card:
            return [replyAction(answer: true), openAction]
        case .open, .password:
            return []
        }
    }

    static var openAction: UNNotificationAction {
        UNNotificationAction(identifier: Action.open, title: String(localized: "Open", bundle: .module), options: [.foreground], icon: .init(systemImageName: "arrow.up.forward.app"))
    }

    /// Up to three of a question's choices, each answering it in the background.
    public static func choiceActions(_ choices: [String]) -> [UNNotificationAction] {
        choices.prefix(3).enumerated().map { index, choice in
            UNNotificationAction(identifier: Action.choice(index), title: choice, options: [.authenticationRequired])
        }
    }

    public static func replyAction(answer: Bool) -> UNNotificationAction {
        UNTextInputNotificationAction(
            identifier: Action.reply, title: String(localized: "Reply…", bundle: .module),
            options: [.authenticationRequired], icon: .init(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: answer ? String(localized: "Answer", bundle: .module) : String(localized: "Send", bundle: .module),
            textInputPlaceholder: answer ? String(localized: "Your answer", bundle: .module) : String(localized: "Message Hermes", bundle: .module)
        )
    }
}
