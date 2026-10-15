import Foundation
import Testing
@testable import HermesKit

private func json(_ text: String) -> JSONValue {
    JSONValue.parse(text) ?? .null
}

private actor Calls {
    var list: [(method: String, params: [String: JSONValue])] = []
    func add(_ method: String, _ params: [String: JSONValue]) { list.append((method, params)) }
}

/// Shaped like `rollback.diff` for the design's 14:31 checkpoint: two edits and a new test.
private let reconnectDiff = """
diff --git a/Sources/Sync/Reconnect.swift b/Sources/Sync/Reconnect.swift
index 1111111..2222222 100644
--- a/Sources/Sync/Reconnect.swift
+++ b/Sources/Sync/Reconnect.swift
@@ -10,5 +10,8 @@ struct Reconnect {
 func reconnect() async {
-    try await socket.open()
+    try await withBackoff(max: 5) {
+        try await socket.open()
+    }
     await resume()
diff --git a/Tests/ReconnectTests.swift b/Tests/ReconnectTests.swift
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/Tests/ReconnectTests.swift
@@ -0,0 +1,3 @@
+import Testing
+
+@Test func reconnects() {}
"""

private let reconnectStat = """
 Sources/Sync/Backoff.swift      | 12 +++++++++---
 Sources/Sync/Reconnect.swift    |  4 +++-
 Tests/ReconnectTests.swift      |  3 +++
 3 files changed, 16 insertions(+), 4 deletions(-)
"""

