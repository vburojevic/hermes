import Foundation

/// The shape and pace of the band that passes over the app's shimmering words (`ShimmerText`,
/// `docs/chat.md` §4a). The band is the words' full ink over grey words, so the app only says how
/// strong it is across its width and where it is when. With straight ramps to a full-strength
/// middle it showed a crease, and eased across 30% of any width it dwelt on the first and last
/// words and raced through the middle of a long row.
public enum ShimmerBand {
    /// One clock for every shimmer: rows sweep together, and new words carry on the sweep.
    public static let period: Double = 1.6
    /// The pass across the words, at a steady pace; the band rests past them for the rest of
    /// the period.
    public static let pass: Double = 1.2

    /// One point across the band: where (0 at its leading edge, 1 at its trailing one) and how
    /// much of the band colour shows there (0 to 1).
    public struct Stop: Equatable, Sendable {
        public let location: Double
        public let strength: Double
    }

    /// Full strength only at the middle, easing out to nothing at both edges (smoothstep), in
    /// enough steps that a gradient between them shows no edge.
    public static let stops: [Stop] = (0...8).map { step in
        let location = Double(step) / 8
        return Stop(location: location, strength: strength(at: location))
    }

    /// How much of the band colour shows `location` of the way across the band.
    public static func strength(at location: Double) -> Double {
        let toMiddle = 1 - abs(2 * min(max(location, 0), 1) - 1)
        return toMiddle * toMiddle * (3 - 2 * toMiddle)
    }

    /// The band's width over words `wordsWidth` wide: 30% of them, at least 32 pt so short words
    /// still see it pass, at most 80 pt so a long row isn't washed over.
    public static func width(over wordsWidth: Double) -> Double {
        min(max(wordsWidth * 0.3, 32), 80)
    }

    /// Where the band's middle starts and ends, from the words' leading edge: wholly before them,
    /// then wholly past them.
    public static func travel(over wordsWidth: Double) -> (from: Double, to: Double) {
        let half = width(over: wordsWidth) / 2
        return (-half, wordsWidth + half)
    }

    /// Where the band's middle is `time` seconds into any clock, on the shared period.
    public static func middle(at time: Double, over wordsWidth: Double) -> Double {
        var into = time.truncatingRemainder(dividingBy: period)
        if into < 0 { into += period }
        let (from, to) = travel(over: wordsWidth)
        let progress = min(into / pass, 1)
        return from + (to - from) * progress
    }
}
