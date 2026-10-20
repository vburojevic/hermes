import Foundation
import Testing
@testable import HermesKit

/// The mock's catalog feed (`Tools/mock-hermes/plugin-catalog.json`), shaped like Hermes's.
private func fixtureCatalog() throws -> PluginCatalog {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../Tools/mock-hermes/plugin-catalog.json").standardizedFileURL
    return try PluginCatalog(data: try Data(contentsOf: url))
}

private func row(_ name: String, catalog: String? = nil, status: String = "enabled") -> HermesPlugin {
    var json: [String: JSONValue] = ["name": .string(name), "key": .string(name), "version": .string("1.0"),
                                     "source": .string("user"), "status": .string(status)]
    if let catalog { json["catalog_name"] = .string(catalog) }
    return HermesPlugin(json: .object(json))!
}

private func curated(_ name: String, state: String = "present") -> CatalogPlugin {
    CatalogPlugin(name: name, title: name.capitalized, description: "", tier: "official", appState: state)
}

@Suite("Plugin offers")
struct PluginOffersTests {
    @Test func theFeedReads() throws {
        let catalog = try fixtureCatalog()
        #expect(catalog.entries.count == 20)
        let blender = try #require(catalog.entry(named: "blender"))
        #expect(blender.isOfficial && blender.category == "desktop")
        #expect(blender.summary == "Build, light and render scenes in Blender.")
        #expect(blender.disclosure == "tools execute arbitrary Python in Blender with your privileges; first start downloads the pinned Blender Lab MCP server and its Python dependencies.")
        #expect(blender.knownIssues.count == 1)
        #expect(catalog.entry(named: "langfuse")?.capabilities.env == ["HERMES_LANGFUSE_PUBLIC_KEY", "HERMES_LANGFUSE_SECRET_KEY"])
        #expect(catalog.entry(named: "nvidia-app")?.disclosure?.hasPrefix("the tools read and change") == true, "Disclosure: works too")
        #expect(catalog.removed.map(\.name) == ["agent-ledger", "or-picker"])
    }

    @Test func pulledPluginsAreFoundByNameOrRepo() throws {
        let catalog = try fixtureCatalog()
        #expect(catalog.removal(name: "agent-ledger", catalogName: nil)?.reason.hasPrefix("It sent approval") == true)
        #expect(catalog.removal(name: "ledger", catalogName: nil, repo: "git@github.com:Ledger-Labs/agent-ledger.git") != nil)
        #expect(catalog.removal(name: "blender", catalogName: "blender") == nil)
    }

