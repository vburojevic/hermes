import Foundation
import Testing
@testable import HermesKit

/// Every way a message reaches Hermes against every state a chat can be in, at the model level
/// (`docs/development.md`, the send matrix; `docs/chat.md` §4c, §4d; `docs/follow-ups.md` §4).
/// Each cell feeds the gateway's answer for that state, shaped like Hermes's own (and the mock's),
/// through the send model the app composes (`UpNext`, `SubmitAnswer`, `SteerOutcome`,
/// `SendsNextReason`, `SendFailure`, `SendRefusal`, `ChatHold`, `GatewayHeldQueue`, `StagedImages`,
/// `NextTurnHold`, `StopReceipt`), and says what the person sees. The table at the bottom is the
/// matrix itself; `everyCellKeepsTheRules` holds every cell to the order's rules.
@Suite("Every way of sending, against every chat state")
struct SendMatrixTests {
    enum Mechanism: String, CaseIterable, CustomTestStringConvertible {
        case steer, upNext, send, stop, retry, editAndResend, photoWhileBusy, talk, toAnotherBot, routineFollowUp
        var testDescription: String { rawValue }
    }

    /// The columns. Another owner is three: the gateway's own turn (`SESSION_OWNER_BUSY`), a message
    /// it didn't confirm (`SESSION_OWNER_UNCONFIRMED`), another Hermes process (`SESSION_NOT_OWNED`).
    enum State: String, CaseIterable, CustomTestStringConvertible {
        case idle, turnRunning, toolRunning, backgroundProcess, ownerBusy, ownerUnconfirmed, notOwned, reconnecting, offline, relaunch
        var testDescription: String { rawValue }
    }

    /// What the person sees become of what they sent.
    enum Visible: Equatable {
        /// Its own turn starts, shown as its turn.
        case ownTurn
        /// Read into the running turn (the dashed steer bubble).
        case steeredIn
        /// Hermes holds it for its next turn: first in the tray, read-only, "on <gateway>".
        case heldByHermes
        /// Waits in Up Next; the tray says what for.
        case upNext(UpNextWait)
        /// Waits in Up Next for what holds the chat, named (`ChatHolder`), and goes by itself.
        case waitsFor(ChatHolder)
        /// Couldn't go the way it was sent: first in Up Next, saying why.
        case sendsNext(SendsNextReason)
        /// Never left this device: "Waiting for <Mac>…", and it goes when the gateway is back.
        case waitsForGateway
        /// Couldn't go: the words are back in the field.
        case backInField
        /// Hermes may have it: looked for in the chat, sent again only by the person.
        case lookedFor
        /// Stop ended the turn: what Hermes's queue held and never ran comes back, held, in order,
        /// with what else Stop ended.
        case stopped(givenBack: [String], receipt: String?)
        /// Stop couldn't reach the gateway: the turn stays running, and the chat says so.
        case stopUnanswered
        /// Edit and Resend: a new chat with the edited message; this one stays as it was.
        case newChat
        /// A turn Hermes starts itself shows live.
        case hermesTurn
        /// Hermes starts it as this one ends: its events wait (`NextTurnHold`) and it shows as the
        /// next turn, never inside the one before.
        case nextHermesTurn
        /// It runs where this device can't follow it; the chat says what holds it, when it knows.
        case runsElsewhere(ChatHolder?)
        /// Offline while it ran: the stored chat shows it on return.
        case storedOnReturn
        /// The control isn't there in this state (Stop with nothing running, steer with no turn).
        case notOffered
    }

    // MARK: The states, as the gateway answers in them

    /// A chat in one state: what runs here, whether the gateway is there, and how Hermes answers
    /// `prompt.submit` and `session.steer` (hermes-agent `tui_gateway/methods_prompt.py`,
    /// `session_auto_continue.py`, `methods_session_interrupt.py`; the mock plays each).
    struct Chat {
        var turnHere = false
        var reachable = true
        var helpersRunning = 0
        /// Hermes's queue holds these for the next turn; `ran` are the ones whose turn started.
        var heldByHermes: [String] = []
        var ran: [String] = []
        var submit: (_ photo: Bool) -> Result<JSONValue, any Error> = { _ in .success(Matrix.streaming) }
        var steer: Result<JSONValue, any Error> = .success(.object(["status": .string("queued")]))
    }

