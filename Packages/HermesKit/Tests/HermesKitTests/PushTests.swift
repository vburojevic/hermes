import Foundation
import HermesPush
import Testing
@testable import HermesKit

@Suite struct PushTests {
    /// A device key (bytes 1…32) and an envelope the plugin's `crypto.seal` made for it.
    static let privateKey = Data(base64Encoded: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=")!
    static let envelope = PushEnvelope(
        epk: "E7JQxZUMtCH3lFjuAgZHouajW0VhHz9ZPr2N1Yufo3A=",
        box: "4qADG4PH6Yaggp5kr98eGZPtYm7FHp+OLQ1mxX9J4AYelhYaLA0axm8SNghXVbPhadHxqBLYsy8yMD8awNZ/PCyC1TN5y5tM4xOmJcR+RzIIvNK8cFwK5vcmiTZH6GD5Wtk64OxHeXACRmbX9O00uMTe4wYFaqY+HJ8VZxTUJj9hRDnD6k7so9ysMbOAcXDQvRXYfaYCc0fNvBZNk8LLfJ0b+H5uzdkK6JsC5xpVRzKxtCcFegDKHqbfkAFYIuoJVsjVu8aMO37rc0Hqhyt+UYuDgzQnkMH7JoWdrG4JM7Qi2HODZvFn8+nnWf1ID309D/PQnvmVUrxf3VA5HX1IanRJwqq6WsLSpGhzz1lzI0NWdkIhnqlZClJ9NK5LFfLK0nj5X16lhmkp6sed4SjxKLs4vkIVDyFpa+FnroxVhaHcpjz4o5A4/DS9M+DUJYKL+Mko7Wfny1mIJiNlM5AzhQdGpQueLnDpwYIJ77DeAN8iY5sW1fbd9Jk4gLIpNjRaP7n2CXP7sVCwvEJuf7j53IZ+OXloFsnFFszTdNTZkscb+cyaBOEmfWyyGbfAFLS44gmcIXR912uNsj7y3TxEx9xpwR+BA9gkbIY3I+ILOkLx9BKXBhLb3LuFBvSMAQcRpoNoEXPo0D8o+enJ36DRRBF39IRW8m205oMJu+crxu07RljB3GvICbQ453DOSqVkVYA/YPDDbzco7+NsoUArNXGim4XRvToKhlDjKoIi4Vn+kYvVtrOm4BNT2XwUy0u557/EE+hTwX0Q9LZpJAQY5kzXciNVCN40E84Tve83MsU6CYFpVzOOQnSb9bBO0nB9MFoLzcUl3OcqlTJlM74RP+AV5Ef3T687TupiXpq77w4BqWc/vwqbZkp2o6R3YwT635c5hhRs06ZxCW0="
    )

    @Test func opensWhatThePluginSealed() throws {
        let key = try PushDeviceKey(rawRepresentation: Self.privateKey)
        #expect(key.publicKeyBase64 == "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=")
        let notice = try key.open(PushNotice.self, from: Self.envelope)
        #expect(notice.kind == .approval)
        #expect(notice.requestID == "req-1")
        #expect(notice.chatID == "20261014_x")
        #expect(notice.command == "rm -rf ~/snapshots/2026-0[1-8]-*")
        #expect(notice.detail == "recursive delete")
        #expect(notice.choices == ["once", "session", "always", "deny"])
        #expect(notice.answer == PushNotice.Answer(via: "socket", sessionID: "20261014_x"))
        #expect(notice.gateway == PushNotice.Gateway(id: "inst_abc", name: "mac-mini"))
        #expect(notice.open == 2 && notice.resolved == ["req-0"])
        #expect(notice.expiresAt == Date(timeIntervalSince1970: 1_792_000_000.5))
    }

    @Test func refusesATamperedOrForeignEnvelope() throws {
        let key = try PushDeviceKey(rawRepresentation: Self.privateKey)
        var tampered = Self.envelope
        var bytes = Data(base64Encoded: tampered.box)!
        bytes[20] ^= 1
        tampered.box = bytes.base64EncodedString()
        #expect(throws: (any Error).self) { try key.open(tampered) }
        #expect(throws: (any Error).self) { try PushDeviceKey().open(Self.envelope) }
        var future = Self.envelope
        future.v = 2
        #expect(throws: PushCryptoError.unsupportedVersion(2)) { try key.open(future) }
    }

    @Test func sealsLikeThePlugin() throws {
        let key = PushDeviceKey()
        let state = TurnActivityState(phase: .needsYou, command: "git push --force", requestID: "r1")
        let envelope = try key.seal(state)
        #expect(envelope.v == 1 && Data(base64Encoded: envelope.epk)?.count == 32)
        #expect(try key.open(TurnActivityState.self, from: envelope) == state)
    }

    @Test func pluginActivityStateDecodes() throws {
        let json = #"{"phase":"working","step":"Running a command: ls","started_at":1792000000,"title":"Disk cleanup","progress":{"done":3,"total":6},"gateway":"mac-mini"}"#
        let state = try JSONDecoder().decode(TurnActivityState.self, from: Data(json.utf8))
        #expect(state.phase == .working && state.progress == .init(done: 3, total: 6))
        #expect(state.startedAt == Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func unknownKindsAndFieldsStillDecode() throws {
        let json = #"{"kind":"holiday","id":"x","title":"Hi","body":"There","extra":{"a":1}}"#
        let notice = try JSONDecoder().decode(PushNotice.self, from: Data(json.utf8))
        #expect(notice.kind == .unknown && notice.title == "Hi")
    }

    @Test func questionChoicesBecomeActionsOnlyWhenSimple() {
        var notice = PushNotice(kind: .question, id: "q", questions: [.init(question: "Which?", choices: ["A", "B", "C", "D"])])
        #expect(notice.actionChoices == ["A", "B", "C"])
        notice.questions = [.init(question: "Which?", choices: ["A"], multiSelect: true)]
        #expect(notice.actionChoices.isEmpty)
        notice.questions.append(.init(question: "And?", choices: ["B"]))
        #expect(notice.actionChoices.isEmpty)
    }

    @Test func presentationUsesTheAppsGatewayNameAndHidesDetails() throws {
        let key = try PushDeviceKey(rawRepresentation: Self.privateKey)
        let notice = try key.open(PushNotice.self, from: Self.envelope)
        let shown = NoticePresentation(notice, gatewayName: "Home Server", slot: 2, showDetails: .unlocked, unlocked: true)
        #expect(shown.title == "Hermes needs your OK")
        #expect(shown.subtitle == "Disk cleanup on the NAS")
        #expect(shown.body == "Run rm -rf ~/snapshots/2026-0[1-8]-* on Home Server?")
        #expect(shown.categoryIdentifier == "APPROVAL.2")
        #expect(shown.interruptionLevel == .timeSensitive)
        let locked = NoticePresentation(notice, gatewayName: "Home Server", slot: 2, showDetails: .unlocked, unlocked: false)
        #expect(locked.title == "Hermes" && locked.subtitle.isEmpty && locked.body == "Needs your OK on Home Server")
        let never = NoticePresentation(notice, gatewayName: nil, slot: nil, showDetails: .never, unlocked: true)
        #expect(never.body == "Needs your OK on mac-mini" && never.categoryIdentifier == "APPROVAL")
        let task = NoticePresentation(PushNotice(kind: .task, id: "t", title: "Backup", body: "Done."), gatewayName: "NAS", slot: nil, showDetails: .always, unlocked: true)
        #expect(task.interruptionLevel == .passive && !task.plays)
    }

    @Test func categoriesCoverEverySlotTheContentExtensionLists() {
        let categories = NotificationCatalog.categories(slots: [0: "Home Server", 15: "VPS"])
        let ids = Set(categories.map(\.identifier))
        #expect(ids.isSuperset(of: ["APPROVAL", "QUESTION", "REPLY", "MESSAGE", "TASK", "OPEN", "APPROVAL.0", "QUESTION.15"]))
        let approval = categories.first { $0.identifier == "APPROVAL" }!
        #expect(approval.actions.map(\.identifier) == ["approval.once", "approval.deny", "approval.more"])
        #expect(approval.actions[0].options.contains(.authenticationRequired))
        #expect(approval.actions[1].options.contains(.destructive))
        #expect(!approval.actions.contains { $0.title.contains("Always") })
        #if os(iOS)
        #expect(categories.first { $0.identifier == "APPROVAL.0" }?.hiddenPreviewsBodyPlaceholder == "Needs your OK on Home Server")
        #endif
        #expect(NotificationCatalog.Category(identifier: "QUESTION.3") == .question)
        #expect(NotificationCatalog.Action.choiceIndex("question.choice.2") == 2)
    }

    @Test func sharedStoreSumsOpenRequestsAndAssignsSlots() {
        let shared = PushShared(suiteName: "push-tests-\(UUID().uuidString)")
        let home = UUID(), vps = UUID()
        #expect(shared.remember(installationID: "inst_a", appID: home, name: "Home").slot == 0)
        #expect(shared.remember(installationID: "inst_b", appID: vps, name: "VPS").slot == 1)
        #expect(shared.remember(installationID: "inst_c", appID: home, name: "Home").slot == 0)  // re-installed Hermes
        #expect(shared.gateways["inst_a"] == nil)
        shared.recordOpen(2, gateway: "inst_c")
        #expect(shared.recordOpen(1, gateway: "inst_b") == 3)
        // An older count never overwrites a newer one.
        #expect(shared.recordOpen(5, gateway: "inst_b", at: .now.addingTimeInterval(-60)) == 3)
        #expect(shared.recordOpen(0, gateway: "inst_c") == 1)
        shared.forget(appID: vps)
        #expect(shared.badge == 0)
        var prefs = shared.preferences
        prefs.tasks = .all
        shared.preferences = prefs
        #expect(shared.preferences.tasks == .all)
        #expect(shared.deviceID == shared.deviceID && shared.deviceID.hasPrefix("dev-"))
    }

    @Test func preferencesUseThePluginsKeys() throws {
        var prefs = PushPreferences()
        prefs.replyAfter = 45
        prefs.showDetails = .never
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(prefs))
        #expect(json["reply_after"]?.doubleValue == 45)
        #expect(json["show_details"]?.stringValue == "never")
        #expect(json["tasks"]?.stringValue == "all" && json["bots"]?.stringValue == "mentions")
        #expect(json["live_activity"]?.boolValue == true)
    }

