import Foundation

/// Where Bot Mode's list of Bots came from (`docs/connecting-and-voice.md` §8): the copy this
/// device kept, shown at once on a launch while the socket connects, or the gateway's own
/// `profiles.list`. The copy can show Bots, but it can't say one isn't there: a Bot made since it
/// was written is missing from it.
public struct RosterLoad: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case none
        /// The device's copy, until the gateway answers.
        case cache
        case gateway
    }

    public private(set) var source: Source = .none

    public init() {}

    /// There are Bots to show: the gateway's list, or the device's copy while it loads.
    public var hasList: Bool { source != .none }

    /// The gateway has answered a roster read. Only this says what the gateway has.
    public var hasLiveList: Bool { source == .gateway }

    /// The device's copy is shown. Never over a list already shown; answers whether it was.
    public mutating func showCached() -> Bool {
        guard source == .none else { return false }
        source = .cache
        return true
    }

    /// The gateway answered `profiles.list`.
    public mutating func gatewayAnswered() {
        source = .gateway
    }

    /// The address changed: nothing shown is this gateway's.
    public mutating func reset() {
        source = .none
    }

    /// Whether the roster has a Bot, as a call reads it (`PendingCall.Facts.hasBot`): `nil` until
    /// the gateway has answered when the list shown doesn't name it.
    public func hasBot(listed: Bool) -> Bool? {
        if listed { return true }
        return hasLiveList ? false : nil
    }
}