    static func chat(_ state: State) -> Chat {
        switch state {
        case .idle:
            // A steer here raced the turn's end: Hermes answers `rejected`.
            return Chat(steer: .success(.object(["status": .string("rejected")])))
        case .turnRunning:
            return Chat(turnHere: true, heldByHermes: ["Photo of the error", "ran already"], ran: ["ran already"],
                        submit: { _ in .success(Matrix.queued) })
        case .toolRunning:
            return Chat(turnHere: true, helpersRunning: 1, heldByHermes: ["Photo of the error"], submit: { _ in .success(Matrix.queued) })
        case .backgroundProcess:
            // A process runs beside the idle chat; its finished notice started a turn of Hermes's
            // own a moment before the send, which this device hasn't heard yet.
            return Chat(submit: { _ in .success(Matrix.queued) })
        case .ownerBusy:
            return Chat(submit: { photo in .failure(Matrix.refusal("SESSION_OWNER_BUSY", photo ? Matrix.busyPhoto : Matrix.busy)) })
        case .ownerUnconfirmed:
            return Chat(submit: { _ in .failure(Matrix.refusal("SESSION_OWNER_UNCONFIRMED", Matrix.unconfirmed)) })
        case .notOwned:
            return Chat(submit: { _ in .failure(Matrix.refusal("SESSION_NOT_OWNED", Matrix.notOwned)) })
        case .reconnecting:
            return Chat(turnHere: true, reachable: false, submit: { _ in .failure(GatewaySocket.Failure.notConnected) },
                        steer: .failure(GatewaySocket.Failure.notConnected))
        case .offline:
            return Chat(reachable: false, submit: { _ in .failure(GatewaySocket.Failure.notConnected) },
                        steer: .failure(GatewaySocket.Failure.notConnected))
        case .relaunch:
            // Opened after a relaunch: Up Next sent what it kept (`relaunchSendsWhatWaitedOnceOpened`),
            // so that message's turn runs now; a Maybe sent message still waits for a Send.
            return Chat(turnHere: true, submit: { _ in .success(Matrix.queued) })
        }
    }

    // MARK: The mechanisms, as the app composes the send model

    /// Who holds a chat another Hermes process answers in, by what its stored rows show running.
    static func elsewhere(_ mechanism: Mechanism) -> ElsewhereTurn? {
        switch mechanism {
        case .toAnotherBot: ElsewhereTurn(answering: "Ada")
        case .routineFollowUp: ElsewhereTurn(routine: "Disk report")
        default: nil
        }
    }

