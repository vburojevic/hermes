import Foundation

extension StringProtocol {
    /// Whether `needle` occurs in the text, compared byte for byte (UTF-8, no Unicode
    /// equivalence). For the ASCII markers the app looks for (`proc_`, ` ```widget`) that is the
    /// same answer as `contains`, which walks the text a character at a time: asked of a whole
    /// reply on every redraw while it streams, that added up on the main thread.
    public func containsBytes(_ needle: String) -> Bool {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return true }
        let found = utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard bytes.count >= pattern.count, let base = bytes.baseAddress else { return false }
            return pattern.withUnsafeBufferPointer { memmem(base, bytes.count, $0.baseAddress, pattern.count) != nil }
        }
        return found ?? contains(needle)
    }

    /// How many times `needle` occurs, without overlaps, byte for byte (see `containsBytes`).
    public func countBytes(_ needle: String) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return 0 }
        let counted = utf8.withContiguousStorageIfAvailable { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return pattern.withUnsafeBufferPointer { pattern -> Int in
                var count = 0
                var start = 0
                while start + pattern.count <= bytes.count,
                      let hit = memmem(base + start, bytes.count - start, pattern.baseAddress, pattern.count) {
                    count += 1
                    start = UnsafeRawPointer(base).distance(to: hit) + pattern.count
                }
                return count
            }
        }
        return counted ?? components(separatedBy: needle).count - 1
    }
}