    @Test func platformsAndHermesVersions() throws {
        let catalog = try fixtureCatalog()
        let nvidia = try #require(catalog.entry(named: "nvidia-app"))
        #expect(!nvidia.runs(on: "Darwin") && nvidia.runs(on: "Windows"))
        #expect(try #require(catalog.entry(named: "blender")).runs(on: "Darwin"))
        let palace = try #require(catalog.entry(named: "memory-palace"))
        #expect(!palace.supports(hermes: "0.22.2") && palace.supports(hermes: "0.30.1"))
        #expect(PluginOffers.unavailable(palace, gateway: "Studio Mac", gatewayOS: "Darwin", hermesVersion: "0.22.2")
                == "Needs Hermes 0.30.0 or later on Studio Mac")
        #expect(PluginOffers.unavailable(nvidia, gateway: "Studio Mac", gatewayOS: "Darwin", hermesVersion: nil) == "Runs on Windows")
    }

    /// The app's plugins first, then curated ones whose app is there; five at most; what's
    /// installed and on, hidden or can't run here is left out; installed but off is Turn On.
    @Test func suggestedOrderLimitAndExclusions() throws {
        let catalog = try fixtureCatalog()
        let suggested = PluginOffers.suggested(
            app: [(.push, .missing), (.widgets, .off)],
            curated: [curated("blender"), curated("obsidian", state: "missing_app"), curated("xcode"), curated("figma-desktop"),
                      curated("touchdesigner"), curated("nvidia-app"), curated("davinci-resolve")],
            installed: [row("Xcode", catalog: "xcode"), row("figma", catalog: "figma-desktop", status: "not enabled")],
            catalog: catalog, gatewayOS: "Darwin", hermesVersion: "0.22.2", hidden: ["touchdesigner"]
        )
        #expect(suggested.map(\.name) == ["hermes-app-push", "hermes-app-widgets", "blender", "figma-desktop", "davinci-resolve"])
        #expect(suggested.map(\.action) == [.install, .turnOn, .install, .turnOn, .install])
        #expect(suggested.count == PluginOffers.limit)
    }

    @Test func appPluginsOnSomewhereAreNotSuggested() {
        let suggested = PluginOffers.suggested(app: [(.push, .on), (.widgets, nil)], curated: [], installed: [], catalog: nil,
                                               gatewayOS: nil, hermesVersion: nil, hidden: [])
        #expect(suggested.map(\.name) == ["hermes-app-widgets"], "unknown (no Bot Mode yet) is still offered")
        let hidden = PluginOffers.suggested(app: [(.push, .missing)], curated: [], installed: [], catalog: nil,
                                            gatewayOS: nil, hermesVersion: nil, hidden: ["hermes-app-push"])
        #expect(hidden.isEmpty)
    }

    @Test func presenceFromTheSurvey() async {
        let rows: [String: [HermesPlugin]] = ["ada": [row("hermes-app-widgets", status: "not enabled")]]
        let survey = await AppPluginsSurvey.read(profiles: ["default", "ada"], plugins: [.widgets, .push]) { rows[$0] ?? [] }
        #expect(AppPluginPresence(survey.entries(for: .widgets)) == .off)
        #expect(AppPluginPresence(survey.entries(for: .push)) == .missing)
    }

    /// The catalog doesn't list where a plugin sends data, so its review never says "sends
    /// nothing"; every hook still reads in words or as "Uses the <name> hook".
    @Test func catalogReviewsNeverPromiseNoNetwork() throws {
        let catalog = try fixtureCatalog()
        let ledger = try #require(catalog.entry(named: "approval-ledger"))
        let lines = CapabilityWords.lines(for: ledger.capabilities, gateway: "Studio Mac", knowsNetwork: false)
        #expect(!lines.contains { $0.words.contains("sends nothing") })
        #expect(lines.last?.words == "Needs no keys")
        for entry in catalog.entries {
            let named = Set(CapabilityWords.lines(for: entry.capabilities, gateway: "Studio Mac", knowsNetwork: false).flatMap(\.names))
            for hook in entry.capabilities.hooks {
                #expect(named.contains(hook), "\(entry.name): \(hook) isn't on its review")
            }
        }
    }

    // MARK: Answers

    @Test func notNowComesBackOnceAfterTwoWeeks() {
        var answers = PluginAnswers()
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(answers.mayOffer("hermes-app-widgets", at: "whatsNew", now: start))
        answers.notNow("hermes-app-widgets", at: "whatsNew", on: start)
        #expect(!answers.mayOffer("hermes-app-widgets", at: "whatsNew", now: start.addingTimeInterval(13 * day)))
        #expect(answers.mayOffer("hermes-app-widgets", at: "checklist", now: start), "another moment isn't answered")
        #expect(answers.mayOffer("hermes-app-widgets", at: "whatsNew", now: start.addingTimeInterval(14 * day)))
        answers.offered("hermes-app-widgets", at: "whatsNew")
        #expect(!answers.mayOffer("hermes-app-widgets", at: "whatsNew", now: start.addingTimeInterval(60 * day)), "only once")
    }

    @Test func hiddenAndShowAgain() {
        var answers = PluginAnswers()
        answers.hide("blender")
        #expect(answers.isHidden("blender"))
        #expect(!answers.mayOffer("blender", at: "suggested"))
        answers.showAgain("blender")
        #expect(!answers.isHidden("blender"))
        #expect(answers.mayOffer("blender", at: "suggested"))
    }

    @Test func newInTheCatalogStartsEmptyAndFills() {
        var answers = PluginAnswers()
        #expect(answers.unseen(in: ["a", "b"]).isEmpty, "the first visit counts everything as seen")
        #expect(answers.unseen(in: ["a", "b", "c"]) == ["c"])
        answers.markSeen(["c"])
        #expect(answers.unseen(in: ["a", "b", "c"]).isEmpty)
    }

    @Test func hiddenNamesKeepPerGateway() throws {
        let defaults = try #require(UserDefaults(suiteName: "plugins-hidden-\(UUID().uuidString)"))
        let store = LocalHiddenSuggestions(defaults: defaults)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.setHidden(["touchdesigner": when], gateway: "studio-mac")
        #expect(store.hidden(gateway: "studio-mac") == ["touchdesigner": when])
        #expect(store.hidden(gateway: "nas").isEmpty)
        store.setHidden([:], gateway: "studio-mac")
        #expect(store.hidden(gateway: "studio-mac").isEmpty)
    }

    // MARK: The catalog store

    @Test func theFeedIsCachedAndKeptWhenARefreshFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        let file = folder.appending(path: "plugin-catalog.json")
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../Tools/mock-hermes/plugin-catalog.json").standardizedFileURL)
        let clock = Clock()
        let fetches = Counter()
        let store = PluginCatalogStore(cacheFile: file, now: { clock.now }) { _ in
            await fetches.add()
            if await fetches.value > 1 { throw URLError(.notConnectedToInternet) }
            return data
        }
        #expect(await store.catalog()?.entries.count == 20)
        #expect(await store.catalog()?.entries.count == 20)
        #expect(await fetches.value == 1, "a fresh copy isn't fetched again")
        clock.now = clock.now.addingTimeInterval(7 * 3600)
        #expect(await store.catalog()?.entries.count == 20, "a failed refresh keeps the old copy")
        #expect(await fetches.value == 2)
        let reopened = PluginCatalogStore(cacheFile: file) { _ in throw URLError(.notConnectedToInternet) }
        #expect(await reopened.catalog()?.entries.count == 20, "the copy on disk is read when the feed can't be")
        try? FileManager.default.removeItem(at: folder)
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor Counter {
    var value = 0
    func add() { value += 1 }
}
