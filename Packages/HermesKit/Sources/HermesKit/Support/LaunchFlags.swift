#if DEBUG
import Foundation

/// Hands out a launch flag's value the first time it's asked for, and never again in this process.
/// A launch argument lives in UserDefaults' argument domain, which `removeObject(forKey:)` can't
/// clear, so a flag that should act once can't clear itself there.
public struct LaunchFlagLatch: Sendable {
    private var taken: Set<String> = []

    public init() {}

    /// The flag's value, once: `nil` after the first time, and while it isn't given (a flag not
    /// given isn't used up).
    public mutating func take<Value>(_ key: String, read: (String) -> Value?) -> Value? {
        consume(key, read: read)
    }

    /// A text flag's value, once; an empty value counts as not given.
    public mutating func take(_ key: String, read: (String) -> String?) -> String? {
        consume(key) { read($0).flatMap { $0.isEmpty ? nil : $0 } }
    }

    private mutating func consume<Value>(_ key: String, read: (String) -> Value?) -> Value? {
        guard !taken.contains(key), let value = read(key) else { return nil }
        taken.insert(key)
        return value
    }
}

/// The Debug launch flags that act once per launch: those that send, type, start a call, or do
/// something a set time after launch. Their views' tasks run again when a composer is rebuilt
/// (another chat, the split layout), a chat opens or the workspace is (a new window, another
/// gateway), and they mustn't act again then; the call sites that read them say so. A launch argument can't be cleared from inside the
/// app (`LaunchFlagLatch`), so this keeps the mark for the process. Flags that open a page or set
/// how something shows hold for every view that reads them, and don't come here.
@MainActor
public enum LaunchFlags {
    private static var latch = LaunchFlagLatch()

    /// `-HERMES_<NAME> <text>`'s text the first time it's asked for; `nil` after that.
    public static func take(_ key: String) -> String? {
        latch.take(key) { UserDefaults.standard.string(forKey: $0) }
    }

    /// `-HERMES_<NAME> YES`: `true` the first time it's asked for; `false` after that, and while
    /// it isn't given or says NO.
    public static func takeSwitch(_ key: String) -> Bool {
        latch.take(key) { UserDefaults.standard.bool(forKey: $0) ? true : nil } != nil
    }

    /// `-HERMES_<NAME> <seconds>`: the seconds the first time they're asked for, while above zero;
    /// `nil` after that.
    public static func takeSeconds(_ key: String) -> Double? {
        latch.take(key) { key -> Double? in
            let seconds = UserDefaults.standard.double(forKey: key)
            return seconds > 0 ? seconds : nil
        }
    }
}
#endif
