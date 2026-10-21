#if DEBUG
import Foundation
import HermesKit
import Observation
import SwiftUI

/// A call frozen in one state, for the design gallery and screenshots (`-HERMES_GALLERY talk`).
@MainActor
@Observable
final class TalkStage: TalkDisplay {
    var phase: TalkSession.Phase
    var speakerName = "Hermes"
    var figureAppearance = BotAppearance(profile: "hermes")
    var engineName = "Realtime"
    var startedAt: Date? = Date.now.addingTimeInterval(-134)
    var status: String
    var caption: (settled: String, lighter: String)?
    var hint: String?
    var notice: String?
    var setupNote: SetupStatus?
    var showsCaptions = true
    var isMuted = false
    var inputLevel: Float = 0.45
    var outputLevel: Float = 0.6
    var runningStep: (title: String, since: Date)?
    var card: String?
    var pendingApproval: ApprovalRequest?
    var pendingRequest: HermesRequest? { nil }
    var chat: ConversationModel? { nil }
    var route = AudioRoute(output: .bluetooth, name: "AirPods Pro")
    var heard = ""
    var transcriptLines: [TalkLine] = []

    init(_ phase: TalkSession.Phase, status: String, caption: (String, String)? = nil, hint: String? = nil) {
        self.phase = phase
        self.status = status
        self.caption = caption.map { (settled: $0.0, lighter: $0.1) }
        self.hint = hint
    }

    func toggleMute() { isMuted.toggle() }
    func interrupt() {}
    func retry() {}
    func respond(_ choice: ApprovalChoice, to approval: ApprovalRequest) {}

    /// The states in `screens/iphone/talk.elyx`.
    static var all: [TalkStage] {
        let listening = TalkStage(.listening, status: "Listening", caption: ("Check the NAS, and clean up snapshots", " older than a month"), hint: "Pause when you’re done")
        let working = TalkStage(.working, status: "Working", caption: ("", "Checking the NAS, then the snapshots."), hint: "Keep talking to steer")
        working.runningStep = ("df -h /volume1", .now.addingTimeInterval(-3))
        let speaking = TalkStage(.speaking, status: "Speaking", caption: ("The NAS is at 61%. Snapshots older than 30 days take 148 GB.", " Want me to delete them?"), hint: "Talk or tap to interrupt")
        let approval = TalkStage(.approval, status: "Needs your OK", caption: ("I need your OK to run a command on the NAS.", ""), hint: "Say “allow once” or “deny”")
        approval.pendingApproval = ApprovalRequest(requestID: "r1", command: "rm -rf ./build && make release", description: "Recursive delete", choices: [.once, .session, .always, .deny])
        let card = TalkStage(.speaking, status: "Speaking", caption: ("Light rain until noon, 13° at most.", " Your flight lands after it clears."))
        card.card = "| Time | Weather |\n|---|---|\n| 09:00 | Light rain, 11° |\n| 12:00 | Clearing, 13° |"
        let bot = TalkStage(.speaking, status: "Speaking", caption: ("I can’t find a speculative decoding paper from this week yet.", " Want me to check again tonight?"), hint: "Talk or tap to interrupt")
        bot.speakerName = "Research Buddy"
        bot.engineName = "Cedar"
        bot.startedAt = .now.addingTimeInterval(-48)
        bot.figureAppearance = BotAppearance(profile: "research", shape: "hexagon", color: "hsl(150 68% 58%)", customized: true)
        let muted = TalkStage(.listening, status: "Muted", caption: ("You're muted", ""), hint: "Tap Mute to talk again")
        muted.isMuted = true
        let microphone = TalkStage(.noMicrophone, status: "Microphone is off", caption: ("", "Hermes needs the microphone to hear you. Speech is turned into text on this device."))
        return [listening, working, speaking, approval, card, bot, muted, microphone]
    }
}
#endif
