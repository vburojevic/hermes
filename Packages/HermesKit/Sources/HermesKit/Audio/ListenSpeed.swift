import Foundation

/// The speeds Listen and voice messages play at (`docs/voice.md` §2, §3, §6): the speed button
/// steps through them, Settings and Now Playing offer them, and a stored speed snaps to one.
public enum ListenSpeed {
    public static let steps: [Double] = [1, 1.25, 1.5, 1.75, 2]

    /// The step nearest `value`, the lower one on a tie. Nothing stored, or not a number, is 1×.
    public static func snapped(_ value: Double?) -> Double {
        guard let value, !value.isNaN else { return 1 }
        let clamped = min(max(value, steps[0]), steps[steps.count - 1])
        return steps.min { abs($0 - clamped) < abs($1 - clamped) } ?? 1
    }

    /// The speed a tap on the button moves to: the next step, from 2× back to 1×.
    public static func next(after rate: Double) -> Double {
        let index = steps.firstIndex(of: snapped(rate)) ?? 0
        return steps[(index + 1) % steps.count]
    }

    /// "1×", "1.25×": the speed as the button, Settings and VoiceOver say it.
    public static func label(_ rate: Double, locale: Locale = .autoupdatingCurrent) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale)) + "×"
    }

    /// The longest step's label ("1.25×"): room sized for it fits every speed, so nothing
    /// around the button moves when the speed changes.
    public static func longestLabel(locale: Locale = .autoupdatingCurrent) -> String {
        steps.map { label($0, locale: locale) }.max { $0.count < $1.count } ?? label(1, locale: locale)
    }
}