@Suite("Checkpoints")
struct CheckpointsTests {
    @Test func listsCheckpointsAndReadsWhyEachWasTaken() {
        let list = CheckpointList(json: json(#"""
        {"enabled": true, "checkpoints": [
          {"hash": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "timestamp": "2026-10-15T14:31:07+02:00", "message": "before patch"},
          {"hash": "b2", "timestamp": "2026-10-15T14:35:00+02:00", "message": "pre-rollback snapshot (restoring to a1b2c3d4)"},
          {"hash": "c3", "timestamp": "2026-10-15T13:02:00+02:00", "message": "before terminal: rm -rf build [nested git repos not captured: vendor]"},
          {"hash": "", "timestamp": "", "message": "dropped"}
        ]}
        """#))
        #expect(list.enabled && list.checkpoints.count == 3)
        #expect(list.checkpoints[0].kind == .beforeEdit(tool: "patch"))
        #expect(list.checkpoints[1].kind == .beforeRestore(to: "a1b2c3d4"))
        #expect(list.checkpoints[2].kind == .beforeCommand("rm -rf build"))
        #expect(list.checkpoints[0].date == ISO8601DateFormatter().date(from: "2026-10-15T12:31:07Z"))
        #expect(!CheckpointList(json: json(#"{"enabled": false, "checkpoints": []}"#)).enabled)
    }

    @Test func diffSplitsPerFileWithExactCountsAndNewFiles() {
        let diff = CheckpointDiff(stat: reconnectStat, diff: reconnectDiff)
        #expect(!diff.isShortened)
        #expect(diff.added == 16 && diff.removed == 4)
        let reconnect = diff.files.first { $0.path == "Sources/Sync/Reconnect.swift" }
        #expect(reconnect?.added == 3 && reconnect?.removed == 1 && reconnect?.change == .modified)
        #expect(reconnect?.diff?.contains("withBackoff") == true)
        let tests = diff.files.first { $0.path == "Tests/ReconnectTests.swift" }
        #expect(tests?.change == .created && tests?.added == 3)
        // Just the hunks: no `new file mode` or `+++` lines for the card to show.
        #expect(tests?.diff?.hasPrefix("@@") == true && tests?.diff?.contains("new file mode") == false)
        // Not in the diff text: counted from the stat, restorable by its full path.
        let backoff = diff.files.first { $0.path == "Sources/Sync/Backoff.swift" }
        #expect(backoff?.diff == nil && backoff?.pathIsExact == true && (backoff?.added ?? 0) + (backoff?.removed ?? 0) == 12)
    }

    @Test func aDiffAtTheLimitSaysItsShortened() {
        let long = String(reconnectDiff.prefix(200)) + String(repeating: "+x\n", count: 2000)
        let diff = CheckpointDiff(stat: reconnectStat, diff: String(long.prefix(CheckpointDiff.diffLimit)))
        #expect(diff.isShortened)
        #expect(diff.files.first?.isPartial == true)
        // Its counts come from the stat, not the cut text.
        #expect(diff.files.first { $0.path == "Sources/Sync/Reconnect.swift" }?.added == 3)
        // A shortened stat path can't be restored on its own.
        let short = CheckpointDiff(stat: " .../Deep/Nested/File.swift | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)", diff: "")
        #expect(short.files.first?.pathIsExact == false)
    }

    @Test func restoreReadsEveryField() {
        let result = CheckpointRestoreResult(json: json(#"""
        {"success": true, "restored_to": "a1b2c3d4", "reason": "before patch", "directory": "/Users/v/Code/hermes-app",
         "restored_files": ["Sources/Sync/Reconnect.swift"], "skipped_oversize": ["Models/weights.bin"],
         "skipped_user_edits": [{"path": "README.md"}], "failed_deletes": ["Tests/ReconnectTests.swift"], "history_removed": 4}
        """#))
        #expect(result.success && result.restoredTo == "a1b2c3d4" && result.historyRemoved == 4)
        #expect(result.skippedOversize == ["Models/weights.bin"] && result.skippedUserEdits == ["README.md"])
        #expect(result.failedDeletes == ["Tests/ReconnectTests.swift"] && result.error == nil)
        let refused = CheckpointRestoreResult(json: json(#"{"success": false, "error": "Checkpoints are not taken for terminal.backend=docker: file paths belong to the container, not this host."}"#))
        #expect(!refused.success && refused.error?.hasPrefix("Checkpoints are not taken") == true)
    }

    @Test func busyMeansWaitOnEitherGateway() {
        #expect(CheckpointFailure(error: GatewayRPCError(code: 4009, message: "session busy — Hermes is still replying.")) == .busy)
        #expect(CheckpointFailure(error: GatewayRPCError(code: 4001, message: "session_busy")) == .busy)
        #expect(CheckpointFailure(error: GatewayRPCError(code: 5022, message: "Checkpoints are not taken for terminal.backend=docker")) == .refused("Checkpoints are not taken for terminal.backend=docker"))
        #expect(CheckpointFailure(error: GatewayRPCError(code: 4001, message: "session not found")) == nil)
        #expect(CheckpointFailure(error: URLError(.notConnectedToInternet)) == nil)
    }

    @Test func callsSendNoProfileAndTheFullHash() async throws {
        let calls = Calls()
        let client = CheckpointsClient { method, params in
            await calls.add(method, params)
            return json(#"{"success": true, "restored_to": "a1b2c3d4", "file": "Sources/Sync/Backoff.swift"}"#)
        }
        let hash = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
        _ = try await client.restore(sessionID: "rt_1", hash: hash, filePath: "Sources/Sync/Backoff.swift")
        _ = try await client.restore(sessionID: "rt_1", hash: hash)
        _ = try await client.dropLastTurn(sessionID: "rt_1")
        let sent = await calls.list
        #expect(sent[0].method == "rollback.restore" && sent[0].params["hash"]?.stringValue == hash && sent[0].params["file_path"]?.stringValue == "Sources/Sync/Backoff.swift")
        #expect(sent[1].params["file_path"] == nil && sent.allSatisfy { $0.params["profile"] == nil })
        #expect(sent[2].method == "session.undo" && sent[2].params["intent"]?.stringValue == "undo")
    }

    /// The bar counts a reply's own edits the way its diff cards show them.
    @Test func aRepliesEditsCountChangedLinesOnly() {
        var patch = ToolActivity(id: "1", name: "patch", status: .succeeded)
        patch.arguments = .object(["path": .string("Sources/Sync/Backoff.swift"),
                                   "old_string": .string("func next() -> Duration {\n    attempt += 1\n    return base * attempt"),
                                   "new_string": .string("func next() -> Duration {\n    attempt += 1\n    return min(base * attempt, cap)\n}")])
        var write = ToolActivity(id: "2", name: "write_file", status: .succeeded)
        write.arguments = .object(["path": .string("Tests/ReconnectTests.swift"), "content": .string("import Testing\n@Test func reconnects() {}")])
        var failed = ToolActivity(id: "3", name: "patch", status: .failed)
        failed.arguments = .object(["path": .string("README.md")])
        let read = ToolActivity(id: "4", name: "read_file", status: .succeeded)
        let turn = AssistantTurn(id: "t", steps: [.tool(patch), .tool(write), .tool(failed), .tool(read)])
        let edits = TurnFileEdits(turn: turn)
        #expect(edits.paths == ["Sources/Sync/Backoff.swift", "Tests/ReconnectTests.swift"])
        #expect(edits.added == 2 + 2 && edits.removed == 1)
        #expect(TurnFileEdits(turn: AssistantTurn(id: "u", steps: [.tool(read)])).isEmpty)
        // The card shows the same: kept lines as context.
        #expect(patch.displayDiff?.components(separatedBy: "\n").dropFirst(2).map { String($0.prefix(1)) } == [" ", " ", "-", "+", "+"])
    }

    @Test func turnsMatchCheckpointsByTime() {
        let base = Date(timeIntervalSince1970: 1_760_000_000.4)
        func user(_ id: String, _ text: String, _ offset: TimeInterval) -> TranscriptItem {
            .user(UserEntry(id: id, text: text, timestamp: base.addingTimeInterval(offset)))
        }
        let items: [TranscriptItem] = [
            user("u1", "Bump swift-collections", 0), .assistant(AssistantTurn(id: "t1")),
            user("u2", "Add backoff to the sync client", 600), .assistant(AssistantTurn(id: "t2")),
            user("u3", "Fix the reconnect after sleep", 1200), .assistant(AssistantTurn(id: "t3")),
        ]
        let matcher = CheckpointMatcher(items: items)
        func checkpoint(_ hash: String, _ offset: TimeInterval, _ message: String = "before patch") -> Checkpoint {
            // Whole seconds, as git writes them.
            Checkpoint(hash: hash, date: Date(timeIntervalSince1970: (base.timeIntervalSince1970 + offset).rounded(.down)), message: message)
        }
        let checkpoints = [
            checkpoint("h5", 1300, "pre-rollback snapshot (restoring to h4)"),
            checkpoint("h4", 1210), checkpoint("h3", 1203),
            checkpoint("h2", 610),
            checkpoint("h1", 0), // the same second the message was sent
        ]
        #expect(matcher.checkpoint(beforeTurn: "t3", in: checkpoints)?.hash == "h3")
        #expect(matcher.checkpoint(beforeTurn: "t1", in: checkpoints)?.hash == "h1")
        #expect(matcher.span(of: checkpoints[0]) == nil)
        // Going back to before "Add backoff" takes that turn and the one after it.
        #expect(matcher.turnsRemoved(restoring: checkpoints[3]).map(\.userID) == ["u2", "u3"])
        // The restore's own snapshot still costs the newest turn.
        #expect(matcher.turnsRemoved(restoring: checkpoints[0]).map(\.userID) == ["u3"])
        // One row per turn, newest first, plus the snapshot.
        #expect(matcher.timeline(checkpoints).map(\.hash) == ["h5", "h3", "h2", "h1"])
    }
}