    static func see(_ mechanism: Mechanism, in state: State) -> Visible {
        let chat = chat(state)
        switch mechanism {
        case .send, .toAnotherBot:
            return sendOrQueue(chat, mechanism)
        case .retry:
            // Try Again goes the one way in (`sendOrQueue`); after an unconfirmed send it isn't
            // offered at all: the message may be with Hermes.
            if case .failure(let error as GatewayRPCError) = chat.submit(false), SendRefusal(error)?.offersRetry == false,
               SendRefusal(error)?.action == .checkTheChat {
                return .lookedFor
            }
            return sendOrQueue(chat, mechanism)
        case .steer:
            // The app steers while it shows a turn running, or before it heard one end.
            guard chat.turnHere || state == .idle else { return .notOffered }
            return steer(chat)
        case .talk:
            // `sendSpoken`: a running turn is steered; with no gateway the words go back to the field.
            if chat.turnHere { return steer(chat) }
            if !chat.reachable { return .backInField }
            return sendOrQueue(chat, mechanism)
        case .upNext:
            if state == .relaunch { return relaunchDrain() }
            guard UpNext.next(in: ["queued"], chat: UpNext.Chat(turnHoldsChat: chat.turnHere, reachable: chat.reachable), isHeld: { _ in false }) != nil else {
                return tray(chat, mechanism)
            }
            return submitted(chat, mechanism, photo: false)
        case .photoWhileBusy:
            guard chat.turnHere else { return submitted(chat, mechanism, photo: true) }
            // Held for the next turn (`prompt.submit {queued: true}`); with no socket it stays in the
            // app's queue, whole.
            if case .success(let answer) = chat.submit(true), SubmitAnswer(result: answer).isQueued { return .heldByHermes }
            return tray(chat, mechanism)
        case .stop:
            guard chat.turnHere else { return .notOffered }
            // `session.interrupt` with no socket never left: the turn goes on.
            if !chat.reachable, SendFailure.overSocket(GatewaySocket.Failure.notConnected) == .notSent { return .stopUnanswered }
            var held = GatewayHeldQueue<String>()
            for line in chat.heldByHermes { held.hold(line, item: line, isTextOnly: false) }
            let given = held.purged(ranSince: chat.ran.enumerated().map { Matrix.row($0.offset, $0.element) })
            return .stopped(givenBack: given.compactMap(\.item), receipt: StopReceipt.line(helpersStopped: chat.helpersRunning, approvalDeclined: false))
        case .editAndResend:
            // `session.branch`, then the message in the new chat; with no gateway the edit goes
            // back to the field.
            return chat.reachable ? .newChat : .backInField
        case .routineFollowUp:
            return routine(chat, state)
        }
    }

    /// Hermes refused the first try because something holds the chat: the chat waits for it
    /// (`waitForChat`), and Try Again waits behind that.
    static func waitsForChat(_ chat: Chat, _ mechanism: Mechanism) -> Bool {
        guard mechanism == .retry, case .failure(let error as GatewayRPCError) = chat.submit(false) else { return false }
        return SendRefusal(error)?.action == .waitsForChat
    }

    /// Send Again, Talk, Try Again, Send as Message (`ConversationModel.sendOrQueue`).
    static func sendOrQueue(_ chat: Chat, _ mechanism: Mechanism) -> Visible {
        guard UpNext.goesNow(turnRunning: chat.turnHere, waitsForChat: waitsForChat(chat, mechanism),
                             othersWaiting: false, queuePaused: false) else {
            return tray(chat, mechanism)
        }
        return submitted(chat, mechanism, photo: false)
    }

    /// `prompt.submit`'s answer, or how it failed.
    static func submitted(_ chat: Chat, _ mechanism: Mechanism, photo: Bool) -> Visible {
        switch chat.submit(photo) {
        case .success(let answer):
            switch SubmitAnswer(result: answer) {
            case .started: return .ownTurn
            case .queuedBehindTurn, .queuedOnGateway: return .heldByHermes
            case .steered: return .steeredIn
            case .redirected: return .steeredIn
            case .voiceStopped: return .notOffered
            }
        case .failure(let error):
            switch SendFailure.overSocket(error) {
            case .notSent, .sendAgain: return .waitsForGateway
            case .mayHaveArrived: return .lookedFor
            case .refused:
                guard let rpc = error as? GatewayRPCError, let refusal = SendRefusal(rpc) else { return .backInField }
                switch refusal.action {
                case .waitsForChat: return .waitsFor(holder(refusal, mechanism))
                case .checkTheChat: return .lookedFor
                case .settleOnGateway, .tryAgain: return .backInField
                }
            }
        }
    }

    static func holder(_ refusal: SendRefusal, _ mechanism: Mechanism) -> ChatHolder {
        if let holder = refusal.holder { return holder }
        guard case .chatHeld(let hold?) = refusal.reason else { return .elsewhere(refusal.line) }
        return hold.holder(of: elsewhere(mechanism), inBotChat: mechanism == .toAnotherBot)
    }

