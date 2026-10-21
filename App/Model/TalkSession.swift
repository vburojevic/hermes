import Foundation
import HermesKit
import HermesMarkdown
import LocalAuthentication
import Observation
import SwiftUI

/// A call with Hermes or a Bot (`docs/voice.md` §4, `screens/iphone/talk.elyx`). It lives in
/// `TalkCenter`, not in a screen: leaving the chat, minimising or locking the phone keeps it going.
/// Every turn is a normal message in the chat (marked Spoken), and every reply in the call is read
/// in the Bot's voice.
@MainActor
@Observable
final class TalkSession: Identifiable, TalkDisplay {
    enum Engine: Equatable {
        /// GPT-Live over WebRTC (`docs/voice.md` §4.1).
        case realtime
        /// On-device transcription and endpointing, the Bot's gateway voice.
        case hermesVoice
    }

    enum Phase: Equatable {
        case connecting
        case listening
        /// A turn is running; speaking now steers it.
        case working
        case speaking
        /// Hermes needs an OK: say it, or tap the card.
        case approval
        /// A clarify question, answered by voice.
        case question
        /// A secret, sudo or sign-in: typed on the card, never spoken.
        case needsTyping
        /// A phone call or Siri took the audio.
        case onHold
        case offline
        case noMicrophone
        case failed(String)
    }

