import Foundation
import HermesKit
import HermesPush

/// What chats tell push: a turn started or ended, an approval or question arrived or went away.
/// Drives the permission ask, the Live Activity and the Mac's own notifications.
extension PushCenter {
    func workspace(of conversation: ConversationModel) -> BotWorkspace? {
        if let workspace = conversation.workspace { return workspace }
        guard let roster = conversation.roster else { return nil }
        return model?.workspaces.values.first { $0.roster === roster }
    }

    func conversation(_ conversation: ConversationModel, working: Bool) {
        if working {
            workingChats.insert(ObjectIdentifier(conversation))
        } else {
            workingChats.remove(ObjectIdentifier(conversation))
        }
        guard let workspace = workspace(of: conversation) else { return }
        if working {
            let started = conversation.liveTurn?.startedAt ?? .now
            #if os(iOS)
            (activities as? TurnActivityController)?.turnStarted(in: conversation, gatewayID: workspace.id, at: started)
            #endif
            return
        }
        let turn = conversation.liveTurn ?? conversation.latestAssistantTurn
        let seconds = turn.flatMap { turn in turn.startedAt.map { (turn.finishedAt ?? .now).timeIntervalSince($0) } } ?? 0
        let ok: Bool
        switch turn?.state {
        case .failed?, .stopped?: ok = false
        default: ok = true
        }
        if seconds >= 30, ok { considerAsking(.longTurn) }
        #if os(iOS)
        // Words only: a widget, private or not, never reaches the Live Activity (`docs/widgets.md` §8).
        let result = turn.map { Self.firstLine($0.previewText) }
        (activities as? TurnActivityController)?.turnFinished(in: conversation, ok: ok, result: ok ? result : String(localized: "Didn’t finish"))
        #else
        // The final text can land a moment after the turn ends (the transcript fetch).
        Task { [weak conversation] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let conversation else { return }
            let text = (conversation.latestAssistantTurn ?? turn)?.previewText
            if ok { MacNotifier.shared.turnFinished(in: conversation, workspace: workspace, seconds: seconds, text: text) }
        }
        #endif
    }

    func conversation(_ conversation: ConversationModel, approval: ApprovalRequest?, replacing old: ApprovalRequest?) {
        if let old, old.id != approval?.id {
            #if os(macOS)
            MacNotifier.shared.resolved(old.id)
            #else
            // Answered (here or elsewhere): its notification goes now, not when the withdraw push lands.
            Task { await removeDelivered(requests: [old.id]) }
            #endif
        }
        guard let approval, approval.id != old?.id else { return }
        // A chat nobody opened (setup's About You) is no moment to ask (`docs/onboarding.md` §4).
        if !conversation.sentInBackground { considerAsking(.approval) }
        #if os(macOS)
        if let workspace = workspace(of: conversation) {
            MacNotifier.shared.approval(approval, in: conversation, workspace: workspace)
        }
        #endif
    }

    func conversation(_ conversation: ConversationModel, requests: [HermesRequest], old: [HermesRequest]) {
        let before = Set(old.map(\.id)), now = Set(requests.map(\.id))
        #if os(iOS)
        let gone = before.subtracting(now)
        if !gone.isEmpty { Task { await removeDelivered(requests: gone) } }
        #endif
        #if os(macOS)
        for id in before.subtracting(now) { MacNotifier.shared.resolved(id) }
        if let workspace = workspace(of: conversation) {
            for request in requests where !before.contains(request.id) {
                MacNotifier.shared.request(request, in: conversation, workspace: workspace)
            }
        }
        #endif
        if !now.subtracting(before).isEmpty, !conversation.sentInBackground { considerAsking(.approval) }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return plain.count > 120 ? String(plain.prefix(119)) + "…" : plain
    }
}
