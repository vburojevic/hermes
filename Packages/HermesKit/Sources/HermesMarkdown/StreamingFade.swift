/// How a streaming paragraph's newest words fade in along the line (`docs/chat.md` §3).
///
/// The fade moves only when the reply redraws: its leading edge sits on the newest glyph, and
/// the glyphs behind it get darker over `length` glyphs. Once the words stop coming for a moment,
/// the rest of the fade goes in a few steps at the stream's pace. A fade animated frame by frame
/// changed the text's drawing on every frame, and SwiftUI laid the whole chat out again each time.
public enum StreamingFade {
    /// The glyphs the fade runs over.
    public static let length = 14.0
    /// The steps the end of the fade goes in once the words stop coming.
    public static let restSteps = 3
    /// How long the words stop before the end of the fade goes in, and the time between its steps
    /// (about one redraw, `applyToLive`).
    public static let restDelay: Duration = .milliseconds(150)
    public static let stepGap: Duration = .milliseconds(66)

    /// The last time the words stopped: the text's length then, the steps of the fade's end gone
    /// in since, and the glyphs earlier pauses left drawn whole.
    public struct Pause: Equatable, Sendable {
        public var count: Int
        public var steps: Int
        public var whole: Int

        /// A paragraph whose words haven't stopped yet.
        public static let none = Pause(count: -1, steps: 0, whole: 0)

        /// The pause after `step` steps of the fade's end with the text `count` glyphs long.
        public func rested(count: Int, step: Int) -> Pause {
            Pause(count: count, steps: step, whole: count == self.count ? whole : whole(before: count))
        }

        /// The glyphs drawn whole once the text is `count` long. The words that arrive after a
        /// pause fade in on their own; what the pause had drawn stays drawn, so nothing dims again.
        func whole(before count: Int) -> Int {
            count == self.count || steps == 0 ? whole : max(whole, self.count)
        }
    }

    /// The fade for text `count` glyphs long after `pause`.
    public struct Edge: Equatable, Sendable {
        /// The fade's leading edge, in glyphs. Every glyph `length` or more behind it is whole.
        public var shown: Double
        /// The glyphs before this are drawn whole whatever the edge.
        public var whole: Double

        public init(count: Int, pause: Pause) {
            let resting = pause.count == count ? pause.steps : 0
            shown = StreamingFade.shown(count: count, restedSteps: resting)
            whole = Double(pause.whole(before: count))
        }

        /// The opacity of the glyph at `index`.
        public func opacity(at index: Double) -> Double {
            index < whole ? 1 : StreamingFade.opacity(at: index, shown: shown)
        }

        /// Whether every glyph before `end` is drawn whole.
        public func isWhole(before end: Double) -> Bool {
            end <= whole || end + StreamingFade.length <= shown
        }
    }

    /// Where the fade's leading edge is, in glyphs, for text `count` glyphs long that has rested
    /// for `restedSteps` steps. Past `count + length`, every glyph is drawn whole.
    public static func shown(count: Int, restedSteps: Int) -> Double {
        let steps = min(max(0, restedSteps), restSteps)
        return Double(max(0, count)) + length * Double(steps) / Double(restSteps)
    }

    /// The opacity of the glyph at `index` with the fade's edge at `shown`.
    public static func opacity(at index: Double, shown: Double) -> Double {
        min(1, max(0, (shown - index) / length))
    }

    /// The steps a block that isn't text (a list's bullet, a code block, a table) fades in over,
    /// `stepGap` apart, from nothing when it arrives. Eased frame by frame, each block's fade
    /// redrew the chat on every frame while the reply wrote.
    public static let appearSteps = 3

    /// The opacity of such a block `step` steps after it arrived.
    public static func appearOpacity(step: Int) -> Double {
        min(1, max(0, Double(step) / Double(appearSteps)))
    }
}
