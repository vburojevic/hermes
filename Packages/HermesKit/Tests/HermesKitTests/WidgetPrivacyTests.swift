import Foundation
import Synchronization
import Testing
@testable import HermesKit

/// Signed answers, previews and what the device keeps (`docs/widgets.md` §6, §8).
@Suite("Widget privacy")
struct WidgetPrivacyTests {
    private func example(_ name: String) throws -> JSONValue {
        try #require(WidgetSpec.shared.examples().first { $0.name == name }?.json)
    }

    private func setting(_ json: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var object) = json else { return json }
        object[key] = value
        return .object(object)
    }

    // MARK: Signed answers

    @Test func approvalsThatCostOrCantBeUndoneNeedASignature() throws {
        // Lunch: a purchase that needs authentication.
        #expect(WidgetSignature.isRequired(try example("approval-1"), action: "approve"))
        // A message that can't be taken back.
        #expect(WidgetSignature.isRequired(try example("approval-2"), action: "approve"))
        // Rejecting or editing never does.
        #expect(!WidgetSignature.isRequired(try example("approval-1"), action: "reject"))
        #expect(!WidgetSignature.isRequired(try example("approval-1"), action: "edit"))
    }

    @Test func aFreeReversiblePostNeedsNoSignature() {
        let post: JSONValue = ["type": "approval", "subject": ["kind": "post", "verb": "Publish"], "consequences": ["reversible": "yes"]]
        #expect(!WidgetSignature.isRequired(post, action: "approve"))
        let costs = setting(post, "consequences", ["reversible": "yes", "cost": ["amount": ["value": 2, "format": "currency", "currency": "EUR"]]])
        #expect(WidgetSignature.isRequired(costs, action: "approve"))
        #expect(WidgetSignature.isRequired(setting(post, "subject", ["kind": "teleport"]), action: "approve"))
        #expect(WidgetSignature.isRequired(setting(post, "authentication", "required"), action: "approve"))
    }

    @Test func anActionMarkedForAuthenticationNeedsOne() {
        let list: JSONValue = ["type": "list", "rows": [["id": "r1", "title": "Invoice", "actions": [
            ["id": "pay", "label": "Pay", "requires": "authentication"], ["id": "open", "label": "Open"],
        ]]]]
        #expect(WidgetSignature.isRequired(list, action: "pay"))
        #expect(!WidgetSignature.isRequired(list, action: "open"))
    }

    @Test func signingInputMatchesThePlugin() {
        // hashlib.sha256(json.dumps(values, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode())
        let answer = WidgetAnswer(widgetID: "w_flights21", rev: 2, action: "answer", mid: "m-1",
                                  values: ["selected": ["ua1187"], "note": "café/ü"])
        #expect(answer.signingInput == "hermes-widgets-v1|w_flights21|2|answer|e5fc536f8ae442b86d7fd60f49d62a80da5673b37d61552b7a92dc39f3359511|m-1")
    }

    // MARK: Previews

    @Test func previewsLeaveWidgetsOut() {
        let reply = "Revenue is up today.\n\n::widget{id=\"w_revenue001\" alt=\"Revenue today: €1,240\"}"
        #expect(WidgetPrivacy.previewText(reply) == "Revenue is up today.")
        let only = "::widget{id=\"w_heartrate1\" alt=\"Resting heart rate\"}"
        #expect(WidgetPrivacy.previewText(only).isEmpty)
        #expect(WidgetPrivacy.hasWidgets(only))
        let inline = "Your morning brief.\n\n```widget\n{\"type\":\"metric\",\"v\":1,\"id\":\"w_brief00001\",\"rev\":1,\"title\":\"Steps\"}\n```"
        #expect(WidgetPrivacy.previewText(inline) == "Your morning brief.")
    }

    @Test func aReplyThatIsOnlyAWidgetSaysSo() {
        let turn = AssistantTurn(id: "t1", answer: "::widget{id=\"w_heartrate1\" alt=\"Resting heart rate\"}")
        #expect(LastLine.of([.assistant(turn)])?.text == "Sent a widget")
    }

    @Test func anAnswerReadsAsWhatItDidWithoutItsWords() {
        let answer = WidgetAnswer(widgetID: "w_form000001", rev: 1, action: "submit", words: "Blood pressure 120/80", mid: "m-9")
        let line = LastLine.of([.user(UserEntry(id: "u1", text: answer.message))])
        #expect(line?.text == "Sent")
        #expect(line?.speaker == .you)
    }

    // MARK: At rest

    @Test func privatePayloadsLeaveTheCachedRows() throws {
        let heart = setting(try example("chart-1"), "sensitivity", "private")
        let created = WidgetAnswer.canonical(["id": heart["id"] ?? "", "rev": 1, "payload": heart])
        let open = try example("metric-1")
        let id = try #require(heart["id"]?.stringValue)
        let answer = WidgetAnswer(widgetID: id, rev: 1, action: "refresh", words: "my pulse", mid: "m-3", values: ["note": "private"], device: "iPhone")
        let rows = [
            SessionMessage(id: 1, role: "tool", content: .text(created), toolCallID: "c1", toolName: "widget"),
            SessionMessage(id: 2, role: "assistant", content: .text("Your pulse.\n\n::widget{id=\"\(id)\" alt=\"Resting heart rate\"}")),
            SessionMessage(id: 3, role: "user", content: .text(answer.message)),
            SessionMessage(id: 4, role: "tool", content: .text(WidgetAnswer.canonical(["id": open["id"] ?? "", "rev": 1, "payload": open])),
                           toolCallID: "c2", toolName: "widget"),
        ]
        let (kept, payloads) = WidgetPrivacy.atRest(rows)
        #expect(payloads.map { $0["id"] } == [heart["id"]])
        #expect(!kept[0].content.text.contains("payload"))
        #expect(kept[0].content.text.contains("\"private\":true"))
        #expect(kept[1].content.text == rows[1].content.text)
        let cachedAnswer = try #require(WidgetAnswer.parse(kept[2].content.text))
        #expect(cachedAnswer.mid == "m-3")
        #expect(cachedAnswer.words == nil)
        #expect(cachedAnswer.values == [:])
        // A widget that isn't private stays as it was, so a cached chat draws it at once.
        #expect(kept[3].content.text == rows[3].content.text)
    }

    @Test func aPrivateInlineBlockBecomesADirective() throws {
        let heart = setting(try example("chart-1"), "sensitivity", "private")
        let id = try #require(heart["id"]?.stringValue)
        let delivery = "Morning check.\n\n```widget\n" + WidgetAnswer.canonical(heart) + "\n```"
        let (kept, payloads) = WidgetPrivacy.atRest([SessionMessage(id: 1, role: "assistant", content: .text(delivery))])
        #expect(payloads.count == 1)
        let text = kept[0].content.text
        #expect(!text.contains("```"))
        #expect(ReplySplitter.directiveIDs(in: text) == [id])
    }

    @Test func nothingPrivateChangesNothing() throws {
        let rows = [SessionMessage(id: 1, role: "assistant", content: .text("Hello"))]
        let (kept, payloads) = WidgetPrivacy.atRest(rows)
        #expect(kept.map(\.content.text) == ["Hello"])
        #expect(payloads.isEmpty)
    }

    // MARK: The plugin's commands

    @Test func commandsRunThroughCommandDispatch() async throws {
        let sent = Mutex<[[String: JSONValue]]>([])
        let client = AppWidgetsClient(profile: "ops") { method, params in
            #expect(method == "command.dispatch")
            sent.withLock { $0.append(params) }
            return ["type": "plugin", "output": #"{"ok":true,"device_id":"d1","fingerprint":"ab12","devices":1}"#]
        }
        let fingerprint = try await client.registerKey(deviceID: "d1", publicKey: "BASE64", name: "iPhone")
        #expect(fingerprint == "ab12")
        let params = try #require(sent.withLock { $0.first })
        #expect(params["name"] == "app-widgets")
        #expect(params["profile"] == "ops")
        #expect(params["arg"]?.stringValue == #"keys.register {"device_id":"d1","name":"iPhone","public_key":"BASE64"}"#)
    }

    /// Where only a Bot has the plugin, commands about no chat go through that Bot's open chat:
    /// Hermes runs a command without a session in the profile it was launched in.
    @Test func commandsAboutNoChatGoThroughTheBotsOpenChat() async throws {
        let sent = Mutex<[[String: JSONValue]]>([])
        let client = AppWidgetsClient(profile: "core", session: "rt-core") { _, params in
            sent.withLock { $0.append(params) }
            return ["type": "plugin", "output": #"{"ok":true,"session_ids":["a"]}"#]
        }
        try await client.markSessions(["a"])
        try await client.markSession(runtimeID: "rt-other", storedID: "b")
        let calls = sent.withLock { $0 }
        #expect(calls.map { $0["session_id"]?.stringValue } == ["rt-core", "rt-other"], "a chat's own command keeps its chat")
        #expect(calls.allSatisfy { $0["profile"] == "core" })
    }

    @Test func aMissingPluginAndARefusalAreTold() async {
        let missing = AppWidgetsClient { _, _ in throw GatewayRPCError(code: 4018, message: "not a quick/plugin/bundle/skill command") }
        await #expect(throws: AppWidgetsClient.Failure.notInstalled) { try await missing.markRoom("room_1") }
        let refused = AppWidgetsClient { _, _ in ["type": "plugin", "output": #"{"ok":false,"error":"room_id is required"}"#] }
        await #expect(throws: AppWidgetsClient.Failure.refused("room_id is required")) { try await refused.markRoom("") }
    }
}
