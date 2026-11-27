import Foundation
import Testing
@testable import HermesKit

/// The session a plugin command runs in (`docs/notifications.md` §1.2): the session authority
/// (Hermes Agent 0.23.3 and newer) refuses a `command.dispatch` without one, the legacy dispatcher
/// gets exactly what it always got.
@Suite("A command's session")
struct CommandDispatchSessionTests {
    private static let notFound = GatewayRPCError(code: 4001, message: "not_found", data: .object(["reason": .string("not_found")]))

    private static func refusal(_ reason: String) -> GatewayRPCError {
        GatewayRPCError(code: 4001, message: reason, data: .object(["reason": .string(reason)]))
    }

    private static let pushStatus: [String: JSONValue] = ["name": .string("app-push"), "arg": .string(#"status {"device_id":"dev-1"}"#)]

    @Test func onlyACommandWithoutASessionOnTheAuthorityGetsOne() {
        #expect(CommandDispatchSession.needsSession(method: "command.dispatch", params: Self.pushStatus, sessionAuthority: true))
        var empty = Self.pushStatus
        empty["session_id"] = .string("")
        #expect(CommandDispatchSession.needsSession(method: "command.dispatch", params: empty, sessionAuthority: true))
        // The legacy dispatcher runs it in its own profile, as it always has.
        #expect(!CommandDispatchSession.needsSession(method: "command.dispatch", params: Self.pushStatus, sessionAuthority: false))
        // A chat's own command keeps its chat.
        var own = Self.pushStatus
        own["session_id"] = .string("rt-chat")
        #expect(!CommandDispatchSession.needsSession(method: "command.dispatch", params: own, sessionAuthority: true))
        #expect(!CommandDispatchSession.needsSession(method: "session.list", params: [:], sessionAuthority: true))
    }

    @Test func theCommandsProfileChoosesTheSession() {
        #expect(CommandDispatchSession.profile(of: Self.pushStatus) == nil)
        #expect(CommandDispatchSession.profile(of: ["profile": .string("")]) == nil)
        #expect(CommandDispatchSession.profile(of: ["profile": .string("scout")]) == "scout")
    }

    @Test func theSessionIsAddedAndTheRestIsKept() async throws {
        var params = Self.pushStatus
        params["profile"] = .string("scout")
        var sent: [[String: JSONValue]] = []
        let answer = try await CommandDispatchSession.sending(params) { stale in
            #expect(stale == nil)
            return "rt-1"
        } send: { params in
            sent.append(params)
            return JSONValue.string("ok")
        }
        #expect(answer == .string("ok"))
        var expected = params
        expected["session_id"] = .string("rt-1")
        #expect(sent == [expected])
    }

    @Test func aSessionThatIsGoneIsReplacedOnceAndTriedOnce() async throws {
        var asked: [String?] = []
        var sent: [String] = []
        let answer = try await CommandDispatchSession.sending(Self.pushStatus) { stale in
            asked.append(stale)
            return stale == nil ? "rt-old" : "rt-new"
        } send: { params in
            let session = params["session_id"]?.stringValue ?? ""
            sent.append(session)
            if session == "rt-old" { throw Self.notFound }
            return JSONValue.string("ok")
        }
        #expect(answer == .string("ok"))
        #expect(asked == [nil, "rt-old"])
        #expect(sent == ["rt-old", "rt-new"])
    }

    @Test func aSecondRefusalIsThrownNeverLooped() async {
        var sends = 0
        var lookups = 0
        await #expect(throws: Self.notFound) {
            try await CommandDispatchSession.sending(Self.pushStatus) { _ in
                lookups += 1
                return "rt-\(lookups)"
            } send: { _ -> JSONValue in
                sends += 1
                throw Self.notFound
            }
        }
        #expect(sends == 2 && lookups == 2)
    }

    @Test func otherRefusalsAreNotRetried() async {
        for error in [Self.refusal("permission_denied"), Self.refusal("unsupported_command"), GatewayRPCError(code: 4018, message: "no")] {
            var sends = 0
            await #expect(throws: error) {
                try await CommandDispatchSession.sending(Self.pushStatus) { _ in "rt-1" } send: { _ -> JSONValue in
                    sends += 1
                    throw error
                }
            }
            #expect(sends == 1)
        }
    }

    @Test func theBotChatIsFoundAndResumed() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let runtime = try await CommandDispatchSession.openBotChat(profile: "scout") { method, params in
            calls.append((method, params))
            switch method {
            case "session.list":
                return ["sessions": [["id": "st-chat", "resolved_id": "st-chat-2", "title": .string(botChatTitle)]]]
            case "session.resume":
                return ["session_id": "rt-chat"]
            default:
                Issue.record("unexpected \(method)")
                return [:]
            }
        }
        #expect(runtime == "rt-chat")
        #expect(calls.map(\.0) == ["session.list", "session.resume"])
        #expect(calls[0].1 == [
            "profile": "scout", "title": .string(botChatTitle), "include_hidden": true, "limit": 200,
        ])
        #expect(calls[1].1 == ["profile": "scout", "session_id": "st-chat-2", "omit_messages": true])
    }

    @Test func aProfileWithoutOneGetsItHidden() async throws {
        var calls: [(String, [String: JSONValue])] = []
        let runtime = try await CommandDispatchSession.openBotChat(profile: nil) { method, params in
            calls.append((method, params))
            return method == "session.list" ? ["sessions": []] : ["session_id": "rt-new"]
        }
        #expect(runtime == "rt-new")
        #expect(calls.map(\.0) == ["session.list", "session.create"], "no session.title: the authority has none")
        #expect(calls[0].1["profile"] == nil, "the gateway's own profile goes without one")
        #expect(calls[1].1 == [
            "title": .string(botChatTitle), "hidden": true, "follow_profile_config": true,
        ])
    }

    @Test func anUnreadableListMakesNoSecondChat() async {
        var methods: [String] = []
        await #expect(throws: HermesError.invalidResponse("session.list")) {
            try await CommandDispatchSession.openBotChat(profile: nil) { method, _ in
                methods.append(method)
                return ["error": "busy"]
            }
        }
        #expect(methods == ["session.list"])
    }

    @Test func aMissingCommandReadsTheSameOnBoth() {
        #expect(CommandDispatchSession.isCommandMissing(GatewayRPCError(code: 4018, message: "not a quick/plugin/bundle/skill command: app-push")))
        #expect(CommandDispatchSession.isCommandMissing(Self.refusal("unsupported_command")))
        #expect(!CommandDispatchSession.isCommandMissing(Self.notFound))
        #expect(!CommandDispatchSession.isCommandMissing(Self.refusal("permission_denied")))
        #expect(!CommandDispatchSession.isCommandMissing(URLError(.timedOut)))
    }

    @Test func thePluginsReadAMissingCommandAsNotInstalled() async {
        let unsupported = Self.refusal("unsupported_command")
        let push = AppPushClient { _, _ in throw unsupported }
        await #expect(throws: AppPushClient.Failure.notInstalled) { try await push.status(deviceID: "dev-1") }
        let widgets = AppWidgetsClient { _, _ in throw unsupported }
        await #expect(throws: AppWidgetsClient.Failure.notInstalled) { try await widgets.markRoom("room_1") }
        // A command that found no session is not a missing plugin.
        let lost = AppPushClient { _, _ in throw Self.notFound }
        await #expect(throws: Self.notFound) { try await lost.status(deviceID: "dev-1") }
    }
}
