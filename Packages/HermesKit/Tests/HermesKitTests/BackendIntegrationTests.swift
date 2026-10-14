import Foundation
import Testing
@testable import HermesKit

/// Runs against `Tools/mock-hermes/backend.py` when `HERMES_MOCK_BACKEND` is set
/// (e.g. `HERMES_MOCK_BACKEND=http://127.0.0.1:19119 swift test`).
@Suite("Mock backend round trip", .enabled(if: ProcessInfo.processInfo.environment["HERMES_MOCK_BACKEND"] != nil))
struct BackendIntegrationTests {
    private var baseURL: URL { URL(string: ProcessInfo.processInfo.environment["HERMES_MOCK_BACKEND"]!)! }

    private func connect() async throws -> (BackendClient, GatewaySocket) {
        let client = BackendClient(baseURL: baseURL, credential: nil)
        _ = try await client.discoverSessionToken()
        let socket = GatewaySocket(url: try await client.gatewaySocketURL())
        try await socket.connect()
        return (client, socket)
    }

    @Test func rosterAndTranscript() async throws {
        let (client, socket) = try await connect()
        defer { Task { await socket.close() } }
        #expect(try await client.status().authRequired == false)

        let result = try await socket.request("profiles.list", [:])
        guard case .array(let rows)? = result["profiles"] else {
            Issue.record("no profiles")
            return
        }
        let bots = rows.map(BotProfile.init(json:))
        #expect(bots.map(\.title).contains("Research Buddy"))
        let researcher = try #require(bots.first { $0.name == "researcher" })
        let chat = try #require(researcher.canonicalSession)
        let transcript = try await client.transcript(storedSessionID: chat.resolvedID, profile: researcher.name)
        #expect(transcript.messages.count >= 4)

        let asset = try await socket.request("profiles.get_asset", ["name": .string("ops"), "asset": .string("avatar")])
        #expect(asset["data"]?.stringValue?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func botChatTurnStreamsAndSettles() async throws {
        let (_, socket) = try await connect()
        defer { Task { await socket.close() } }
        let list = try await socket.request("session.list", ["profile": .string("writer"), "title": .string(botChatTitle), "include_hidden": .bool(true)])
        guard case .array(let sessions)? = list["sessions"], let stored = sessions.first?["id"]?.stringValue else {
            Issue.record("no Bot Chat")
            return
        }
        let resumed = try await socket.request("session.resume", ["session_id": .string(stored), "profile": .string("writer"), "omit_messages": .bool(true)])
        let runtime = try #require(resumed["session_id"]?.stringValue)

        let messages = await socket.messages()
        _ = try await socket.request("prompt.submit", ["session_id": .string(runtime), "text": .string("What's new?")])
        var live = LiveTurn(id: "t", sessionID: runtime)
        var settled = false
        for await message in messages {
            guard case .frame(.event(let event)) = message, event.sessionID == runtime else { continue }
            for decoded in GatewayTurnDecoder.decode(event) {
                if decoded.event == .settled { settled = true }
                live.apply(decoded)
            }
            if settled { break }
        }
        #expect(live.turn.state == .complete)
        #expect(live.turn.answer.contains("Here's what I found"))
        #expect(!live.turn.reasoningText.isEmpty)
        #expect(live.turn.steps.contains { if case .tool(let tool) = $0 { tool.status == .succeeded && tool.callID != nil } else { false } })
    }

    @Test func approvalsAreServerRequests() async throws {
        let (_, socket) = try await connect()
        defer { Task { await socket.close() } }
        let created = try await socket.request("session.create", ["profile": .string("default"), "title": .string("scratch")])
        let runtime = try #require(created["session_id"]?.stringValue)
        let messages = await socket.messages()
        _ = try await socket.request("prompt.submit", ["session_id": .string(runtime), "text": .string("please approve the cleanup")])
        var answer = ""
        for await message in messages {
            switch message {
            case .frame(.request(let request)):
                let approval = try #require(GatewayTurnDecoder.approval(from: request))
                #expect(approval.command?.contains("rm -rf") == true)
                await socket.respond(to: request.id, result: .object(["choice": .string("once"), "all": .bool(false)]))
            case .frame(.event(let event)) where event.sessionID == runtime:
                if event.type == "message.complete" { answer = event.payload["text"]?.stringValue ?? "" }
                if event.type == "session.info", event.payload["running"]?.boolValue == false { break }
                continue
            default:
                continue
            }
            if !answer.isEmpty { break }
        }
        #expect(answer.contains("approved: `once`"))
    }