    @Test func appPushClientSpeaksCommandDispatch() async throws {
        let calls = Calls()
        let client = AppPushClient { method, params in
            await calls.add(method, params)
            if params["arg"]?.stringValue?.hasPrefix("status") == true {
                return .object(["type": .string("plugin"), "output": .string(#"{"ok": true, "version": "1.0.0", "registered": true, "open": 3, "gateway": {"id": "inst_x", "name": "mac"}}"#)])
            }
            return .object(["type": .string("plugin"), "output": .string(#"{"ok": true, "gateway": {"id": "inst_x", "name": "mac"}, "relay": "ok", "version": "1.0.0"}"#)])
        }
        let device = AppPushClient.Device(id: "dev-1", token: "ab12", topic: "co.caffeinatedcode.hermes.dev", environment: "development",
                                          publicKey: "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=", platform: "ios", name: "iPhone", appVersion: "1.0")
        let registration = try await client.register(device, preferences: PushPreferences())
        #expect(registration == .init(installationID: "inst_x", gatewayName: "mac", relay: "ok", version: "1.0.0"))
        let status = try await client.status(deviceID: "dev-1")
        #expect(status.registered && status.open == 3 && status.installationID == "inst_x")
        let sent = await calls.all
        #expect(sent.first?.0 == "command.dispatch" && sent.first?.1["name"]?.stringValue == "app-push")
        let arg = try #require(sent.first?.1["arg"]?.stringValue)
        #expect(arg.hasPrefix("register {"))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(arg.dropFirst("register ".count).utf8))
        #expect(json["device_id"]?.stringValue == "dev-1" && json["preferences"]?["tasks"]?.stringValue == "all")

        let missing = AppPushClient { _, _ in throw GatewayRPCError(code: 4018, message: "not a quick/plugin/bundle/skill command: app-push") }
        await #expect(throws: AppPushClient.Failure.notInstalled) { try await missing.status(deviceID: "dev-1") }
        let refusing = AppPushClient { _, _ in .object(["type": .string("plugin"), "output": .string(#"{"ok": false, "error": "device not registered"}"#)]) }
        await #expect(throws: AppPushClient.Failure.refused("device not registered")) { try await refusing.test(deviceID: "dev-1") }
    }
}

private actor Calls {
    var all: [(String, [String: JSONValue])] = []
    func add(_ method: String, _ params: [String: JSONValue]) { all.append((method, params)) }
}