    /// The Up Next tray's header for a message waiting there.
    static func tray(_ chat: Chat, _ mechanism: Mechanism) -> Visible {
        let wait = UpNextWait.of(isEditing: false, waitsForChat: waitsForChat(chat, mechanism), turnHoldsChat: chat.turnHere,
                                 reachable: chat.reachable, heldOnGateway: false, allHeld: false)
        if wait == .chat, case .failure(let error as GatewayRPCError) = chat.submit(false), let refusal = SendRefusal(error) {
            return .waitsFor(holder(refusal, mechanism))
        }
        return .upNext(wait)
    }

    static func steer(_ chat: Chat) -> Visible {
        let (result, error): (JSONValue?, (any Error)?) = switch chat.steer {
        case .success(let answer): (answer, nil)
        case .failure(let failure): (nil, failure)
        }
        switch SteerOutcome.steer(result: result, error: error) {
        case .accepted, .redirected: return .steeredIn
        case .heldByHermes: return .heldByHermes
        case .unknown: return .lookedFor
        case .nextMessage:
            // The app still shows the turn running when the answer comes.
            return .sendsNext(SendsNextReason.steer(error: error, turnRunning: true, waitingForApproval: false, attached: chat.reachable))
        }
    }

    /// Up Next after a relaunch, once the chat is opened: what it kept goes, the Maybe sent
    /// message stays for a Send.
    static func relaunchDrain() -> Visible {
        let kept = [(text: "maybe", held: true), (text: "kept", held: false)]
        let opened = UpNext.Chat(turnHoldsChat: false, reachable: true, opened: true)
        guard let first = UpNext.next(in: kept, chat: opened, isHeld: \.held), first.text == "kept" else { return .upNext(.sendSendsFirst) }
        return submitted(Chat(), .upNext, photo: false)
    }

    /// A routine's follow-up: a turn Hermes starts itself in the chat.
    static func routine(_ chat: Chat, _ state: State) -> Visible {
        if case .failure(let error as GatewayRPCError) = chat.submit(false), let refusal = SendRefusal(error) {
            // Another process or the gateway's own queue runs it.
            if case .chatHeld = refusal.reason { return .runsElsewhere(holder(refusal, .routineFollowUp)) }
            return .runsElsewhere(refusal.holder)
        }
        if !chat.turnHere, !chat.reachable { return .storedOnReturn }
        // Hermes starts it the moment the turn before ends; its start reaches the app while it's
        // still finishing that one (or, unseen, behind a notice's turn).
        let turnBefore = chat.turnHere || state == .backgroundProcess
        var next = NextTurnHold<String>()
        return next.holds("message.start", startsTurn: true, turnEnded: turnBefore) ? .nextHermesTurn : .hermesTurn
    }

    // MARK: The matrix

    @Test(arguments: Mechanism.allCases, State.allCases)
    func cell(_ mechanism: Mechanism, _ state: State) throws {
        let expected = try #require(Matrix.expected[mechanism]?[state], "the matrix has no cell for \(mechanism) × \(state)")
        #expect(Self.see(mechanism, in: state) == expected)
    }

    @Test func theMatrixHasEveryCell() {
        #expect(Matrix.expected.count == Mechanism.allCases.count)
        for mechanism in Mechanism.allCases {
            #expect(Set(Matrix.expected[mechanism]?.keys.map { $0 } ?? []) == Set(State.allCases), "\(mechanism)")
        }
    }

