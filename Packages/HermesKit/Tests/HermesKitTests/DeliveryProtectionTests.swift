import Foundation
import Testing
@testable import HermesKit

@Suite("Whether a Bot's delivery outlives the sender's chat")
struct DeliveryProtectionTests {
    /// `message_agent`'s delivery as `process.list` shows it: Hermes's own runner script.
    private let delivery = "/Users/ada/.hermes/hermes-agent/venv/bin/python /Users/ada/.hermes/hermes-agent/tools/bot_mode_dm.py "
        + "--run-delivery query-file /Users/ada/.hermes/bot_dm/dm_1.txt hermes -p engineer chat --in ~ -c 'Bot Chat'"

    private func listed(_ id: String, _ command: String, persists: Bool) -> JSONValue {
        var row: [String: JSONValue] = ["session_id": .string(id), "command": .string(command), "status": .string("running"),
                                        "notify_on_complete": .bool(true)]
        // Hermes lists the flag only when it's set.
        if persists { row["persist_on_release"] = .bool(true) }
        return .object(row)
    }

    @Test func aDeliveryWithoutTheFlagIsUnprotected() {
        var tracker = ProcessTracker()
        tracker.apply(list: [listed("proc_a", delivery, persists: false), listed("proc_b", "npm run dev", persists: false)])
        #expect(tracker.processes.first?.isBotDelivery == true)
        #expect(tracker.processes.last?.isBotDelivery == false)
        #expect(DeliveryProtection.seen(in: tracker.processes, version: "0.22.2") == DeliveryProtection(version: "0.22.2", protected: false))
    }

    @Test func aDeliveryWithTheFlagIsProtected() {
        var tracker = ProcessTracker()
        tracker.apply(list: [listed("proc_a", delivery, persists: true)])
        #expect(DeliveryProtection.seen(in: tracker.processes, version: "0.22.2") == DeliveryProtection(version: "0.22.2", protected: true))
    }

    @Test func noDeliveryTellsNothing() {
        var tracker = ProcessTracker()
        tracker.apply(list: [listed("proc_b", "npm run dev", persists: false)])
        #expect(DeliveryProtection.seen(in: tracker.processes, version: "0.22.2") == nil)
    }

    /// A record holds for its version until a later look says otherwise; an update starts over.
    @Test func theRecordFollowsTheVersion() {
        let fixed = DeliveryProtection(version: "0.22.2", protected: true)
        #expect(DeliveryProtection.updated(fixed, seen: nil, version: "0.22.2") == fixed)
        #expect(DeliveryProtection.updated(fixed, seen: nil, version: "0.23.0") == nil)
        let undone = DeliveryProtection(version: "0.22.2", protected: false)
        #expect(DeliveryProtection.updated(fixed, seen: undone, version: "0.22.2") == undone)
    }
}
