import Foundation
import Testing
@testable import HermesKit

/// The widget contract (`docs/widgets.md` §3): the bundled examples, the invalid fixtures and
/// the client's fail-closed reading.
@Suite("Widget contract")
struct WidgetContractTests {
    static let examples = WidgetSpec.shared.examples()

    static let invalid: [(name: String, json: JSONValue)] = {
        guard let folder = Bundle.module.url(forResource: "Fixtures/widgets/invalid", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            // `{"$comment": <why it must fail>, "payload": {…}}`
            guard let data = try? Data(contentsOf: url), let payload = JSONValue.parse(data)?["payload"] else { return nil }
            return (url.deletingPathExtension().lastPathComponent, payload)
        }
    }()

    /// Invalid fixtures the client still draws, because the only fault is one the contract's
    /// fail-closed table forgives (the plugin refuses them all).
    static let forgivenByClient: Set<String> = ["metric-1", "outline-2", "sources-2", "status-2"]

    @Test func catalogueAndModelsAgree() {
        #expect(WidgetSpec.shared.catalog.map(\.type) == WidgetType.allCases.map(\.rawValue))
        #expect(WidgetSpec.shared.catalog.count == 35)
    }

    @Test func everyTypeHasExamples() {
        for type in WidgetType.allCases {
            #expect(!WidgetSpec.shared.examples(for: type).isEmpty, "no example for \(type.rawValue)")
        }
    }

    @Test(arguments: examples.map(\.name))
    func exampleValidatesAndDecodes(_ name: String) throws {
        let json = try #require(Self.examples.first { $0.name == name }?.json)
        #expect(WidgetReader.strictFailures(json) == [])
        let result = WidgetReader.read(json)
        guard case .ready(let payload) = result else {
            Issue.record("\(name) fell back: \(result)")
            return
        }
        #expect(payload.type.rawValue == json["type"]?.stringValue)
        #expect(payload.id == json["id"]?.stringValue)
    }

    @Test func invalidFixturesAreThere() {
        #expect(Self.invalid.count == 117)
    }

    @Test(arguments: invalid.map(\.name))
    func invalidPayloadIsRejected(_ name: String) throws {
        let json = try #require(Self.invalid.first { $0.name == name }?.json)
        #expect(!WidgetReader.strictFailures(json).isEmpty, "\(name) passed the strict checks")
        let result = WidgetReader.read(json)
        if Self.forgivenByClient.contains(name) {
            #expect(result.payload != nil, "\(name) should be forgiven: \(result)")
        } else {
            #expect(result.payload == nil, "\(name) was drawn")
        }
    }

    @Test func forgivenFixturesReadSafely() throws {
        let metric = try #require(Self.invalid.first { $0.name == "metric-1" }?.json)
        #expect(WidgetReader.read(metric).payload?.json["sensitivty"] == nil)
        let status = try #require(Self.invalid.first { $0.name == "status-2" }?.json)
        guard case .status(let widget)? = WidgetReader.read(status).payload?.content else {
            Issue.record("status-2 didn't read as status")
            return
        }
        #expect(widget.items.first?.state == .info)
        let outline = try #require(Self.invalid.first { $0.name == "outline-2" }?.json)
        guard case .outline(let tree)? = WidgetReader.read(outline).payload?.content else {
            Issue.record("outline-2 didn't read as outline")
            return
        }
        #expect(tree.nodes.first?.state == .unknown)
        // A link the app can't open (http) is dropped, not followed.
        let sources = try #require(Self.invalid.first { $0.name == "sources-2" }?.json)
        guard case .sources(let list)? = WidgetReader.read(sources).payload?.content else {
            Issue.record("sources-2 didn't read as sources")
            return
        }
        #expect(list.items.first?.url == nil)
    }

    // MARK: - Failing closed (payload contract §10)

