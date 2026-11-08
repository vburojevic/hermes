import Foundation
import Testing
@testable import HermesKit

/// Skills reads its list when it opens, again whenever the gateway comes online, and on pull to
/// refresh (`docs/bots-groups-skills.md` §3). The newest read's answer is the one that stands.
@MainActor
struct SkillsLoadTests {
    struct Offline: Error {}

    let workspace = UUID()
    let address = URL(string: "http://127.0.0.1:44642")!
    let library = [
        Skill(name: "github-pr-review", description: "Review a pull request", category: "software-development"),
        Skill(name: "arxiv", description: "Find papers", category: "research"),
    ]

    func trigger(online: Bool, address: URL? = nil) -> SkillsLoadTrigger {
        SkillsLoadTrigger(workspace: workspace, address: address ?? self.address, isOnline: online)
    }

    /// Lets a read started in another task get under way.
    func untilReading(_ reads: LatestRead<[Skill]>) async {
        var turns = 0
        while !reads.isReading, turns < 1_000 {
            await Task.yield()
            turns += 1
        }
    }

    // MARK: When Skills reads

    /// The gateway coming online changes the trigger, so a page opened before it connected reads again.
    @Test func comingOnlineReadsAgain() {
        #expect(trigger(online: false) != trigger(online: true))
        #expect(trigger(online: true).reads(showing: []))
    }

    @Test func aNewAddressOrGatewayReadsAgain() {
        #expect(trigger(online: true) != trigger(online: true, address: URL(string: "http://127.0.0.1:44643")!))
        #expect(trigger(online: true) != SkillsLoadTrigger(workspace: UUID(), address: address, isOnline: true))
        #expect(trigger(online: true) == trigger(online: true))
    }

    /// Offline, an empty page still reads, so it can say why it's empty.
    @Test func offlineWithNothingShownReads() {
        #expect(trigger(online: false).reads(showing: []))
    }

    /// The connection dropping never clears a list already shown.
    @Test func offlineKeepsAListAlreadyShown() {
        #expect(!trigger(online: false).reads(showing: library))
        #expect(trigger(online: true).reads(showing: library))
    }

    // MARK: What an answer does

    @Test func aReadFillsTheList() {
        var list = SkillsList()
        list.take(.success(library))
        #expect(list.skills == library)
        #expect(list.error == nil)
    }

    @Test func aFailedReadKeepsTheSkillsShown() {
        var list = SkillsList(skills: library)
        list.take(.failure(HermesError.unreachable(host: "127.0.0.1", reason: .cannotConnect)))
        #expect(list.skills == library)
        #expect(list.error == .unreachable(host: "127.0.0.1", reason: .cannotConnect))
    }

    @Test func anErrorThatIsNotTheGatewaysReadsAsAnInvalidResponse() {
        var list = SkillsList()
        list.take(.failure(Offline()))
        guard case .invalidResponse? = list.error else {
            Issue.record("Expected an invalid response, got \(String(describing: list.error))")
            return
        }
        #expect(list.skills.isEmpty)
    }

    /// A read a newer one replaced, or one cancelled as Skills closed, changes nothing.
    @Test func noAnswerChangesNothing() {
        var list = SkillsList(skills: library, error: .rateLimited)
        list.take(nil)
        #expect(list == SkillsList(skills: library, error: .rateLimited))
    }

    // MARK: A late connect, end to end

    /// Skills opens before the gateway connects: the first read fails and the page says why. The
    /// gateway comes online and the page fills in. The connection drops again and the list stays.
    @Test func aLateConnectFillsTheList() async {
        let reads = LatestRead<[Skill]>()
        var list = SkillsList()
        var connected = false
        let library = library
        func read(_ trigger: SkillsLoadTrigger) async {
            guard trigger.reads(showing: list.skills) else { return }
            let online = connected
            list.take(await reads.read {
                guard online else { throw HermesError.unreachable(host: "127.0.0.1", reason: .cannotConnect) }
                return library
            })
        }

        await read(trigger(online: false))
        #expect(list.skills.isEmpty)
        #expect(list.error != nil)

        connected = true
        await read(trigger(online: true))
        #expect(list.skills == library)
        #expect(list.error == nil)

        connected = false
        await read(trigger(online: false))
        #expect(list.skills == library)
        #expect(list.error == nil)
    }

    /// The read from before the connect answers after the one from after it: the newer list stands.
    @Test func aSlowEarlierReadNeverOverwritesANewerOne() async {
        let reads = LatestRead<[Skill]>()
        let gate = TasksLoadTests.Gate()
        var list = SkillsList()
        let older = Task { @MainActor in
            await reads.read { () async throws -> [Skill] in
                await gate.wait()
                throw HermesError.unreachable(host: "127.0.0.1", reason: .timedOut)
            }
        }
        await untilReading(reads)
        let library = library
        list.take(await reads.read { library })
        gate.open()
        list.take(await older.value)
        #expect(list.skills == library)
        #expect(list.error == nil)
        #expect(!reads.isReading)
    }
}
