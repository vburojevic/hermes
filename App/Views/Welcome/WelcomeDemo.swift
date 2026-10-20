import HermesKit
import SwiftUI

/// What the welcome tour shows (`screens/iphone/welcome.elyx`): fixed demo states for the app's
/// real components. Nothing here talks to a gateway.
@MainActor
enum WelcomeDemo {
    // MARK: Page 1: a message and an approval

    static let question = UserEntry(id: "welcome-question", text: String(localized: "Free up space on the NAS. Old snapshots are fine to go."))

    static let approval: ApprovalRequest = {
        var request = ApprovalRequest(
            requestID: "welcome-approval",
            command: "find /volume1/@snapshots -mtime +30 -delete",
            description: String(localized: "Recursive delete"),
            choices: [.once, .session, .always, .deny]
        )
        request.toolName = "terminal"
        return request
    }()

    // MARK: Page 2: Bots

    struct Bot: Identifiable {
        let name: String
        let handle: String
        let appearance: BotAppearance
        var id: String { handle }
    }

    static let bots = [
        Bot(name: "Ada", handle: "ada", appearance: BotAppearance(profile: "ada", shape: "cloud", color: "#DD4B94", customized: true)),
        Bot(name: "Research Buddy", handle: "researcher", appearance: BotAppearance(profile: "researcher", shape: "hexagon", color: "#4BDD94", customized: true)),
        Bot(name: "Scout", handle: "scout", appearance: BotAppearance(profile: "scout", shape: "triangle", color: "#DD944B", customized: true)),
    ]

    static let digest = String(localized: "Your digest is in: 3 new papers on KV caches. The second one halves memory use. Want summaries?")

    /// 08:00 today.
    static var digestTime: Date {
        Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: .now) ?? .now
    }

    // MARK: Page 3: the Board and the Inspector pill

    /// The running card has been going for a little under six minutes, so its clock turns over
    /// while the page is up.
    static func board(now: Date = .now) -> BoardModel {
        let model = BoardModel(demoProjectID: "welcome")
        let running = BoardCard(
            id: "t_9e2a91c", title: String(localized: "Fix the reconnect after sleep"), column: "running", assignee: "default",
            currentRunStartedAt: now.addingTimeInterval(-5 * 60 - 54), lastHeartbeatAt: .distantFuture,
            latestSummary: String(localized: "Running swift test · 212 of 240 passed")
        )
        let needsYou = BoardCard(
            id: "t_77bc4e8", title: String(localized: "Write the App Store listing"), column: "blocked", assignee: "ada",
            latestSummary: String(localized: "Which category: Developer Tools or Productivity?"), commentCount: 2, blockKind: "needs_input"
        )
        let review = BoardCard(
            id: "t_31d3fa2", title: String(localized: "Add Increase Contrast snapshot tests"), column: "review", assignee: "scout",
            latestSummary: String(localized: "Added 46 snapshots; 2 colours fixed to reach 7:1.")
        )
        let checks = BoardChecks(ok: true, classification: "success", prURL: URL(string: "https://github.com/studio/hermes-app/pull/142"))
        model.showDemo(
            BoardSnapshot(lanes: [
                BoardLane(key: "running", cards: [running]),
                BoardLane(key: "blocked", cards: [needsYou]),
                BoardLane(key: "review", cards: [review]),
            ]),
            extras: [review.id: BoardCardExtras(checks: checks)],
            faces: ["default": BotAppearance(profile: "default"), "ada": bots[0].appearance, "scout": bots[2].appearance],
            now: now
        )
        return model
    }

    // MARK: Page 4: the learning map and a memory note

    static let memory = MemoryChange(kind: .saved, store: .about, text: String(localized: "you prefer 24-hour times"))

    /// The map in `learningMapCompact`: two well-used skills, the ones around them, memories as dots.
    static func learned() -> LearnedModel {
        let model = LearnedModel(workspace: workspace)
        model.showDemo(graph)
        return model
    }

    static let graph: LearningGraph = {
        func skill(_ id: String, _ category: String, _ uses: Int) -> LearningNode {
            LearningNode(id: id, kind: .skill, label: id, category: category, useCount: uses, createdBy: "agent")
        }
        func memory(_ index: Int) -> LearningNode {
            LearningNode(id: "memory:welcome:\(index)", kind: .memory, label: "", category: "memory")
        }
        let skills = [
            skill("ios-testing", "ios", 12), skill("xcode-build", "ios", 9), skill("swiftui-previews", "ios", 3),
            skill("app-store-listing", "writing", 2), skill("release-notes", "writing", 7), skill("changelog-style", "writing", 2),
            skill("nas-backups", "home", 8), skill("docker-compose", "home", 3), skill("synology-dsm", "home", 2),
            skill("arxiv-digest", "research", 6), skill("paper-summary", "research", 2),
        ]
        let memories = (0..<9).map(memory)
        let links: [(String, String)] = [
            ("ios-testing", "xcode-build"), ("ios-testing", "swiftui-previews"), ("xcode-build", "swiftui-previews"),
            ("ios-testing", "app-store-listing"), ("app-store-listing", "release-notes"), ("release-notes", "changelog-style"),
            ("ios-testing", "synology-dsm"), ("synology-dsm", "nas-backups"), ("nas-backups", "docker-compose"),
            ("arxiv-digest", "paper-summary"),
            ("ios-testing", "memory:welcome:0"), ("xcode-build", "memory:welcome:1"), ("nas-backups", "memory:welcome:2"),
            ("docker-compose", "memory:welcome:3"), ("release-notes", "memory:welcome:4"), ("changelog-style", "memory:welcome:5"),
            ("arxiv-digest", "memory:welcome:6"), ("paper-summary", "memory:welcome:7"), ("app-store-listing", "memory:welcome:8"),
        ]
        return LearningGraph(nodes: skills + memories, edges: links.map { LearningEdge(source: $0.0, target: $0.1) })
    }()

    /// A gateway that is never connected: the map's model needs one to hang off.
    private static let workspace: BotWorkspace = {
        let folder = FileManager.default.temporaryDirectory.appending(path: "welcome-demo", directoryHint: .isDirectory)
        let bot = BotConfiguration(name: "Studio Mac", baseURL: URL(string: "http://127.0.0.1:8642")!, accent: "gold")
        let store = BotStore(fileURL: folder.appending(path: "bots.json"), keychain: KeychainStore(service: "co.caffeinatedcode.hermes.welcome-demo"))
        return BotWorkspace(bot: bot, apiKey: nil, store: store)
    }()
}
