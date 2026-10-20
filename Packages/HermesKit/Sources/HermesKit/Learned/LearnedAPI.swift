import Foundation

// What Hermes Learned's REST calls (`docs/learned.md` §1). Every call names the Bot's profile:
// each Bot learns on its own.

extension BackendClient {
    private static func profileItems(_ profile: String?) -> [URLQueryItem] {
        guard let profile, !profile.isEmpty else { return [] }
        return [URLQueryItem(name: "profile", value: profile)]
    }

    /// Everything learned (`GET /api/learning/graph`).
    public func learningGraph(profile: String?) async throws -> LearningGraph {
        LearningGraph(json: try await rest("api/learning/graph", query: Self.profileItems(profile)))
    }

    /// A skill's SKILL.md (`GET /api/learning/node`).
    public func learnedSkillText(id: String, profile: String?) async throws -> String {
        let json = try await rest("api/learning/node", query: [URLQueryItem(name: "id", value: id)] + Self.profileItems(profile))
        return json["content"]?.stringValue ?? ""
    }

    /// Rewrites a skill's SKILL.md (`PUT /api/learning/node`).
    public func editLearnedSkill(id: String, content: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["id": .string(id), "content": .string(content)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await rest("api/learning/node", method: "PUT", query: Self.profileItems(profile), body: .object(body))
    }

    /// Archives a skill (`DELETE /api/learning/node`); Tidying restores it.
    public func archiveLearnedSkill(id: String, profile: String?) async throws {
        var body: [String: JSONValue] = ["id": .string(id)]
        if let profile, !profile.isEmpty { body["profile"] = .string(profile) }
        _ = try await rest("api/learning/node", method: "DELETE", query: Self.profileItems(profile), body: .object(body))
    }

    /// Where a skill's SKILL.md is on the gateway (`GET /api/skills/content`), for the Inspector's
    /// File tab.
    public func skillFilePath(name: String, profile: String?) async throws -> String? {
        try await rest("api/skills/content", query: [URLQueryItem(name: "name", value: name)] + Self.profileItems(profile))["path"]?.stringValue
    }

    // MARK: The curator

    public func curatorStatus(profile: String?) async throws -> CuratorStatus {
        CuratorStatus(json: try await rest("api/curator", query: Self.profileItems(profile)))
    }

    /// The Tidying switch (`PUT /api/curator/paused`).
    public func setCuratorPaused(_ paused: Bool, profile: String?) async throws {
        _ = try await rest("api/curator/paused", method: "PUT", query: Self.profileItems(profile), body: .object(["paused": .bool(paused)]))
    }

    /// Tidy Up Now (`POST /api/curator/run`): runs in the background; follow `curatorRunState()`.
    public func runCurator(profile: String?) async throws {
        _ = try await rest("api/curator/run", method: "POST", query: Self.profileItems(profile), body: .object([:]))
    }

    /// Whether the tidy started with `runCurator` is still running (`GET
    /// /api/actions/curator-run/status`), and how it ended.
    public func curatorRunState() async throws -> (running: Bool, exitCode: Int?) {
        let json = try await rest("api/actions/curator-run/status", query: [URLQueryItem(name: "lines", value: "20")])
        return (json["running"]?.boolValue ?? false, json["exit_code"]?.truncatedIntValue)
    }

    /// The newest tidy report (`logs/curator/<stamp>/run.json` under the profile's Hermes
    /// folder), read through the managed files (`/api/files`, `/api/files/read`). Nil when there
    /// is none or the gateway doesn't let the app read it.
    public func latestCuratorReport(profile: String?) async throws -> CuratorReport? {
        for folder in try await curatorLogFolders(profile: profile) {
            guard let listing = try? await rest("api/files", query: [URLQueryItem(name: "path", value: folder)]) else { continue }
            let runs = listing["entries"].items
                .filter { $0["is_directory"]?.boolValue ?? false }
                .compactMap { $0["path"]?.stringValue ?? $0["name"]?.stringValue.map { folder + "/" + $0 } }
                .sorted(by: >)
            for run in runs.prefix(3) {
                guard let file = try? await rest("api/files/read", query: [URLQueryItem(name: "path", value: run + "/run.json")]),
                      let data = Self.dataURLBytes(file["data_url"]?.stringValue),
                      let json = JSONValue.parse(data) else { continue }
                return CuratorReport(json: json)
            }
        }
        return nil
    }

    /// Where a profile's curator reports may be: from the gateway's Hermes home when it says,
    /// else the default layout under the files root (`~/.hermes`, `profiles/<name>`).
    private func curatorLogFolders(profile: String?) async throws -> [String] {
        var folders: [String] = []
        if let home = (try? await rest("api/status", query: Self.profileItems(profile)))?["hermes_home"]?.stringValue, !home.isEmpty {
            folders.append(home + "/logs/curator")
        }
        let listing = try await rest("api/files")
        let named = profile.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        var roots: [String] = []
        if let locked = listing["locked_root"]?.stringValue, !locked.isEmpty {
            roots.append(locked)
        } else if let home = listing["path"]?.stringValue, !home.isEmpty {
            roots.append(home + "/.hermes")
        }
        for root in roots {
            folders.append(named.map { root + "/profiles/\($0)/logs/curator" } ?? root + "/logs/curator")
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0).inserted }
    }

    static func dataURLBytes(_ dataURL: String?) -> Data? {
        guard let dataURL, let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }
}
