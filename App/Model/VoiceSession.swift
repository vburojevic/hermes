import Foundation
import HermesKit
import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Voice mode (`screens/iphone/voice.elyx`, `docs/composer.md` §4): a hands-free conversation in
/// the same chat. Words are heard on the device; a pause of about 1.5 s sends them as a normal
/// message (a Steer Now while a turn runs), and the reply is read aloud as it streams.
@MainActor
@Observable
final class VoiceSession: Identifiable {
    enum Phase: Equatable {
        case starting
        case listening
        case muted
        /// A turn is running; the person can keep talking (that steers it).
        case thinking
        case speaking
        /// Hermes needs approval: tap, or say it.
        case approval
        case noMicrophone
        case offline
        case failed(String)
    }

    let id = UUID()
    let conversation: ConversationModel
    let workspace: BotWorkspace
    private(set) var phase: Phase = .starting
    /// Minimised: the conversation keeps going while the person reads the chat.
    var isMinimised = false
    var showsCaptions = UserDefaults.standard.object(forKey: "voiceCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsCaptions, forKey: "voiceCaptions") }
    }
    private(set) var isMuted = false
    /// iPhone and iPad: the loudspeaker rather than the earpiece. Mac: replies are read aloud.
    var prefersSpeaker = true {
        didSet {
            listener.prefersSpeaker = prefersSpeaker
            #if os(macOS)
            if !prefersSpeaker { speaker.stop() }
            #endif
        }
    }
    /// A line under the caption after a spoken approval that needs a tap ("Always Allow").
    private(set) var approvalHint: String?

    let listener = DictationController(mode: .conversation)
    let speaker = VoiceSpeaker()

    /// How long a pause sends what was said.
    static let pause: TimeInterval = 1.5

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The reply being read: how much of its answer has been queued for speech.
    @ObservationIgnored private var awaitingReply = false
    @ObservationIgnored private var spokenOffset = 0
    @ObservationIgnored private var trackedTurnID: String?
    /// Everything read aloud lately, to tell the speaker's own echo from the person.
    @ObservationIgnored private var recentlySpoken = ""
    @ObservationIgnored private var isSending = false

    init(conversation: ConversationModel, workspace: BotWorkspace) {
        self.conversation = conversation
        self.workspace = workspace
    }

    // MARK: What the screen shows

    /// Who's talking: "Hermes", or the Bot in a Bot Chat.
    var speakerName: String {
        if let name = conversation.botName { return workspace.roster?.bot(named: name)?.title ?? name }
        return "Hermes"
    }

    var botAppearance: BotAppearance? {
        guard let name = conversation.botName, let roster = workspace.roster, let bot = roster.bot(named: name) else { return nil }
        return roster.appearance(for: bot)
    }

    var title: String {
        conversation.isBotChat ? speakerName : String(localized: "Voice")
    }

    var status: String {
        switch phase {
        case .starting: String(localized: "Starting…")
        case .listening: conversation.isBotChat ? String(localized: "\(speakerName) is listening…") : String(localized: "Listening…")
        case .muted: String(localized: "Muted")
        case .thinking: workingStatus
        case .speaking: String(localized: "\(speakerName) is speaking")
        case .approval: String(localized: "Waiting for your approval")
        case .noMicrophone: String(localized: "Microphone is off")
        case .offline: String(localized: "Can't reach \(workspace.bot.name)")
        case .failed: String(localized: "Voice isn't available")
        }
    }

    /// The big line: the person's words, the step running, or the sentence being read.
    var caption: String? {
        switch phase {
        case .listening, .muted, .starting:
            let words = listener.transcript
            return words.isEmpty ? nil : words
        case .thinking:
            return listener.transcript.isEmpty ? currentStep : listener.transcript
        case .speaking:
            return speaker.currentSentence
        case .approval:
            return String(localized: "Say “allow once”, “allow in this chat” or “deny”, or tap below.")
        case .noMicrophone:
            return String(localized: "\(speakerName) needs the microphone and speech recognition to hear you. Speech is turned into text on this device.")
        case .offline:
            return String(localized: "Voice needs a connection to your gateway. What you said is kept as a draft.")
        case .failed(let message):
            return message
        }
    }

