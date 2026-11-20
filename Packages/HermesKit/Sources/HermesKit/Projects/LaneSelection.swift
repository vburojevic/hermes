import Foundation

/// The chat the arrow keys have selected on a Mac project home (`docs/projects.md` §2): Up and
/// Down move within a lane, Left and Right to the lane before or after it, keeping the row's place
/// where that lane has one. It works on the rows as shown, each lane's in order and the lanes in
/// theirs, so a lane collapsed to three rows offers those three.
public struct LaneSelection: Hashable, Sendable {
    public enum Move: Hashable, Sendable {
        case up, down, left, right
    }

    /// Where a selection stands: its lane and its row in that lane.
    public struct Position: Hashable, Sendable {
        public let lane: Int
        public let row: Int
    }

    /// The selected row's id, or nil before the first key.
    public private(set) var rowID: String?

    public init(rowID: String? = nil) {
        self.rowID = rowID
    }

    /// Selects a row, or clears the selection. A click opens its chat and leaves this alone.
    public mutating func select(_ id: String?) {
        rowID = id
    }

    /// The selected row's place among `lanes`, or nil when it isn't shown.
    public func position(in lanes: [[String]]) -> Position? {
        guard let rowID else { return nil }
        for (laneIndex, lane) in lanes.enumerated() {
            if let rowIndex = lane.firstIndex(of: rowID) { return Position(lane: laneIndex, row: rowIndex) }
        }
        return nil
    }

    /// Moves by one key. With nothing selected (or a row that has gone), any arrow selects the
    /// first chat of the first lane. At a lane's first or last row, or the first or last lane, the
    /// selection stays where it is. Returns whether there was a row to select, so the key is
    /// handled whenever the home has chats.
    @discardableResult
    public mutating func move(_ move: Move, in lanes: [[String]]) -> Bool {
        let shown = lanes.filter { !$0.isEmpty }
        guard let first = shown.first?.first else {
            rowID = nil
            return false
        }
        guard let at = position(in: shown) else {
            rowID = first
            return true
        }
        let lane = shown[at.lane]
        switch move {
        case .up:
            rowID = lane[max(at.row - 1, 0)]
        case .down:
            rowID = lane[min(at.row + 1, lane.count - 1)]
        case .left, .right:
            let target = move == .left ? max(at.lane - 1, 0) : min(at.lane + 1, shown.count - 1)
            let next = shown[target]
            rowID = next[min(at.row, next.count - 1)]
        }
        return true
    }
}
