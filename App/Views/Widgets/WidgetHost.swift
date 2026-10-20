import HermesKit
import SwiftUI

/// Where a chat's widgets live and who answers them (`docs/widgets.md` §5): the transcript sets
/// one per chat. Cards read the chat's facts and the gateway's store through it, so a card redraws
/// when its own widget changes, not with every streamed word.
@MainActor
final class WidgetHost {
    weak var conversation: ConversationModel?
    /// A Bot group chat: answers go to the room, and a widget is answered only by who its `for` names.
    weak var room: GroupChatModel?
    let store: WidgetStore

    init(conversation: ConversationModel?, store: WidgetStore) {
        self.conversation = conversation
        self.store = store
    }

    init(room: GroupChatModel, store: WidgetStore) {
        self.room = room
        self.store = store
    }

    var facts: WidgetChatFacts { conversation?.widgetFacts ?? room?.widgetFacts ?? WidgetChatFacts() }

    /// A newer widget in this chat that replaces `id`.
    func supersedingID(_ id: String) -> String? {
        for other in facts.shown.reversed() where other != id {
            if store.payload(other)?.envelope.supersedes == id { return other }
        }
        return nil
    }

    /// In a group chat, the Bot a widget is for, when it's for one of the room's Bots rather than
    /// the person (contract §9: others see it read-only, "For Ops"). The person is the room's
    /// only human, so a `for` naming anyone else is theirs.
    func forOther(_ payload: WidgetPayload) -> String? {
        guard let room, let target = payload.envelope.for else { return nil }
        let name = target.name.lowercased()
        let isBot = room.room.members.contains { member in
            [member.handle, member.profile, member.displayName ?? ""].contains { $0.lowercased() == name }
        }
        return isBot ? target.name : nil
    }

    func interaction(for payload: WidgetPayload, now: Date) -> WidgetInteraction {
        WidgetInteraction.evaluate(
            payload, facts: facts, local: store.local[payload.id], mine: store.mine, enteredTurn: store.enteredTurn,
            supersededBy: supersedingID(payload.id), forOther: forOther(payload), now: now
        )
    }

    // MARK: - Answers

    /// Sends a tap's answer: through Face ID and the device's signature when the plugin will
    /// check one (`WidgetSignature`), else at once.
    func send(_ answer: WidgetAnswer) {
        guard let sender = sender else { return }
        if let payload = store.payload(answer.widgetID), WidgetSignature.isRequired(payload.json, action: answer.action) {
            store.sendSigned(answer, title: payload.title, via: sender)
        } else {
            sender.sendWidgetAnswer(answer)
        }
    }

    private var sender: (any WidgetAnswerSender)? { conversation ?? room }

    func resend(_ text: String) {
        conversation?.resendWidgetAnswer(text)
        room?.sendWidgetText(text)
    }

    /// A tick waits 5 s for more in a chat; in a group chat it goes at once.
    func tick(_ item: String, in payload: WidgetPayload) {
        if let conversation {
            store.tick(item, in: payload, conversation: conversation)
        } else if let room, case .checklist(let list) = payload.content {
            var batch = ChecklistTicks(rev: payload.rev)
            batch.toggle(item)
            if let answer = batch.takeAnswer(payload, list) { room.sendWidgetAnswer(answer) }
        }
    }

    func rate(_ card: String, _ rating: WidgetAnswer.Rating, in payload: WidgetPayload, total: Int) {
        guard let conversation else { return }
        store.rate(card, rating, in: payload, total: total, conversation: conversation)
    }

    func sendSuggestion(_ words: String) {
        conversation?.sendSuggestion(words)
    }
}

/// Where a chat's answers go: a chat's turn, or a group chat's room.
@MainActor
protocol WidgetAnswerSender: AnyObject {
    var canSendWidgetAnswer: Bool { get }
    func sendWidgetAnswer(_ answer: WidgetAnswer)
}

extension ConversationModel: WidgetAnswerSender {}

extension EnvironmentValues {
    @Entry var widgetHost: WidgetHost?
    /// The gallery's stand-ins for the clock and the round trip (Debug only in practice).
    @Entry var widgetPreview: WidgetPreview?
}

/// A card drawn at another moment or in another state, for the gallery.
struct WidgetPreview: Hashable {
    var now: Date?
    var interaction: WidgetInteraction?
}