    /// The caption is a quieter colour when it describes rather than quotes.
    var captionIsSecondary: Bool {
        switch phase {
        case .thinking: listener.transcript.isEmpty
        case .offline: true
        default: false
        }
    }

    var hint: String? {
        if let approvalHint, phase == .approval { return approvalHint }
        return switch phase {
        case .listening: conversation.isBotChat ? String(localized: "Pause to send") : String(localized: "Pause to send · swipe down to keep it running")
        case .thinking: String(localized: "You can keep talking")
        case .speaking: String(localized: "Tap anywhere to interrupt")
        case .muted: String(localized: "Tap the microphone to talk again")
        default: nil
        }
    }

    /// "Working · checking the NAS": the plan step in progress, else the turn's status line.
    private var workingStatus: String {
        let turn = conversation.liveTurn
        if let item = turn?.plan.first(where: { $0.status == .inProgress }) {
            return String(localized: "Working · \(item.content.prefix(1).lowercased() + item.content.dropFirst())")
        }
        if let status = conversation.liveStatus { return String(localized: "Working · \(status)") }
        return String(localized: "Working")
    }

    /// The step running now ("Running df -h /volume1…").
    private var currentStep: String? {
        guard let turn = conversation.liveTurn else { return nil }
        for step in turn.steps.reversed() {
            if case .tool(let tool) = step, tool.status == .running {
                let title = ToolDescriptor.describe(tool.name).activeTitle
                if let preview = tool.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                    return "\(title) · \(preview.prefix(60))…"
                }
                return "\(title)…"
            }
        }
        return nil
    }

    // MARK: Lifecycle

    func begin() {
        guard loop == nil else { return }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        loop = Task { [weak self] in
            await self?.startListening()
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func end() {
        loop?.cancel()
        loop = nil
        speaker.stop()
        listener.cancel()
        listener.endSession()
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted {
            listener.cancel()
        } else {
            Task { await startListening() }
        }
    }

    /// Tap anywhere while a reply is read: stop reading and listen.
    func interrupt() {
        guard speaker.isSpeaking else { return }
        speaker.stop()
        awaitingReply = false
    }

    /// Offline → Try Again; no microphone after the person fixed Settings.
    func retry() {
        Task {
            if let roster = workspace.roster, conversation.isBotChat || !workspace.connection.isOnline {
                await roster.reconnectNow()
            }
            if !workspace.connection.isOnline { await workspace.connect() }
            phase = .starting
            await startListening()
        }
    }

    func respond(_ choice: ApprovalChoice) {
        guard let approval = conversation.pendingApproval else { return }
        approvalHint = nil
        conversation.respond(to: approval, with: choice)
    }

    // MARK: The loop

    private var isReachable: Bool {
        if conversation.isBotChat { return workspace.roster?.isConnected == true }
        if case .failed = workspace.connection { return conversation.usesGateway }
        return true
    }

    private func startListening() async {
        guard !isMuted, !listener.isActive else { return }
        await listener.start()
        switch listener.state {
        case .denied: phase = .noMicrophone
        case .failed(let message): phase = .failed(message)
        default: break
        }
    }

    private func tick() async {
        if phase == .noMicrophone || isSending { return }
        if case .failed = phase { return }

        streamReply()

        let heard = listener.transcript
        // Barge-in: the person talking over the reply stops it, unless it's the reply's echo.
        if speaker.isSpeaking, Self.wordCount(heard) >= 2, !isEcho(heard) {
            speaker.stop()
            awaitingReply = false
        }
        // The reply ended and all the microphone caught was the reply itself: start clean.
        if !speaker.isSpeaking, !heard.isEmpty, isEcho(heard) {
            listener.cancel()
            recentlySpoken = ""
            await startListening()
        }

        // A pause after some words sends them.
        if listener.state == .listening, !heard.isEmpty, !speaker.isSpeaking,
           let last = listener.lastHeard, Date.now.timeIntervalSince(last) >= Self.pause {
            isSending = true
            let words = await listener.finish()
            deliver(words)
            isSending = false
            await startListening()
        }

        updatePhase()
    }

    private func deliver(_ words: String) {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if conversation.pendingApproval != nil {
            answerApproval(words)
            return
        }
        let wasWorking = conversation.isWorking
        if conversation.sendSpoken(words) {
            if !wasWorking {
                awaitingReply = true
                trackedTurnID = nil
                spokenOffset = 0
            }
        } else {
            phase = .offline
        }
    }

    /// "Allow once", "allow in this chat", "deny". Always Allow still needs a tap.
    private func answerApproval(_ words: String) {
        let said = words.lowercased()
        if said.contains("always") {
            approvalHint = String(localized: "Always Allow needs a tap to confirm.")
        } else if said.contains("deny") || said.contains("don't") || said.hasPrefix("no") || said.contains("stop") {
            respond(.deny)
        } else if said.contains("chat") || said.contains("session") {
            respond(conversation.pendingApproval?.choices.contains(.session) == true ? .session : .once)
        } else if said.contains("allow") || said.contains("once") || said.hasPrefix("yes") || said.contains("go ahead") {
            respond(.once)
        } else {
            approvalHint = String(localized: "Didn't catch that. Say “allow once”, “allow in this chat” or “deny”.")
        }
    }

    /// Queues each finished sentence of the reply for reading as it streams.
    private func streamReply() {
        guard awaitingReply, !isMuted else { return }
        let live = conversation.liveTurn
        guard let turn = live ?? (conversation.isWorking ? nil : conversation.latestAssistantTurn) else { return }
        if trackedTurnID == nil { trackedTurnID = turn.id }
        let answer = turn.answer
        guard spokenOffset <= answer.count else {
            awaitingReply = false
            return
        }
        let start = answer.index(answer.startIndex, offsetBy: spokenOffset)
        let finished = live == nil || live?.state != .streaming && live?.state != .waitingForApproval
        if finished {
            say(String(answer[start...]))
            awaitingReply = false
            if case .failed(let message) = turn.state, answer.isEmpty {
                say(message)
            }
        } else if let boundary = SpeechText.sentenceBoundary(in: answer, from: start) {
            say(String(answer[start..<boundary]))
            spokenOffset = answer.distance(from: answer.startIndex, to: boundary)
        }
    }

    private func say(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if os(macOS)
        guard prefersSpeaker else { return }
        #endif
        recentlySpoken = String((recentlySpoken + " " + trimmed).suffix(600))
        speaker.speak(trimmed)
    }

    private func updatePhase() {
        let next: Phase
        if !isReachable, !conversation.isWorking {
            next = .offline
        } else if conversation.pendingApproval != nil {
            next = .approval
        } else if isMuted {
            next = .muted
        } else if speaker.isSpeaking {
            next = .speaking
        } else if conversation.isWorking || awaitingReply {
            next = .thinking
        } else if listener.state == .listening {
            next = .listening
        } else {
            next = phase == .offline ? .offline : .starting
        }
        guard next != phase else { return }
        phase = next
        if next != .approval { approvalHint = nil }
        AccessibilityNotification.Announcement(status).post()
    }

    // MARK: Echo

    /// Most of what was "heard" is in what was just read aloud.
    private func isEcho(_ heard: String) -> Bool {
        let words = Self.words(heard)
        guard !words.isEmpty, !recentlySpoken.isEmpty else { return false }
        let spoken = Set(Self.words(recentlySpoken))
        let matches = words.filter(spoken.contains).count
        return Double(matches) / Double(words.count) >= 0.6
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func wordCount(_ text: String) -> Int {
        words(text).count
    }
}
