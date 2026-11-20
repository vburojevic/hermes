import Foundation
import Testing
@testable import HermesKit

@Suite("Skills page list")
struct SkillCatalogTests {
    let home = URL(string: "http://127.0.0.1:18642")!
    let other = URL(string: "http://127.0.0.1:18643")!

    @Test func readsOncePerAddress() {
        var catalog = SkillCatalog()
        #expect(catalog.needsLoad(from: home, isOnline: true))
        #expect(catalog.isWaiting(for: home))
        catalog.received([Skill(name: "github-pr")], from: home)
        // Skills opened again, or the gateway reconnecting, keeps what it read.
        #expect(!catalog.needsLoad(from: home, isOnline: true))
        #expect(!catalog.isWaiting(for: home))
        // A new address for the same workspace reads its own list.
        #expect(catalog.needsLoad(from: other, isOnline: true))
        #expect(catalog.isWaiting(for: other))
    }

    @Test func waitsForTheGatewayToComeOnline() {
        let catalog = SkillCatalog()
        #expect(!catalog.needsLoad(from: home, isOnline: false))
        #expect(catalog.needsLoad(from: home, isOnline: true))
    }

    @Test func readsAgainAfterAFailure() {
        var catalog = SkillCatalog()
        catalog.received([Skill(name: "github-pr")], from: home)
        catalog.failed(.invalidResponse("offline"), from: home)
        // The list already shown stays; the next open asks again.
        #expect(catalog.skills.map(\.name) == ["github-pr"])
        #expect(catalog.needsLoad(from: home, isOnline: true))
        catalog.failed(.invalidResponse("offline"), from: other)
        #expect(catalog.skills.isEmpty)
        catalog.received([Skill(name: "arxiv")], from: other)
        #expect(catalog.failure == nil)
        #expect(!catalog.needsLoad(from: other, isOnline: true))
    }

    @Test func readsAgainAfterATurnWritesASkill() {
        var catalog = SkillCatalog()
        catalog.received([Skill(name: "github-pr")], from: home)
        catalog.markStale()
        // The list stays on screen while it is read again, and only online.
        #expect(catalog.needsLoad(from: home, isOnline: true))
        #expect(!catalog.needsLoad(from: home, isOnline: false))
        #expect(!catalog.isWaiting(for: home))
        #expect(catalog.skills.map(\.name) == ["github-pr"])
        catalog.received([Skill(name: "github-pr"), Skill(name: "app-store-listing")], from: home)
        #expect(!catalog.needsLoad(from: home, isOnline: true))
    }

    @Test func showsPlaceholdersUntilTheFirstAnswer() {
        var catalog = SkillCatalog()
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: false) == .placeholders)
        #expect(catalog.shown(for: home, isLoading: true, isUnreachable: false) == .placeholders)
        catalog.received([], from: home)
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: false) == .empty)
        // Pull to refresh on an empty list shows placeholders while it asks.
        #expect(catalog.shown(for: home, isLoading: true, isUnreachable: false) == .placeholders)
        catalog.received([Skill(name: "github-pr")], from: home)
        #expect(catalog.shown(for: home, isLoading: true, isUnreachable: false) == .list)
        // Another address has read nothing yet.
        #expect(catalog.shown(for: other, isLoading: false, isUnreachable: false) == .placeholders)
    }

    @Test func saysWhyThereAreNoSkills() {
        var catalog = SkillCatalog()
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: true) == .offline)
        catalog.failed(.invalidResponse("timed out"), from: home)
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: false) == .failed(.invalidResponse("timed out")))
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: true) == .offline)
        // A list read before the failure stays, also while the gateway is away.
        catalog.received([Skill(name: "arxiv")], from: home)
        catalog.failed(.invalidResponse("timed out"), from: home)
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: false) == .list)
        #expect(catalog.shown(for: home, isLoading: false, isUnreachable: true) == .list)
    }

    @Test func groupsByCategoryAndFilters() {
        var catalog = SkillCatalog()
        catalog.received([
            Skill(name: "xcode", description: "Builds apps", category: "software-development"),
            Skill(name: "arxiv", description: "Reads papers", category: "research"),
            Skill(name: "notes"),
            Skill(name: "github-pr", description: "Opens pull requests", category: "software-development"),
        ], from: home)
        let groups = catalog.groups(matching: "", generalTitle: "General")
        #expect(groups.map(\.title) == ["General", "Research", "Software Development"])
        #expect(groups.last?.skills.map(\.name) == ["github-pr", "xcode"])
        #expect(catalog.groups(matching: "papers", generalTitle: "General").map(\.title) == ["Research"])
        #expect(catalog.groups(matching: "nothing", generalTitle: "General").isEmpty)
    }
}