    let id = UUID()
    let conversation: ConversationModel
    let workspace: BotWorkspace
    private(set) var engine: Engine = .hermesVoice
    private(set) var phase: Phase = .connecting
    private(set) var startedAt: Date?
    /// A short note above the caption ("Switched to Hermes Voice"), for 6 s.
    private(set) var notice: String? {
        didSet {
            guard let notice else { return }
            noticeClear?.cancel()
            noticeClear = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, self?.notice == notice else { return }
                self?.notice = nil
            }
        }
    }
    @ObservationIgnored private var noticeClear: Task<Void, Never>?
    var showsCaptions = UserDefaults.standard.object(forKey: "voiceCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsCaptions, forKey: "voiceCaptions") }
    }
    /// iPhone: the loudspeaker rather than the earpiece. Mac: replies are read aloud.
    var prefersSpeaker = true {
        didSet {
            guard prefersSpeaker != oldValue else { return }
            #if os(iOS)
            Task { await voice.setSpeaker(prefersSpeaker) }
            #else
            if !prefersSpeaker { Task { await voice.stopSpeaking() } }
            #endif
        }
    }
    /// A line under the caption after a spoken answer that needs a tap ("Always Allow").
    private(set) var approvalHint: String?
    /// From the end of speech to the first audio of the reply, for the debug overlay
    /// (`docs/voice.md` §12).
    private(set) var lastLatency: TimeInterval?
    private(set) var spokenTurns = 0
    private(set) var approvalsAnswered = 0
    private(set) var stepsRun = 0

    let voice = HermesVoiceEngine()
    /// Realtime, while it carries the call.
    private(set) var realtime: RealtimeTalk?

    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    /// The reply being read, by turn id (`docs/voice.md` §11).
    @ObservationIgnored private var reply: SpokenReplyTracker?
    /// Turns sent during the call whose replies haven't started being read.
    @ObservationIgnored private var expectedReplies = 0
    @ObservationIgnored private var lastSentTurns = 0
    /// Every assistant turn known when its reply would have been read, so none is read twice.
    @ObservationIgnored private var knownTurns: Set<String> = []
    @ObservationIgnored private var interruptedReply = false
    /// The reply being followed has started to be read (barging in then stops it).
    @ObservationIgnored private var replyStarted = false
    @ObservationIgnored private var shownApproval: (id: String, since: Date)?
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var clarifying: (request: HermesRequest, answers: [String: JSONValue], step: Int)?
    /// Tools already given a spoken note ("Checking the NAS.").
    @ObservationIgnored private var notedSteps: Set<String> = []
    @ObservationIgnored private var stepNote: Task<Void, Never>?
    @ObservationIgnored private var speechEndedAt: TimeInterval?
    @ObservationIgnored private var ended = false
    /// Realtime's delegation being worked on, and how much of its reply has gone back.
    @ObservationIgnored private var delegation: (id: String, turnID: String?, sent: Int, lastTool: String?)?

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

    /// When the gateway can't speak, the call answers in this device's voice and says why; when
    /// it can't transcribe (Transcribe on: The gateway), the device hears the words and it says why.
    var setupNote: SetupStatus? {
        let setup = VoiceSetup.of(workspace)
        if transcribesOnDevice, let status = setup.status("transcription", profile: conversation.botName), status.state == .limited {
            return status
        }
        guard setup.gatewaySpeaks(profile: conversation.botName) == false else { return nil }
        return setup.status("talk", profile: conversation.botName)
    }

    /// The person chose the gateway's transcription, but this call hears on the device.
    private(set) var transcribesOnDevice = false

    var botAppearance: BotAppearance? {
        if let name = conversation.botName, let roster = workspace.roster, let bot = roster.bot(named: name) {
            return roster.appearance(for: bot)
        }
        return nil
    }

    /// "Realtime" or the Bot's voice, for the header ("2:14 · Realtime").
    var engineName: String {
        engine == .realtime ? String(localized: "Realtime") : String(localized: "Hermes Voice")
    }

    var route: AudioRoute { voice.route }
    var heard: String { voice.heard }
    var chat: ConversationModel? { conversation }

    /// The call's lines so far, for the transcript sheet.
    var transcriptLines: [TalkLine] {
        let since = (startedAt ?? .now).addingTimeInterval(-2)
        return conversation.rows.compactMap { item in
            switch item {
            case .user(let entry):
                guard (entry.timestamp ?? .now) >= since else { return nil }
                return TalkLine(id: entry.id, isUser: true, text: entry.text)
            case .assistant(let turn):
                guard (turn.startedAt ?? .now) >= since, !turn.answer.isEmpty else { return nil }
                return TalkLine(id: turn.id, isUser: false, text: MarkdownDocument(parsing: turn.answer).spokenScript(descriptions: .app).text)
            default:
                return nil
            }
        }
    }

    var isMuted: Bool { voice.isMuted }
    var inputLevel: Float { realtime?.inputLevel ?? voice.inputLevel }
    var outputLevel: Float { realtime?.outputLevel ?? voice.outputLevel }
    var isHearingSpeech: Bool { voice.isHearingSpeech }
    private var isSpeaking: Bool { realtime?.isSpeaking ?? voice.isSpeaking }

    /// The state's name under the face.
    var status: String {
        switch phase {
        case .connecting:
            if let progress = voice.downloadProgress {
                return String(localized: "Downloading speech model · \(Int(progress * 100))%")
            }
            return String(localized: "Connecting")
        case .listening: return isMuted ? String(localized: "Muted") : String(localized: "Listening")
        case .working: return String(localized: "Working")
        case .speaking: return String(localized: "Speaking")
        case .approval: return String(localized: "Needs your OK")
        case .question: return String(localized: "Question")
        case .needsTyping: return String(localized: "Needs you to type")
        case .onHold: return String(localized: "On hold")
        case .offline: return String(localized: "Can't reach \(workspace.bot.name)")
        case .noMicrophone: return String(localized: "Microphone is off")
        case .failed: return String(localized: "Talk stopped")
        }
    }

    /// The big words: settled, then still changing (lighter). While speaking, the sentence being
    /// said, then the next one (lighter).
    var caption: (settled: String, lighter: String)? {
        switch phase {
        case .listening, .connecting:
            if isMuted, let at = voice.mutedSpeechAt, Date.now.timeIntervalSince(at) < 3 {
                return (String(localized: "You're muted"), "")
            }
            if let realtime { return realtime.heard.isEmpty ? nil : (realtime.heard, "") }
            let settled = voice.heardFinal.trimmingCharacters(in: .whitespaces)
            let changing = voice.heardVolatile.trimmingCharacters(in: .whitespaces)
            guard SpokenAnswers.hasWords(settled + changing) else { return nil }
            return (settled, settled.isEmpty ? changing : " " + changing)
        case .working:
            if SpokenAnswers.hasWords(voice.heard) { return (voice.heard, "") }
            return workingLine.map { ("", $0) }
        case .speaking:
            if let realtime { return realtime.saying.isEmpty ? nil : (String(realtime.saying.suffix(160)), "") }
            guard let player = voice.player, let index = player.current, index < player.queued.count else { return nil }
            let next = index + 1 < player.queued.count ? " " + player.queued[index + 1].text : ""
            return (player.queued[index].text, next)
        case .approval:
            return (String(localized: "I need your OK to \(approvalSubject)."), "")
        case .question:
            return clarifyingQuestion.map { ($0, "") }
        case .needsTyping:
            return (String(localized: "I need you to type that. It's on the card below."), "")
        case .onHold:
            return ("", String(localized: "The call carries on when the other audio ends."))
        case .offline:
            return ("", String(localized: "Talk needs a connection to your gateway. What you said is kept as a draft."))
        case .noMicrophone:
            return ("", String(localized: "\(speakerName) needs the microphone to hear you. Speech is turned into text on this device."))
        case .failed(let message):
            return ("", message)
        }
    }

    var hint: String? {
        if let approvalHint, phase == .approval { return approvalHint }
        return switch phase {
        case .listening: isMuted ? String(localized: "Tap Mute to talk again") : String(localized: "Pause when you're done")
        case .working: String(localized: "Keep talking to steer")
        case .speaking: String(localized: "Talk or tap to interrupt")
        case .approval: String(localized: "Say “allow once” or “deny”")
        case .question: String(localized: "Say your answer, or tap it")
        default: nil
        }
    }

    /// The step running now and since when ("df -h /volume1 · 3 s"), while working.
    var runningStep: (title: String, since: Date)? {
        guard phase == .working, let turn = conversation.liveTurn else { return nil }
        for step in turn.steps.reversed() {
            if case .tool(let tool) = step, tool.status == .running {
                let preview = tool.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (preview.isEmpty ? ToolDescriptor.describe(tool.name).activeTitle : String(preview.prefix(48)), tool.startedAt ?? .now)
            }
        }
        return nil
    }

    /// A table or code the reply put in the chat, shown above the controls ("Hermes showed you a
    /// card") while the call goes on, as Markdown.
    var card: String? {
        guard let turn = conversation.liveTurn ?? conversation.latestAssistantTurn, !knownAtStart.contains(turn.id) else { return nil }
        return Self.lastCard(in: turn.answer)
    }

    /// The last fenced code block or table in a reply.
    static func lastCard(in answer: String) -> String? {
        let lines = answer.components(separatedBy: "\n")
        var cards: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("```") { end += 1 }
                guard end < lines.count else { break }
                cards.append(lines[index...end].joined(separator: "\n"))
                index = end + 1
            } else if line.hasPrefix("|") {
                var end = index
                while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|") { end += 1 }
                if end > index { cards.append(lines[index...end].joined(separator: "\n")) }
                index = end + 1
            } else {
                index += 1
            }
        }
        return cards.last
    }

    /// The face: the Bot's, or Hermes's (the main profile's violet squircle).
    var figureAppearance: BotAppearance {
        if let botAppearance { return botAppearance }
        if let roster = workspace.roster, let main = roster.visibleBots.first(where: \.isDefault) { return roster.appearance(for: main) }
        return BotAppearance(profile: "hermes")
    }

    var pendingApproval: ApprovalRequest? { conversation.pendingApproval }
    /// The request on the card while one waits (a secret, a sign-in), docked in the call.
    var pendingRequest: HermesRequest? { conversation.requests.first }

    @ObservationIgnored private var knownAtStart: Set<String> = []

    private var approvalSubject: String {
        guard let approval = conversation.pendingApproval else { return String(localized: "go on") }
        if let description = approval.description, !description.isEmpty {
            return description.prefix(1).lowercased() + description.dropFirst()
        }
        return String(localized: "run a command")
    }

    private var clarifyingQuestion: String? {
        guard let clarifying else { return nil }
        switch clarifying.request.kind {
        case .clarify(let questions): return questions[min(clarifying.step, questions.count - 1)].question
        case .choose(let choice): return choice.question
        default: return nil
        }
    }

    /// "Checking the NAS, then the snapshots.": the plan step in progress, else the turn's status.
    private var workingLine: String? {
        let turn = conversation.liveTurn
        if let item = turn?.plan.first(where: { $0.status == .inProgress }) { return item.content }
        return conversation.liveStatus
    }

    // MARK: Lifecycle

    func begin() {
        guard watchers.isEmpty, !ended else { return }
        startedAt = .now
        // What voice the gateway has, so the call can say why if it falls back.
        Task { [workspace, conversation] in await VoiceSetup.of(workspace).checkIfStale(profile: conversation.botName) }
        lastSentTurns = conversation.sentTurns
        knownTurns = Set(conversation.rows.compactMap { item -> String? in
            if case .assistant(let turn) = item { return turn.id }
            return nil
        })
        if let live = conversation.liveTurn, live.state != .streaming, live.state != .waitingForApproval { knownTurns.insert(live.id) }
        knownAtStart = knownTurns
        if conversation.isWorking { expectedReplies = 1 }
        voice.onTurn = { [weak self] words, endedAt in self?.deliver(words, endedAt: endedAt) }
        voice.onBargeIn = { [weak self] in self?.bargedIn() }
        voice.onFirstAudio = { [weak self] at in self?.firstAudio(at: at) }
        voice.onInterruption = { [weak self] began in self?.interruption(began) }
        voice.onVoiceFellBack = { [weak self] why in
            guard let self else { return }
            VoiceSetup.of(self.workspace).noteSpeechFailure(why, profile: self.conversation.botName)
        }
        voice.onTranscriptionFellBack = { [weak self] why in
            guard let self else { return }
            self.transcribesOnDevice = true
            VoiceSetup.of(self.workspace).noteTranscriptionFailure(why, profile: self.conversation.botName)
        }
        voice.pause = TalkPreferences.pause
        watchers = [
            Task { [weak self] in await self?.startEngine() },
            Task { [weak self] in
                guard let conversation = self?.conversation else { return }
                // The reply, approvals and requests: followed as they change, never polled.
                let changes = Observations { [conversation] in
                    ConversationSnapshot(
                        live: conversation.liveTurn, latest: conversation.latestAssistantTurn,
                        approval: conversation.pendingApproval?.id, requests: conversation.requests.map(\.id),
                        isWorking: conversation.isWorking, sentTurns: conversation.sentTurns, status: conversation.liveStatus
                    )
                }
                for await snapshot in changes {
                    guard let self, !self.ended else { return }
                    self.follow(snapshot)
                }
            },
            Task { [weak self] in
                guard let voice = self?.voice else { return }
                let changes = Observations { [weak self, voice] in
                    EngineSnapshot(state: voice.state, speaking: self?.realtime?.isSpeaking ?? voice.isSpeaking, muted: voice.isMuted,
                                   interrupted: voice.isInterrupted)
                }
                for await _ in changes {
                    guard let self, !self.ended else { return }
                    self.updatePhase()
                }
            },
        ]
    }

    /// Ends the call: what's said stops, the audio goes back, and the call is summed up.
    @discardableResult
    func end() -> CallRecord? {
        guard !ended else { return nil }
        ended = true
        watchers.forEach { $0.cancel() }
        watchers = []
        stepNote?.cancel()
        reply = nil
        realtime?.close()
        let backend = conversation.audioBackend
        Task {
            await voice.stopSpeaking()
            voice.cue(.end)
            try? await Task.sleep(for: .milliseconds(250))
            await voice.stop()
            if let backend { await backend.client.ttsLease("app:talk", active: false, profile: backend.profile) }
        }
        guard let startedAt else { return nil }
        return CallRecord(
            id: id, session: conversation.sessionID, botName: conversation.botName, title: speakerName,
            startedAt: startedAt, endedAt: .now, turns: spokenTurns, approvals: approvalsAnswered, steps: stepsRun
        )
    }

    /// Mute is the microphone only: the Bot carries on, and unmuting carries on from there.
    func toggleMute() {
        voice.setMuted(!voice.isMuted)
        realtime?.setMuted(voice.isMuted)
        updatePhase()
    }

    /// A tap while the Bot speaks: stop it, and stop the turn if it's still writing.
    func interrupt() {
        guard voice.isSpeaking, realtime == nil else { return }
        Task { await voice.stopSpeaking(fade: true) }
        bargedIn()
    }

    /// Offline or failed → Try Again; no microphone after the person fixed Settings.
    func retry() {
        Task {
            if let roster = workspace.roster, conversation.isBotChat || !workspace.connection.isOnline {
                await roster.reconnectNow()
            }
            if !workspace.connection.isOnline { await workspace.connect() }
            phase = .connecting
            if voice.state != .running { await startEngine() }
            updatePhase()
        }
    }

    /// An answer tapped on the approval card. Always Allow, a flagged command and anything that
    /// can't be undone ask for Face ID first (`docs/voice.md` §4.3).
    func respond(_ choice: ApprovalChoice) {
        guard let approval = conversation.pendingApproval else { return }
        // A card fill's own card asked for Face ID already (`PaymentApprovalCard`).
        let risky = choice != .deny && !approval.isPaymentFill && (choice == .always || approval.smartDenied || SpokenAnswers.isIrreversible(approval))
        Task {
            if risky, !(await Self.confirmWithOwner(String(localized: "Allow \(speakerName) to go ahead"))) { return }
            approvalHint = nil
            approvalsAnswered += 1
            conversation.respond(to: approval, with: choice)
        }
    }

    // MARK: Engine

    private func startEngine() async {
        // Bot Mode still connecting (a cold launch): the Bot's voice and Realtime come from it,
        // so give it a moment.
        if conversation.audioBackend == nil, let roster = workspace.roster, !roster.isConnected {
            for _ in 0..<20 where !roster.isConnected && !ended {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        let backend = conversation.audioBackend
        if let backend { await backend.client.ttsLease("app:talk", active: true, profile: backend.profile) }
        if let backend, TalkPreferences.engine == .realtime,
           (try? await backend.client.voiceLiveStatus(profile: backend.profile))?.isRealtime == true,
           await startRealtime(backend: backend) {
            return
        }
        await startHermesVoice()
    }

    private func startHermesVoice() async {
        engine = .hermesVoice
        let backend = conversation.audioBackend
        let device = DeviceVoice(language: DeviceVoice.language(of: conversation.latestAssistantTurn?.answer ?? ""))
        let gateway = backend.map { GatewayVoice(backend: $0.client, profile: $0.profile) }
        let transcription = await gatewayTranscription(backend)
        if voice.state == .running {
            // Taking over from Realtime: the audio is already ours.
            await voice.listen(voice: gateway ?? device, fallback: gateway == nil ? nil : device, contextualStrings: contextualStrings,
                               transcription: transcription)
        } else {
            await voice.start(voice: gateway ?? device, fallback: gateway == nil ? nil : device,
                              contextualStrings: contextualStrings, speaker: prefersSpeaker, transcription: transcription)
        }
        if voice.state == .running { voice.cue(.start) }
        updatePhase()
    }

    /// Transcribe on: The gateway, when the gateway says it can transcribe as you speak
    /// (voice-config `stt.streaming`). Otherwise the device hears the words and the call says why.
    private func gatewayTranscription(_ backend: (client: BackendClient, profile: String?)?) async -> HermesVoiceEngine.GatewayTranscription? {
        guard TalkPreferences.transcribeOn == .gateway else { return nil }
        guard let backend, (try? await backend.client.voiceConfig(profile: backend.profile))?.stt.streaming == true else {
            transcribesOnDevice = true
            await VoiceSetup.of(workspace).check(profile: conversation.botName)
            return nil
        }
        return HermesVoiceEngine.GatewayTranscription(backend: backend.client, profile: backend.profile)
    }

    /// Realtime: the call's audio through WebRTC to GPT-Live. `false` when it can't start, so the
    /// call goes on as Hermes Voice.
    private func startRealtime(backend: (client: BackendClient, profile: String?)) async -> Bool {
        guard let graph = await voice.acquireForRealtime(speaker: prefersSpeaker) else { return voice.state == .denied }
        let realtime = RealtimeTalk()
        realtime.onDelegation = { [weak self] id, prompt, context in self?.delegated(id, prompt: prompt, context: context) }
        realtime.onEnded = { [weak self] reason in self?.realtimeEnded(reason) }
        self.realtime = realtime
        engine = .realtime
        do {
            try await realtime.start(graph: graph, backend: backend.client, profile: backend.profile, history: realtimeHistory)
        } catch {
            TalkCenter.logger.error("realtime didn't start: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            self.realtime = nil
            notice = String(localized: "Realtime couldn't connect. Using Hermes Voice.")
            return false
        }
        if !UserDefaults.standard.bool(forKey: TalkPreferences.Key.realtimeExplained) {
            // Said once: Realtime's audio goes to OpenAI (`docs/voice.md` §8).
            UserDefaults.standard.set(true, forKey: TalkPreferences.Key.realtimeExplained)
            notice = String(localized: "Realtime: your voice goes to OpenAI through your gateway's key.")
        }
        voice.cue(.start)
        updatePhase()
        return true
    }

    /// Realtime dropped mid-call: the call carries on as Hermes Voice.
    private func realtimeEnded(_ reason: String) {
        guard !ended, realtime != nil else { return }
        realtime = nil
        delegation = nil
        notice = String(localized: "Switched to Hermes Voice")
        Task { await startHermesVoice() }
    }

    /// The recent chat as GPT-Live items: the newest 24 messages, 6000 characters in all, each cut
    /// to 1200 (as Hermes Desktop sends it).
    private var realtimeHistory: [JSONValue] {
        var items: [JSONValue] = []
        var size = 0
        for item in conversation.rows.suffix(24).reversed() {
            let (role, text): (String, String)
            switch item {
            case .user(let entry): (role, text) = ("user", entry.text)
            case .assistant(let turn): (role, text) = ("assistant", MarkdownDocument(parsing: turn.answer).spokenScript(descriptions: .app).text)
            default: continue
            }
            let cut = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
            guard !cut.isEmpty, size + cut.count <= 6000 else { continue }
            size += cut.count
            items.append(.object([
                "type": .string("message"), "role": .string(role),
                "content": .array([.object(["type": .string(role == "user" ? "input_text" : "output_text"), "text": .string(cut)])]),
            ]))
        }
        return items.reversed()
    }

    /// GPT-Live asked Hermes to act: what the person said becomes a turn (a newer request
    /// supersedes one still running), and its progress and reply go back to the voice.
    private func delegated(_ id: String, prompt: String, context: String) {
        if BargeInDetector.isStopPhrase(prompt), prompt.split(separator: " ").count <= 2 {
            TalkCenter.shared.end()
            return
        }
        if conversation.isWorking { conversation.stop() }
        delegation = (id, nil, 0, nil)
        if conversation.sendSpoken(prompt, voice: VoiceTurn(isVoiceTurn: false, context: context)) {
            spokenTurns += 1
        } else {
            realtime?.speak(id, String(localized: "Sorry, I could not reach Hermes for that request."))
            delegation = nil
        }
        updatePhase()
    }

    /// The delegated turn's tools and reply, back to the voice as they happen.
    private func followDelegation(_ snapshot: ConversationSnapshot) {
        guard let realtime, var current = delegation else { return }
        // The live turn, or the stored row it became when it finished.
        guard let turn = snapshot.live ?? (snapshot.isWorking ? nil : snapshot.latest) else { return }
        if let tracked = current.turnID, tracked != turn.id {
            guard snapshot.live == nil, tracked.hasPrefix("live-"), !knownTurns.contains(turn.id) else { return }
        } else if current.turnID == nil, knownTurns.contains(turn.id) {
            return
        }
        current.turnID = current.turnID ?? turn.id
        for step in turn.steps.reversed() {
            if case .tool(let tool) = step, tool.status == .running {
                let title = ToolDescriptor.describe(tool.name).activeTitle
                if title != current.lastTool {
                    current.lastTool = title
                    realtime.think(current.id, "Hermes is working: \(title). Not done yet.")
                }
                break
            }
        }
        let spoken = MarkdownDocument(parsing: turn.answer).spokenScript(detail: TalkPreferences.codeAndTables, descriptions: .app).text
        let finished = turn.state != .streaming && turn.state != .waitingForApproval
        if !finished {
            // Whole sentences while it streams; the rest when it settles.
            if let boundary = spoken.range(of: ". ", options: .backwards)?.upperBound {
                let cut = spoken.distance(from: spoken.startIndex, to: boundary)
                if cut > current.sent {
                    realtime.speak(current.id, String(spoken.dropFirst(current.sent).prefix(cut - current.sent)))
                    current.sent = cut
                }
            }
            delegation = current
            return
        }
        if spoken.count > current.sent {
            realtime.speak(current.id, String(spoken.dropFirst(current.sent)))
        } else if current.sent == 0 {
            realtime.think(current.id, "Hermes finished that request without a spoken result.")
        }
        knownTurns.insert(turn.id)
        if let tracked = current.turnID { knownTurns.insert(tracked) }
        delegation = nil
    }

    /// Bot names, projects and skills, so the transcriber spells them right.
    private var contextualStrings: [String] {
        SpeechVocabulary.words(workspace: workspace, conversation: conversation)
    }

    private var isReachable: Bool {
        if conversation.isBotChat { return workspace.roster?.isConnected == true }
        if case .failed = workspace.connection { return conversation.usesGateway }
        return true
    }

    // MARK: Turns

    private func deliver(_ words: String, endedAt: TimeInterval) {
        // Noise the transcriber wrote down as "." is nobody's turn.
        guard SpokenAnswers.hasWords(words) else { return }
        noteShownApproval()
        if let approval = conversation.pendingApproval {
            answer(approval, with: words)
            return
        }
        if clarifying != nil {
            answerClarify(with: words)
            return
        }
        if conversation.requests.contains(where: { !Self.canAnswerByVoice($0) }) {
            // Secrets, sudo and sign-ins are typed, never spoken.
            say(String(localized: "I need you to type that. It's on the card."))
            return
        }
        if BargeInDetector.isStopPhrase(words), words.split(separator: " ").count <= 3 {
            // "Stop" is said to the call, not to Hermes: it stopped the voice already, and it
            // stops a turn still working. It isn't sent as a message.
            if conversation.isWorking, conversation.pendingApproval == nil { conversation.stop() }
            return
        }
        let voiceTurn = VoiceTurn(context: voiceContext, interrupted: interruptedReply)
        if conversation.sendSpoken(words, voice: voiceTurn) {
            interruptedReply = false
            spokenTurns += 1
            speechEndedAt = endedAt
            voice.cue(.sent)
        } else {
            phase = .offline
        }
    }

    /// The recent spoken exchange, for `voice_context`.
    private var voiceContext: String {
        let lines: [(isUser: Bool, text: String)] = conversation.rows.suffix(24).compactMap { item in
            switch item {
            case .user(let entry): (true, entry.text)
            case .assistant(let turn): (false, MarkdownDocument(parsing: turn.answer).spokenScript().text)
            default: nil
            }
        }
        return VoiceTurn.context(lines)
    }

    /// The person talked over the reply: stop reading it, and stop the turn if it's still writing
    /// (`session.interrupt`). The next turn says it was cut off.
    private func bargedIn() {
        // Talking over an ask (an approval, a question, a step note) only stops the ask: the
        // reply still comes, and is read.
        guard replyStarted else {
            updatePhase()
            return
        }
        if let tracked = reply?.trackedTurnID { knownTurns.insert(tracked) }
        reply = nil
        replyStarted = false
        interruptedReply = true
        if conversation.isWorking, conversation.pendingApproval == nil { conversation.stop() }
        updatePhase()
    }

    private func firstAudio(at uptime: TimeInterval) {
        guard let ended = speechEndedAt else { return }
        let latency = uptime - ended
        lastLatency = latency
        speechEndedAt = nil
        TalkCenter.logger.info("first audio \(Int(latency * 1000)) ms after the end of speech (\(self.engineName, privacy: .public))")
    }

    private func interruption(_ began: Bool) {
        // After a real phone call the call carries on with a tone.
        if !began { voice.cue(.start) }
        updatePhase()
    }

    // MARK: Following the chat

    private func follow(_ snapshot: ConversationSnapshot) {
        if snapshot.sentTurns > lastSentTurns {
            // A turn was sent during the call (spoken, or typed into the call): read its reply.
            expectedReplies += snapshot.sentTurns - lastSentTurns
            lastSentTurns = snapshot.sentTurns
        }
        if realtime != nil {
            followDelegation(snapshot)
            expectedReplies = 0
        } else {
            followReply(snapshot)
            followSteps(snapshot)
        }
        followRequests()
        updatePhase()
    }

    private func followReply(_ snapshot: ConversationSnapshot) {
        if reply == nil, expectedReplies > 0, let live = snapshot.live, !knownTurns.contains(live.id) {
            expectedReplies -= 1
            reply = SpokenReplyTracker(earlierTurnIDs: knownTurns, detail: TalkPreferences.codeAndTables, descriptions: .app)
            replyStarted = false
        }
        guard var tracker = reply else { return }
        guard let turn = snapshot.live ?? (snapshot.isWorking ? nil : snapshot.latest) else { return }
        let finished = turn.state != .streaming && turn.state != .waitingForApproval
        var failure: String?
        if case .failed(let message) = turn.state { failure = message }
        // A finished turn leaves `live` and comes back as a stored row with its own id: the same
        // reply, read on from where it was.
        let sentences = tracker.update(turnID: turn.id, answer: turn.answer, isFinished: finished, failure: failure, settled: snapshot.live == nil)
        if let tracked = tracker.trackedTurnID { knownTurns.insert(tracked) }
        reply = tracker.isDone ? nil : tracker
        #if os(macOS)
        guard prefersSpeaker else { return }
        #endif
        if !sentences.isEmpty { replyStarted = true }
        voice.speak(sentences)
        if tracker.isDone {
            voice.finishSpeaking()
            replyStarted = false
        }
    }

    /// Steps longer than 4 s get a short spoken note, once ("Running a command.").
    private func followSteps(_ snapshot: ConversationSnapshot) {
        guard let turn = snapshot.live else { return }
        for step in turn.steps {
            guard case .tool(let tool) = step else { continue }
            if tool.status != .running, !notedSteps.contains(tool.id) {
                notedSteps.insert(tool.id)
                stepsRun += 1
            }
            guard tool.status == .running, !notedSteps.contains("note:" + tool.id) else { continue }
            notedSteps.insert("note:" + tool.id)
            let title = ToolDescriptor.describe(tool.name).activeTitle
            let id = tool.id
            stepNote?.cancel()
            stepNote = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, !self.voice.isSpeaking else { return }
                let stillRunning = self.conversation.liveTurn?.steps.contains { step in
                    if case .tool(let tool) = step { tool.id == id && tool.status == .running } else { false }
                } ?? false
                if stillRunning { self.say(title + ".") }
            }
        }
    }

    private func say(_ line: String) {
        #if os(macOS)
        guard prefersSpeaker else { return }
        #endif
        voice.speak([SpokenSentence(text: line, block: 0, range: 0..<0)])
        voice.finishSpeaking()
    }

    // MARK: Approvals and questions

    private func answer(_ approval: ApprovalRequest, with words: String) {
        let shownFor = shownApproval.map { Date.now.timeIntervalSince($0.since) } ?? 0
        switch SpokenAnswers.approval(words, for: approval, shownFor: shownFor) {
        case .allow(let choice):
            approvalHint = nil
            approvalsAnswered += 1
            conversation.respond(to: approval, with: choice)
        case .deny:
            approvalHint = nil
            approvalsAnswered += 1
            conversation.respond(to: approval, with: .deny)
        case .needsTap(.always):
            approvalHint = String(localized: "Always Allow needs a tap and Face ID.")
        case .needsTap(.flagged):
            approvalHint = String(localized: "Hermes flagged this command. Tap Run Once Anyway on the card if you trust it, or say “deny”.")
        case .needsTap(.irreversible):
            approvalHint = String(localized: "This can't be undone, so it needs a tap and Face ID. Or say “deny”.")
        case .needsTap(.cardFill):
            approvalHint = String(localized: "Filling your card needs Fill Card on the card and Face ID. Or say “don't fill”.")
        case .tooSoon:
            approvalHint = String(localized: "Take a moment to read it, then say “allow once” or “deny”.")
        case .notUnderstood:
            approvalHint = String(localized: "Didn't catch that. Say “allow once”, “allow in this chat” or “deny”.")
        }
    }

    private func noteShownApproval() {
        guard let id = conversation.pendingApproval?.id else { shownApproval = nil; return }
        if shownApproval?.id != id { shownApproval = (id, .now) }
    }

    static func canAnswerByVoice(_ request: HermesRequest) -> Bool {
        switch request.kind {
        case .clarify, .choose: true
        default: false
        }
    }

    /// New approvals and requests are said once: the ask, a question with its choices, or "type
    /// that" for secrets (never their content).
    private func followRequests() {
        if let approval = conversation.pendingApproval, !announced.contains(approval.id) {
            announced.insert(approval.id)
            say(String(localized: "I need your OK to \(approvalSubject)."))
        }
        for request in conversation.requests where !announced.contains(request.id) {
            announced.insert(request.id)
            switch request.kind {
            case .clarify(let questions):
                guard clarifying == nil, let first = questions.first else { continue }
                clarifying = (request, [:], 0)
                say(Self.spoken(first))
            case .choose(let choice):
                guard clarifying == nil else { continue }
                clarifying = (request, [:], 0)
                say(choice.question + " " + Self.listing(choice.options.map(\.label)))
            default:
                say(String(localized: "I need you to type something. It's on the card."))
            }
        }
        if let current = clarifying, !conversation.requests.contains(where: { $0.id == current.request.id }) {
            clarifying = nil  // answered on the card
        }
    }

    private func answerClarify(with words: String) {
        guard var current = clarifying else { return }
        switch current.request.kind {
        case .clarify(let questions):
            let question = questions[current.step]
            if let index = SpokenAnswers.choice(words, among: question.choices.map(Self.label)) {
                current.answers[question.id] = question.multiSelect ? .array([.string(question.choices[index])]) : .string(question.choices[index])
            } else {
                current.answers[question.id] = .string(words)
            }
            if current.step + 1 < questions.count {
                current.step += 1
                clarifying = current
                say(Self.spoken(questions[current.step]))
            } else {
                clarifying = nil
                let given = questions.compactMap { current.answers[$0.id]?.stringValue.map(Self.label) }
                conversation.answer(current.request, with: .object(["answers": .object(current.answers)]),
                                    receipt: String(localized: "Answered · \(given.joined(separator: " · "))"))
            }
        case .choose(let choice):
            guard let index = SpokenAnswers.choice(words, among: choice.options.map(\.label)) else {
                say(String(localized: "Which one? \(Self.listing(choice.options.map(\.label)))"))
                return
            }
            clarifying = nil
            let option = choice.options[index]
            conversation.answer(current.request, with: .object(["picked": choice.multiSelect ? .array([.string(option.id)]) : .string(option.id)]),
                                receipt: String(localized: "Answered · \(option.label)"))
        default:
            clarifying = nil
        }
        updatePhase()
    }

    /// "Which database? Staging, Production, or A local copy?"
    static func spoken(_ question: HermesRequest.Question) -> String {
        question.choices.isEmpty ? question.question : question.question + " " + listing(question.choices.map(label))
    }

    /// "Staging — Safe to reset" → "Staging": the part of a choice worth saying.
    static func label(_ choice: String) -> String {
        for separator in [" — ", " – ", ": ", "\n"] {
            if let range = choice.range(of: separator) { return String(choice[..<range.lowerBound]) }
        }
        return choice
    }

    static func listing(_ options: [String]) -> String {
        guard options.count > 1 else { return options.first.map { $0 + "?" } ?? "" }
        return options.dropLast().joined(separator: ", ") + String(localized: ", or ") + options[options.count - 1] + "?"
    }

    /// Face ID (or the passcode, or Touch ID on a Mac) before a risky allow. A device without a
    /// passcode has nothing to ask, so the tap is enough.
    static func confirmWithOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return (error as? LAError)?.code == .passcodeNotSet
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    // MARK: Phase

    private func updatePhase() {
        noteShownApproval()
        let next: Phase
        switch voice.state {
        case .denied: next = .noMicrophone
        case .failed(let message): next = .failed(message)
        case .idle, .starting: next = .connecting
        case .running:
            if voice.isInterrupted {
                next = .onHold
            } else if !isReachable, !conversation.isWorking {
                next = .offline
            } else if conversation.pendingApproval != nil {
                next = .approval
            } else if isSpeaking {
                next = .speaking
            } else if clarifying != nil {
                next = .question
            } else if conversation.requests.contains(where: { !Self.canAnswerByVoice($0) }) {
                next = .needsTyping
            } else if conversation.isWorking || reply != nil || expectedReplies > 0 || delegation != nil {
                next = .working
            } else {
                next = .listening
            }
        }
        guard next != phase else { return }
        phase = next
        if next != .approval { approvalHint = nil }
        // VoiceOver announces each state ("Listening", "Hermes is speaking").
        let spoken = next == .speaking ? String(localized: "\(speakerName) is speaking") : status
        AccessibilityNotification.Announcement(spoken).post()
        TalkCenter.shared.sessionChanged(self)
    }
}

/// What the reply follower reacts to.
private struct ConversationSnapshot: Equatable {
    var live: AssistantTurn?
    var latest: AssistantTurn?
    var approval: String?
    var requests: [String]
    var isWorking: Bool
    var sentTurns: Int
    var status: String?
}

private struct EngineSnapshot: Equatable {
    var state: HermesVoiceEngine.State
    var speaking: Bool
    var muted: Bool
    var interrupted: Bool
}

/// A call that ended, folded into one card in its chat (`callSummary`, `docs/voice.md` §4.3).
struct CallRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var session: String?
    var botName: String?
    var title: String
    var startedAt: Date
    var endedAt: Date
    var turns: Int
    var approvals: Int
    var steps: Int
    /// What was done: Hermes's last reply when it summed up, or Apple Intelligence's summary.
    var summary: String?
    var summaryByDevice = false

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// What the Talk views read (`TalkScreen`, `TalkPanel`, `CallPill`): a call, or a staged one in the
/// design gallery.
@MainActor
protocol TalkDisplay: AnyObject, Observable {
    var phase: TalkSession.Phase { get }
    var speakerName: String { get }
    var figureAppearance: BotAppearance { get }
    var engineName: String { get }
    var startedAt: Date? { get }
    var status: String { get }
    var caption: (settled: String, lighter: String)? { get }
    var hint: String? { get }
    var notice: String? { get }
    /// Why the call can't use the gateway's voice, with how to set it up (`docs/voice.md` §6.1).
    var setupNote: SetupStatus? { get }
    var showsCaptions: Bool { get set }
    var isMuted: Bool { get }
    var inputLevel: Float { get }
    var outputLevel: Float { get }
    var runningStep: (title: String, since: Date)? { get }
    var card: String? { get }
    var pendingApproval: ApprovalRequest? { get }
    var pendingRequest: HermesRequest? { get }
    var chat: ConversationModel? { get }
    var route: AudioRoute { get }
    var heard: String { get }
    var transcriptLines: [TalkLine] { get }
    func toggleMute()
    func interrupt()
    func retry()
    func respond(_ choice: ApprovalChoice)
}

struct TalkLine: Identifiable, Hashable {
    var id: String
    var isUser: Bool
    var text: String
}
