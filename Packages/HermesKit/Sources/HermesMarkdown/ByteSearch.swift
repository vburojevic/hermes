import Foundation

// HermesKit's byte search (`HermesKit/Support/ByteSearch.swift`), kept internal here: this module
// doesn't depend on HermesKit, and the app imports both.
extension StringProtocol {
    /// Whether `needle` occurs in the text, compared byte for byte (UTF-8).
    func containsBytes(_ needle: String) -> Bool {
        countBytes(needle, stoppingAt: 1) > 0
    }

    /// How many times `needle` occurs, without overlaps, compared byte for byte (UTF-8).
    func countBytes(_ needle: String, stoppingAt limit: Int = .max) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return 0 }
        let counted = utf8.withContiguousStorageIfAvailable { bytes -> Int in
            guard let base = bytes.baseAddress else { return 0 }
            return pattern.withUnsafeBufferPointer { pattern -> Int in
                var count = 0
                var start = 0
                while count < limit, start + pattern.count <= bytes.count,
                      let hit = memmem(base + start, bytes.count - start, pattern.baseAddress, pattern.count) {
                    count += 1
                    start = UnsafeRawPointer(base).distance(to: hit) + pattern.count
                }
                return count
            }
        }
        return counted ?? Swift.min(components(separatedBy: needle).count - 1, limit)
    }
}