    @Test func routinesRoundTrip() async throws {
        let (_, socket) = try await connect()
        defer { Task { await socket.close() } }
        let added = try await socket.request("cron.manage", [
            "action": .string("add"), "profile": .string("writer"), "name": .string("[bot:writer] Tea reminder"),
            "schedule": .string("in 30m"), "prompt": .string("Remind me to drink tea"), "deliver": .string("bot-chat"),
        ])
        let id = try #require(added["job_id"]?.stringValue)
        let listed = try await socket.request("cron.manage", ["action": .string("list"), "profile": .string("writer"), "include_disabled": .bool(true)])
        guard case .array(let jobs)? = listed["jobs"] else {
            Issue.record("no jobs")
            return
        }
        let routines = jobs.compactMap(BotRoutine.init(json:))
        #expect(routines.contains { $0.id == id && $0.title == "Tea reminder" && $0.deliversToBotChat })
        _ = try await socket.request("cron.manage", ["action": .string("remove"), "profile": .string("writer"), "name": .string(id)])
    }

    @Test func badTokenIsRejected() async throws {
        let socket = GatewaySocket(url: URL(string: baseURL.absoluteString.replacingOccurrences(of: "http", with: "ws") + "/api/ws?token=wrong")!)
        await #expect(throws: (any Error).self) { try await socket.connect() }
    }
}

/// Read-only checks against a real local `hermes serve` (`HERMES_REAL_BACKEND=http://127.0.0.1:9119`).
/// Never submits prompts, so it costs nothing.
@Suite("Real backend (read-only)", .enabled(if: ProcessInfo.processInfo.environment["HERMES_REAL_BACKEND"] != nil))
struct RealBackendReadOnlyTests {
    @Test func rosterDecodes() async throws {
        let client = BackendClient(baseURL: URL(string: ProcessInfo.processInfo.environment["HERMES_REAL_BACKEND"]!)!, credential: nil)
        let status = try await client.status()
        print("[real] version \(status.version ?? "?") auth_required \(status.authRequired)")
        _ = try await client.discoverSessionToken()
        let socket = GatewaySocket(url: try await client.gatewaySocketURL())
        try await socket.connect()
        defer { Task { await socket.close() } }
        let result = try await socket.request("profiles.list", [:])
        guard case .array(let rows)? = result["profiles"] else {
            Issue.record("no profiles in \(result)")
            return
        }
        for bot in rows.map(BotProfile.init(json:)) {
            print("[real] bot \(bot.name) title=\(bot.title) handle=@\(bot.handle) botChat=\(bot.canonicalSession != nil) last=\(bot.lastActive.map { "\($0)" } ?? "-") rev=\(bot.metaRevision.map(String.init) ?? "-") avatar=\(bot.hasAvatar)")
            let list = try await socket.request("session.list", ["profile": .string(bot.name), "title": .string(botChatTitle), "include_hidden": .bool(true), "limit": .number(200)])
            print("[real]   session.list Bot Chat -> \(list["sessions"].map { if case .array(let a) = $0 { a.count } else { -1 } } ?? -1) rows")
            let cron = try await socket.request("cron.manage", ["action": .string("list"), "profile": .string(bot.name), "include_disabled": .bool(true)])
            let jobs: [JSONValue] = if case .array(let jobs)? = cron["jobs"] { jobs } else { [] }
            print("[real]   routines: \(jobs.compactMap(BotRoutine.init(json:)).map { "\($0.title) [\($0.schedule)] bot=\($0.taggedBot ?? "-")" })")
        }
        #expect(!rows.isEmpty)
    }
}