    private func metric(_ extra: [String: JSONValue] = [:], removing: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": "metric", "v": 1, "id": "w_test0001", "title": "Revenue",
            "as_of": "2026-10-16T09:41:00+02:00", "fallback_text": "Revenue: €1,284.",
            "items": [["label": "Revenue", "value": ["value": 1284.5, "format": "currency", "currency": "EUR"]]],
        ]
        for (key, value) in extra { object[key] = value }
        for key in removing { object[key] = nil }
        return .object(object)
    }

    @Test func unknownSensitivityIsPrivate() {
        let payload = WidgetReader.read(metric(["sensitivity": "secret"])).payload
        #expect(payload?.isPrivate == true)
    }

    @Test func unknownFieldsAreIgnored() {
        let payload = WidgetReader.read(metric(["colour": "red"])).payload
        #expect(payload != nil)
        #expect(payload?.json["colour"] == nil)
    }

    @Test func unknownStateIsInfo() {
        let payload = WidgetReader.read(metric(["state": "great", "state_label": "Great"])).payload
        #expect(payload?.envelope.state == .info)
        #expect(payload?.envelope.stateLabel == "Great")
    }

    @Test func unknownLayoutIsTheDefault() {
        guard case .metric(let widget)? = WidgetReader.read(metric(["layout": "carousel"])).payload?.content else {
            Issue.record("didn't read")
            return
        }
        #expect(widget.layout == .auto)
    }

    @Test func unknownActionKindAndSchemeAreDropped() {
        let actions: JSONValue = [
            ["id": "call", "label": "Call", "kind": "dial"],
            ["id": "site", "label": "Site", "kind": "open", "url": "http://example.com"],
            ["id": "more", "label": "More"],
        ]
        let payload = WidgetReader.read(metric(["actions": actions])).payload
        #expect(payload?.envelope.actions?.map(\.id) == ["more"])
    }

    @Test func missingRequiredFieldFallsBack() {
        let result = WidgetReader.read(metric(removing: ["items"]))
        guard case .fallback(let fallback) = result else {
            Issue.record("drawn without its items")
            return
        }
        #expect(fallback.text == "Revenue: €1,284.")
        #expect(fallback.reason == .invalid("(root): 'items' is a required property"))
    }

    @Test func unknownTypeAndNewerVersionFallBack() {
        #expect(WidgetReader.read(metric(["type": "hologram"])) == .fallback(WidgetFallback(
            id: "w_test0001", rev: 1, type: "hologram", title: "Revenue", text: "Revenue: €1,284.",
            reason: .unknownType("hologram"), isPrivate: false, json: metric(["type": "hologram"]))))
        guard case .fallback(let newer) = WidgetReader.read(metric(["v": 2])) else {
            Issue.record("v2 drawn")
            return
        }
        #expect(newer.reason == .newerVersion(2))
    }

    @Test func invalidFallbackWithUnknownSensitivityStaysPrivate() {
        guard case .fallback(let fallback) = WidgetReader.read(metric(["sensitivity": "family"], removing: ["items"])) else {
            Issue.record("drawn")
            return
        }
        #expect(fallback.isPrivate)
    }

    @Test func approvalOfUnknownKindIsATransfer() throws {
        var approval = try #require(Self.examples.first { $0.name == "approval-1" }?.json)
        guard case .object(var object) = approval, case .object(var subject)? = object["subject"] else { return }
        subject["kind"] = "escrow"
        object["subject"] = .object(subject)
        approval = .object(object)
        let result = WidgetReader.read(approval)
        if case .approval(let widget)? = result.payload?.content {
            #expect(widget.subject.kind == .transfer)
        } else {
            // A transfer must name its cost; without one the approval can only be text.
            guard case .fallback(let fallback) = result else { return }
            #expect(fallback.reason == .invalid("consequences: 'cost' is a required property"))
        }
    }

    // MARK: - Client rules

    @Test func reservedOrRepeatedActionIDsFallBack() {
        #expect(WidgetReader.read(metric(["actions": [["id": "approve", "label": "OK"]]])).payload == nil)
        #expect(WidgetReader.read(metric(["actions": [["id": "go", "label": "Go"], ["id": "go", "label": "Again"]]])).payload == nil)
    }

    @Test func anAlertMayOfferAcknowledge() throws {
        guard case .object(var alert) = try #require(Self.examples.first { $0.name == "alert-1" }?.json) else { return }
        alert["actions"] = [["id": "acknowledge", "label": "Acknowledge"]]
        #expect(WidgetReader.read(.object(alert)).payload != nil)
    }

    @Test func twoPrimaryActionsFallBack() {
        let actions: JSONValue = [["id": "a", "label": "A", "style": "primary"], ["id": "b", "label": "B", "style": "primary"]]
        #expect(WidgetReader.read(metric(["actions": actions])).payload == nil)
    }

    @Test func destructiveNeedsConfirm() {
        #expect(WidgetReader.read(metric(["actions": [["id": "drop", "label": "Delete", "style": "destructive"]]])).payload == nil)
        let confirmed: JSONValue = [["id": "drop", "label": "Delete", "style": "destructive", "confirm": ["title": "Delete it?"]]]
        #expect(WidgetReader.read(metric(["actions": confirmed])).payload != nil)
    }

    @Test func valuesDecodeByJSONType() throws {
        let values = try JSONDecoder().decode([WidgetValue].self, from: Data(#"[true, 1, 2.5, "x", null]"#.utf8))
        #expect(values == [.bool(true), .number(1), .number(2.5), .string("x"), .null])
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
    }
}
