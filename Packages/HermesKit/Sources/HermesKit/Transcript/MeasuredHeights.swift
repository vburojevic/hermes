import Foundation
import Synchronization

/// A finished reply's heights as its text measured them, by width, kept with the text itself so
/// every view of it shares them (`docs/chat.md` §3 Selection). Each view of a reply used
/// to measure it again: opening a chat laid out every reply in it twice (once to size it, once
/// to draw it) and built each code block and table twice, even for a chat opened a moment ago.
///
/// Heights are kept for the last few widths a view asked about (a window being resized asks at
/// every width it passes). A block whose height changed where it was shown (an image arrived, a
/// widget drew) makes the text's heights wrong, and may change again: from then on nothing is
/// kept, and each view measures the reply as before.
public final class MeasuredHeights: Sendable {
    /// Where a hosted block is, and the width it was laid out at.
    public struct BlockKey: Hashable, Sendable {
        public let paragraph: Int
        public let width: CGFloat

        public init(paragraph: Int, width: CGFloat) {
            self.paragraph = paragraph
            self.width = width
        }
    }

    private struct State {
        var texts: Recent<CGFloat>
        var blocks: Recent<BlockKey>
        var isKept = true
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - widths: how many widths the text's height is kept for.
    ///   - blocks: how many block heights are kept, over every block and width.
    public init(widths: Int = 4, blocks: Int = 64) {
        state = Mutex(State(texts: Recent(limit: widths), blocks: Recent(limit: blocks)))
    }

    /// The text's height at this width, when a view measured it there.
    public func height(at width: CGFloat) -> CGFloat? {
        state.withLock { $0.texts[width] }
    }

    public func record(_ height: CGFloat, at width: CGFloat) {
        state.withLock { state in
            guard state.isKept else { return }
            state.texts[width] = height
        }
    }

    /// A hosted block's height at this width, when a view measured it there.
    public func blockHeight(_ key: BlockKey) -> CGFloat? {
        state.withLock { $0.blocks[key] }
    }

    public func recordBlock(_ height: CGFloat, at key: BlockKey) {
        state.withLock { state in
            guard state.isKept else { return }
            state.blocks[key] = height
        }
    }

    /// A block changed its height where it was shown: what was kept no longer holds, and the
    /// reply's heights aren't kept again.
    public func blockResized() {
        state.withLock { state in
            state.isKept = false
            state.texts.removeAll()
            state.blocks.removeAll()
        }
    }

    /// Whether heights are still kept for this reply.
    public var isKept: Bool {
        state.withLock { $0.isKept }
    }
}

/// Values by key, the oldest dropped past `limit`.
private struct Recent<Key: Hashable> {
    let limit: Int
    private var values: [Key: CGFloat] = [:]
    private var order: [Key] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    subscript(key: Key) -> CGFloat? {
        get { values[key] }
        set {
            guard let newValue else {
                values[key] = nil
                order.removeAll { $0 == key }
                return
            }
            if values.updateValue(newValue, forKey: key) == nil {
                order.append(key)
                if order.count > limit { values[order.removeFirst()] = nil }
            }
        }
    }

    mutating func removeAll() {
        values = [:]
        order = []
    }
}
