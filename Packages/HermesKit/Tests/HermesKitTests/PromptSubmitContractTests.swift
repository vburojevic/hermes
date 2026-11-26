import Foundation
import Testing
@testable import HermesKit

/// One message's `prompt.submit` for the dispatcher serving the socket (`docs/follow-ups.md` §4,
/// `docs/composer.md` §3): the legacy one forbids unknown keys, the session authority (Hermes Agent
/// 0.23.3 and newer) admits a message only with its `submission_id`.
@Suite("A message's prompt.submit")
struct PromptSubmitContractTests {
    private static let authorityNotFound = GatewayRPCError(code: 4001, message: "not_found", data: .object(["reason": .string("not_found")]))

    private static func authorityRefusal(_ reason: String) -> GatewayRPCError {
        GatewayRPCError(code: 4001, message: reason, data: .object(["reason": .string(reason)]))
    }

    @Test func aLegacySocketGetsExactlyTheKeysItAlwaysGot() {
        let submit = PromptSubmitContract(sessionID: "rt-1", text: "Hi", submissionID: "msg-1")
        #expect(submit.params(sessionAuthority: false) == [
            "session_id": .string("rt-1"), "text": .string("Hi"), "queued": .bool(true),
        ])
        let reply = PromptSubmitContract(sessionID: "rt-1", text: "Hi", queued: false, submissionID: "msg-1")
        #expect(reply.params(sessionAuthority: false) == ["session_id": .string("rt-1"), "text": .string("Hi")])
    }

    @Test func theSessionAuthorityGetsTheMessagesSubmissionID() {
        let submit = PromptSubmitContract(sessionID: "rt-1", text: "Hi", submissionID: "msg-1")
        #expect(submit.params(sessionAuthority: true) == [
            "session_id": .string("rt-1"), "text": .string("Hi"), "queued": .bool(true),
            "submission_id": .string("msg-1"),
        ])
    }

    @Test func aSpokenTurnKeepsItsVoiceKeysOnBoth() {
        let voice = VoiceTurn(isVoiceTurn: true, context: "User: hi", interrupted: true)
        let submit = PromptSubmitContract(sessionID: "rt-1", text: "Hi", extras: voice.submitParams, submissionID: "msg-1")
        for authority in [false, true] {
            let params = submit.params(sessionAuthority: authority)
            #expect(params["surface"] == .string("voice-live"))
            #expect(params["voice_turn"] == .bool(true))
            #expect(params["voice_context"] == .string("User: hi"))
            #expect(params["interrupted"] == .bool(true))
            #expect((params["submission_id"] != nil) == authority)
        }
    }

    @Test func eachMessageMintsItsOwnID() {
        let first = PromptSubmitContract(sessionID: "rt-1", text: "Hi")
        let second = PromptSubmitContract(sessionID: "rt-1", text: "Hi")
        #expect(first.submissionID != second.submissionID)
        #expect(UUID(uuidString: first.submissionID) != nil)
    }

    /// A missing session, or on the session authority a chat this socket hasn't resumed
    /// (`permission_denied`, `gateway/session_controls.py` `submission`).
    @Test func onlyAMissingSessionOrAnUnresumedChatIsStale() {
        #expect(PromptSubmitContract.isStaleSession(GatewayRPCError(code: 4001, message: "session not found")))
        #expect(PromptSubmitContract.isStaleSession(Self.authorityNotFound))
        #expect(PromptSubmitContract.isStaleSession(Self.authorityRefusal("permission_denied")))
        #expect(!Self.authorityRefusal("permission_denied").isSessionNotFound)
        for reason in ["invalid_params", "runtime_draining", "session_busy"] {
            #expect(!PromptSubmitContract.isStaleSession(Self.authorityRefusal(reason)))
        }
        #expect(!PromptSubmitContract.isStaleSession(GatewayRPCError(code: 4007, message: "session not found")))
        #expect(!PromptSubmitContract.isStaleSession(GatewayRPCError(code: 4000, message: "invalid params for prompt.submit")))
        #expect(!PromptSubmitContract.isStaleSession(GatewaySocket.Failure.notConnected))
    }

    @Test func aStaleSessionIsResumedOnceAndTheSameMessageGoesAgain() async throws {
        let submit = PromptSubmitContract(sessionID: "rt-old", text: "Hi", submissionID: "msg-1")
        var sent: [[String: JSONValue]] = []
        var resumes = 0
        let answer = try await PromptSubmitContract.submittingOnce(submit) { submit in
            sent.append(submit.params(sessionAuthority: true))
            if submit.sessionID == "rt-old" { throw Self.authorityNotFound }
            return "started"
        } resume: {
            resumes += 1
            return "rt-new"
        }
        #expect(answer == "started")
        #expect(resumes == 1)
        #expect(sent.map { $0["session_id"]?.stringValue } == ["rt-old", "rt-new"])
        #expect(sent.map { $0["submission_id"]?.stringValue } == ["msg-1", "msg-1"])
    }

    /// A reconnected socket holds no chat until it resumes one: the authority refuses its submit
    /// before admitting anything, so the chat is resumed and the same message goes again, once.
    @Test func anUnresumedChatIsResumedOnceWithTheSameID() async throws {
        let submit = PromptSubmitContract(sessionID: "s-1", text: "Hi", submissionID: "msg-1")
        var subscribed = false
        var sent: [String?] = []
        var resumes = 0
        let answer = try await PromptSubmitContract.submittingOnce(submit) { submit in
            sent.append(submit.params(sessionAuthority: true)["submission_id"]?.stringValue)
            guard subscribed else { throw Self.authorityRefusal("permission_denied") }
            return "queued"
        } resume: {
            resumes += 1
            subscribed = true
            return "s-1"
        }
        #expect(answer == "queued")
        #expect(resumes == 1)
        #expect(sent == ["msg-1", "msg-1"])
    }

    @Test func aDenialAfterTheResumeIsThrown() async {
        let submit = PromptSubmitContract(sessionID: "s-1", text: "Hi", submissionID: "msg-1")
        var sends = 0
        var resumes = 0
        await #expect(throws: GatewayRPCError.self) {
            try await PromptSubmitContract.submittingOnce(submit) { _ -> String in
                sends += 1
                throw Self.authorityRefusal("permission_denied")
            } resume: {
                resumes += 1
                return "s-1"
            }
        }
        #expect(sends == 2)
        #expect(resumes == 1)
    }

    @Test func aSecondStaleSessionIsThrown() async {
        let submit = PromptSubmitContract(sessionID: "rt-old", text: "Hi", submissionID: "msg-1")
        var sends = 0
        var resumes = 0
        await #expect(throws: GatewayRPCError.self) {
            try await PromptSubmitContract.submittingOnce(submit) { _ -> String in
                sends += 1
                throw Self.authorityNotFound
            } resume: {
                resumes += 1
                return "rt-new"
            }
        }
        #expect(sends == 2)
        #expect(resumes == 1)
    }

    @Test func anyOtherRefusalIsShownWithoutAResume() async {
        let submit = PromptSubmitContract(sessionID: "rt-1", text: "Hi", submissionID: "msg-1")
        var sends = 0
        var resumes = 0
        await #expect(throws: GatewayRPCError.self) {
            try await PromptSubmitContract.submittingOnce(submit) { _ -> String in
                sends += 1
                throw Self.authorityRefusal("invalid_params")
            } resume: {
                resumes += 1
                return "rt-new"
            }
        }
        #expect(sends == 1)
        #expect(resumes == 0)
    }
}
