#if DEBUG
import Testing
@testable import HermesKit

/// Debug launch flags that act once per launch (`LaunchFlags`): a launch argument stays
/// in UserDefaults for the whole process, so the flag's value is handed out the first time it's
/// asked for and never again, however often its view's task runs.
@Suite("Launch flags")
struct LaunchFlagsTests {
    /// What the launch arguments hold: never cleared, as `removeObject` can't clear them.
    static let arguments = ["HERMES_TYPE": "hello", "HERMES_SEND": "approve", "HERMES_EMPTY": ""]

    static func read(_ key: String) -> String? { arguments[key] }

    @Test func aFlagActsOnceThoughItsValueStays() {
        var latch = LaunchFlagLatch()
        #expect(latch.take("HERMES_TYPE", read: Self.read) == "hello")
        #expect(latch.take("HERMES_TYPE", read: Self.read) == nil)
        #expect(latch.take("HERMES_TYPE", read: Self.read) == nil)
    }

    @Test func eachFlagActsOnceOnItsOwn() {
        var latch = LaunchFlagLatch()
        #expect(latch.take("HERMES_TYPE", read: Self.read) == "hello")
        #expect(latch.take("HERMES_SEND", read: Self.read) == "approve")
        #expect(latch.take("HERMES_SEND", read: Self.read) == nil)
    }

    @Test func aFlagNotGivenIsNotUsedUp() {
        var latch = LaunchFlagLatch()
        var arguments: [String: String] = [:]
        #expect(latch.take("HERMES_IME") { arguments[$0] } == nil)
        arguments["HERMES_IME"] = "nihon"
        #expect(latch.take("HERMES_IME") { arguments[$0] } == "nihon")
        #expect(latch.take("HERMES_IME") { arguments[$0] } == nil)
    }

    @Test func anEmptyValueDoesNothing() {
        var latch = LaunchFlagLatch()
        #expect(latch.take("HERMES_EMPTY", read: Self.read) == nil)
    }

    /// As `LaunchFlags.takeSwitch` reads them: NO counts as not given.
    @Test func aSwitchActsOnce() {
        var latch = LaunchFlagLatch()
        let switches = ["HERMES_OPEN_VOICE": true, "HERMES_LISTEN": false]
        let read = { (key: String) -> Bool? in switches[key] == true ? true : nil }
        #expect(latch.take("HERMES_OPEN_VOICE", read: read) == true)
        #expect(latch.take("HERMES_OPEN_VOICE", read: read) == nil)
        #expect(latch.take("HERMES_LISTEN", read: read) == nil)
    }

    /// As `LaunchFlags.takeSeconds` reads them: zero or less counts as not given.
    @Test func aTimeActsOnce() {
        var latch = LaunchFlagLatch()
        let seconds = ["HERMES_STUCK_TURN": 30.0, "HERMES_REFRESH_AFTER": 0]
        let read = { (key: String) -> Double? in seconds[key].flatMap { $0 > 0 ? $0 : nil } }
        #expect(latch.take("HERMES_STUCK_TURN", read: read) == 30)
        #expect(latch.take("HERMES_STUCK_TURN", read: read) == nil)
        #expect(latch.take("HERMES_REFRESH_AFTER", read: read) == nil)
    }
}
#endif