    /// The order's rules, held against every cell: the true state is visible; nothing is lost,
    /// duplicated or sent to the wrong turn; refusals are never generic.
    @Test(arguments: Mechanism.allCases, State.allCases)
    func everyCellKeepsTheRules(_ mechanism: Mechanism, _ state: State) {
        let seen = Self.see(mechanism, in: state)
        let chat = Self.chat(state)
        // A steer only ever goes into a turn this device shows running.
        if seen == .steeredIn { #expect(chat.turnHere, "steered with no turn running here") }
        // Never "finished" while the turn still runs here; never "couldn't reach" while it's there.
        if case .sendsNext(let reason) = seen {
            #expect(reason != .turnEnded || state == .idle)
            #expect(reason != .notBack || !chat.reachable)
        }
        // A message Hermes may have is never sent again by itself.
        if seen == .lookedFor, case .failure(let error) = chat.submit(false) {
            #expect(SendFailure.overSocket(error) != .notSent)
            if let rpc = error as? GatewayRPCError, let refusal = SendRefusal(rpc) { #expect(!refusal.offersRetry) }
        }
        // Waiting for the gateway is only for a message that never left (nothing can run twice).
        if seen == .waitsForGateway { #expect(!chat.reachable) }
        // A refusal names what holds the chat in words, never the chat limit or a bare code.
        if case .waitsFor(let holder) = seen {
            if case .elsewhere(let line) = holder {
                #expect(!line.contains("as many chats at once"))
                #expect(!line.isEmpty && line.rangeOfCharacter(from: .lowercaseLetters) != nil)
            }
            if case .chatLimit = holder { Issue.record("only Hermes's chat limit is the chat limit") }
        }
        // Up Next never says "sends when this reply is done" with no reply running here.
        if seen == .upNext(.reply) { #expect(chat.turnHere) }
    }

    // MARK: Around the matrix

    /// A turn running, at its edges: the agent still being built, the chat compacting, an approval
    /// waited on, a run Hermes queued (`docs/chat.md` §4c).
    @Test func aSteerAtTheTurnsEdgesSaysWhyItGoesNext() {
        let starting = GatewayRPCError(code: 4010, message: "agent does not support steer")
        #expect(SteerOutcome.steer(result: nil, error: starting) == .nextMessage)
        #expect(SendsNextReason.steer(error: starting, turnRunning: true, waitingForApproval: false, attached: true) == .turnStarting)
        #expect(SteerOutcome.steer(result: .object(["status": .string("queued")]), error: nil, compacting: true) == .heldByHermes)
        let notAccepting = HermesError.server(status: 409, code: "run_not_accepting_steer", message: "Run is not currently accepting steer input")
        #expect(SteerOutcome.apiServer(error: notAccepting) == .nextMessage)
        #expect(SendsNextReason.steer(error: notAccepting, turnRunning: true, waitingForApproval: true, attached: true) == .waitsOnApproval)
        #expect(SendsNextReason.steer(error: notAccepting, turnRunning: true, waitingForApproval: false, runQueued: true, attached: true) == .runQueued)
    }

    /// Over the API server: what each answer to `POST /v1/runs` means for the message. The mock
    /// plays each (`/api/mock/run-caps`, the run FIFO, Idempotency-Key).
    @Test func overTheAPIServerNothingGoesTwiceAndRefusalsAreWords() throws {
        // The run cap (429) and a dropped connection go again under the same key: Hermes replays it.
        #expect(SendFailure.overHTTP(HermesError.server(status: 429, code: "rate_limit_exceeded", message: "Too many concurrent runs (max 10)")) == .sendAgain)
        #expect(SendFailure.overHTTP(URLError(.networkConnectionLost)) == .sendAgain)
        // The key went with another body: Hermes had the first.
        #expect(SendFailure.overHTTP(HermesError.server(status: 409, code: "idempotency_key_conflict", message: "Idempotency-Key was used with a different request")) == .mayHaveArrived)
        // The store's refusals come with only their reason: the chat says it in words.
        for code in ["queue_full", "permission_denied", "admission_conflict"] {
            let refusal = HermesError.server(status: 409, code: code, message: code)
            #expect(SendFailure.overHTTP(refusal) == .refused)
            #expect(refusal.isRefusal)
            #expect(refusal.errorDescription?.contains(code) == false, "\(code) shows as a bare code")
        }
        // A run Hermes queued behind another answers `started`; its status says it waits.
        let queued = try JSONDecoder().decode(RunStatus.self, from: Data(#"{"run_id": "run_2", "status": "queued"}"#.utf8))
        #expect(queued.isQueued)
        #expect(RunFollow.next(eventsGone: false, status: .success(queued)) == .listen)
    }

    /// The queue survives a relaunch: each row keeps why it's there, nothing goes from a chat the
    /// person hasn't opened, and once opened what waited goes, in order, the held one staying.
    @Test func relaunchSendsWhatWaitedOnceOpened() {
        for note in [UpNextNote.clearedByStop, .mayHaveArrived, .sendsNextInstead(.turnStarting), .sendsNextInstead(.notBack)] {
            #expect(UpNextNote(storedKey: note.storedKey) == note)
        }
        let kept = [(text: "maybe", held: true), (text: "kept", held: false), (text: "after", held: false)]
        let unopened = UpNext.Chat(turnHoldsChat: false, reachable: true, opened: false)
        #expect(UpNext.next(in: kept, chat: unopened, isHeld: \.held) == nil)
        #expect(Self.relaunchDrain() == .ownTurn)
        // While its turn runs, the next one waits, and the tray says for that reply.
        #expect(UpNext.next(in: Array(kept.dropFirst(2)), chat: UpNext.Chat(turnHoldsChat: true, reachable: true), isHeld: \.held) == nil)
        #expect(UpNextWait.of(isEditing: false, waitsForChat: false, turnHoldsChat: true, reachable: true, heldOnGateway: false, allHeld: false) == .reply)
        // Only Maybe sent left: it waits for a Send, never under "sends when this reply is done".
        #expect(UpNextWait.of(isEditing: false, waitsForChat: false, turnHoldsChat: false, reachable: true, heldOnGateway: false, allHeld: true) == .sendSendsFirst)
    }

    /// A photo whose message Hermes refused is taken back, so it doesn't ride on the next message;
    /// the gateway's busy refusal says it took the photo off.
    @Test func aRefusedPhotoNeverRidesOnTheNextMessage() throws {
        for state in [State.ownerBusy, .ownerUnconfirmed, .notOwned] {
            guard case .failure(let error) = Self.chat(state).submit(true) else { Issue.record("\(state) took it"); continue }
            #expect(StagedImages.takeBack(after: error, promptSent: true), "\(state)")
        }
        guard case .failure(let error as GatewayRPCError) = Self.chat(.ownerBusy).submit(true) else { return }
        #expect(try #require(SendRefusal(error)).line.contains("with its photo"))
    }
}

/// The matrix: what the person sees, for every mechanism in every state. `docs/development.md`
/// has it in short, with what the mock plays for each column.
enum Matrix {
    static let streaming = JSONValue.object(["status": .string("streaming"), "user_row_id": .number(7)])
    static let queued = JSONValue.object(["status": .string("queued")])

    // Hermes's own words (hermes-agent `tui_gateway/methods_prompt.py`, `hermes_cli/active_sessions.py`).
    static let busy = "The gateway is running a turn in this chat and this kind of message cannot join its queue. Nothing was sent. Send it again when the current turn ends."
    static let busyPhoto = "The gateway is running a turn in this chat and an image cannot join its queue, so it was removed from this message. Nothing was sent. Send it again when the current turn ends."
    static let unconfirmed = "The gateway is running a turn in this chat and did not confirm your message in time. It may already be queued there: check the chat before sending it again."
    static let notOwned = "This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.\nDetails: session 20261026_101500_ab12cd opened by cli 0m ago."

    static func refusal(_ reason: String, _ message: String) -> GatewayRPCError {
        GatewayRPCError(code: 4090, message: message, data: .object(["reason": .string(reason)]))
    }

    static func row(_ index: Int, _ text: String) -> SessionMessage {
        try! JSONDecoder().decode(SessionMessage.self, from: Data(#"{"id": \#(index + 1), "role": "user", "content": "\#(text)"}"#.utf8))
    }

    typealias M = SendMatrixTests.Mechanism
    typealias V = SendMatrixTests.Visible

    static let terminal = ChatHolder.elsewhere("This chat is open in another Hermes window/terminal. Use it there, or start a new chat here.")
    static let stoppedWithPhoto = V.stopped(givenBack: ["Photo of the error"], receipt: nil)

    static let expected: [M: [SendMatrixTests.State: V]] = [
        .steer: [
            .idle: .sendsNext(.turnEnded), .turnRunning: .steeredIn, .toolRunning: .steeredIn, .backgroundProcess: .notOffered,
            .ownerBusy: .notOffered, .ownerUnconfirmed: .notOffered, .notOwned: .notOffered,
            .reconnecting: .sendsNext(.notBack), .offline: .notOffered, .relaunch: .steeredIn,
        ],
        .upNext: [
            .idle: .ownTurn, .turnRunning: .upNext(.reply), .toolRunning: .upNext(.reply), .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(terminal),
            .reconnecting: .upNext(.gatewayAway), .offline: .upNext(.gatewayAway), .relaunch: .ownTurn,
        ],
        .send: [
            .idle: .ownTurn, .turnRunning: .upNext(.reply), .toolRunning: .upNext(.reply), .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(terminal),
            .reconnecting: .upNext(.gatewayAway), .offline: .waitsForGateway, .relaunch: .upNext(.reply),
        ],
        .stop: [
            .idle: .notOffered, .turnRunning: stoppedWithPhoto,
            .toolRunning: .stopped(givenBack: ["Photo of the error"], receipt: "Stop also stopped 1 helper."),
            .backgroundProcess: .notOffered, .ownerBusy: .notOffered, .ownerUnconfirmed: .notOffered, .notOwned: .notOffered,
            .reconnecting: .stopUnanswered, .offline: .notOffered, .relaunch: .stopped(givenBack: [], receipt: nil),
        ],
        .retry: [
            .idle: .ownTurn, .turnRunning: .upNext(.reply), .toolRunning: .upNext(.reply), .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(terminal),
            .reconnecting: .upNext(.gatewayAway), .offline: .waitsForGateway, .relaunch: .upNext(.reply),
        ],
        .editAndResend: [
            .idle: .newChat, .turnRunning: .newChat, .toolRunning: .newChat, .backgroundProcess: .newChat,
            .ownerBusy: .newChat, .ownerUnconfirmed: .newChat, .notOwned: .newChat,
            .reconnecting: .backInField, .offline: .backInField, .relaunch: .newChat,
        ],
        .photoWhileBusy: [
            .idle: .ownTurn, .turnRunning: .heldByHermes, .toolRunning: .heldByHermes, .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(terminal),
            .reconnecting: .upNext(.gatewayAway), .offline: .waitsForGateway, .relaunch: .heldByHermes,
        ],
        .talk: [
            .idle: .ownTurn, .turnRunning: .steeredIn, .toolRunning: .steeredIn, .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(terminal),
            .reconnecting: .sendsNext(.notBack), .offline: .backInField, .relaunch: .steeredIn,
        ],
        .toAnotherBot: [
            .idle: .ownTurn, .turnRunning: .upNext(.reply), .toolRunning: .upNext(.reply), .backgroundProcess: .heldByHermes,
            .ownerBusy: .waitsFor(.gatewayTurn), .ownerUnconfirmed: .lookedFor, .notOwned: .waitsFor(.answeringBot("Ada")),
            .reconnecting: .upNext(.gatewayAway), .offline: .waitsForGateway, .relaunch: .upNext(.reply),
        ],
        .routineFollowUp: [
            .idle: .hermesTurn, .turnRunning: .nextHermesTurn, .toolRunning: .nextHermesTurn, .backgroundProcess: .nextHermesTurn,
            .ownerBusy: .runsElsewhere(.gatewayTurn), .ownerUnconfirmed: .runsElsewhere(nil), .notOwned: .runsElsewhere(.routine("Disk report")),
            .reconnecting: .nextHermesTurn, .offline: .storedOnReturn, .relaunch: .nextHermesTurn,
        ],
    ]
}
