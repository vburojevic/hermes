import Foundation

/// A hang (or a CPU exception) MetricKit reported, reduced to what the next freeze report needs:
/// how long, on which build, and the blocked thread's call stack as binaries, UUIDs, offsets and
/// sample counts (docs/development.md, Hangs). Nothing else from the payload is kept: no region,
/// no bundle id, no addresses, and every string is cut to a short safe alphabet, so what lands in
/// the app's log can't carry a chat's words, a name or an address.
public struct HangReport: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// `MXHangDiagnostic`: the main thread didn't answer for `seconds`.
        case hang
        /// `MXCPUExceptionDiagnostic`: the app used `seconds` of CPU over its sampled time.
        case cpu
    }

    public struct Frame: Sendable, Equatable {
        /// 0 for a thread's outermost frame, one more for each frame it called.
        public var depth: Int
        public var binary: String
        public var uuid: String
        public var offset: UInt64
        public var samples: Int
    }

    public struct Thread: Sendable, Equatable {
        /// The thread MetricKit blames (the blocked main thread, for a hang).
        public var attributed: Bool
        public var frames: [Frame]
    }

    public var kind: Kind
    /// The hang's length, or the CPU time for a CPU exception; nil when MetricKit's text didn't parse.
    public var seconds: Double?
    public var appVersion: String
    public var build: String
    public var os: String
    public var architecture: String
    public var threads: [Thread]

    /// Frames kept per report, deepest calls dropped first: a stack tree for a long hang can hold
    /// thousands, and the log keeps several reports.
    public static let frameLimit = 400
    /// Reports' text kept in the log file, newest last; older reports go whole.
    public static let logLimit = 256 * 1024
    /// A block of the main thread this long or longer is a hang (Apple's own threshold).
    public static let hangThreshold: Duration = .milliseconds(250)

    /// Reads a diagnostic's `jsonRepresentation()`. Nil when it isn't one MetricKit writes.
    public init?(json: Data, kind: Kind) {
        guard let root = DeepJSON.parse(json) as? [String: Any],
              let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]]
        else { return nil }
        let meta = root["diagnosticMetaData"] as? [String: Any] ?? [:]
        self.kind = kind
        let durationKey = kind == .hang ? "hangDuration" : "totalCPUTime"
        seconds = (meta[durationKey] as? String).flatMap(Self.seconds(in:))
        appVersion = Self.safe(meta["appVersion"])
        build = Self.safe(meta["appBuildVersion"])
        os = Self.safe(meta["osVersion"])
        architecture = Self.safe(meta["platformArchitecture"])
        var budget = Self.frameLimit
        var threads: [Thread] = []
        for stack in stacks {
            var frames: [Frame] = []
            Self.collect(stack["callStackRootFrames"] as? [[String: Any]] ?? [], into: &frames, budget: &budget)
            threads.append(Thread(attributed: stack["threadAttributed"] as? Bool ?? false, frames: frames))
        }
        // The blamed thread first: it's the one a freeze report reads.
        self.threads = threads.filter(\.attributed) + threads.filter { !$0.attributed }
    }

    /// The report as log lines: a heading, then each thread's frames, one per line.
    public var lines: [String] {
        let length = seconds.map { String(format: "%.2f s", $0) } ?? "unknown length"
        let what = kind == .hang ? "hang" : "cpu exception"
        var lines = ["\(what) \(length) · app \(appVersion) (\(build)) · \(os) · \(architecture)"]
        for (index, thread) in threads.enumerated() {
            lines.append("  thread \(index)\(thread.attributed ? " (blamed)" : "")")
            for frame in thread.frames {
                let indent = String(repeating: "  ", count: min(frame.depth, 40))
                lines.append("    \(indent)#\(frame.depth) \(frame.binary) \(frame.uuid) +0x\(String(frame.offset, radix: 16)) ×\(frame.samples)")
            }
        }
        return lines
    }

    /// `log` with `entry` added at its end, older entries dropped whole (entries are separated by
    /// a blank line) until it fits in `limit` bytes. An entry larger than the limit is cut.
    public static func appending(_ entry: String, to log: String, limit: Int = logLimit) -> String {
        var entries = log.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        entries.append(entry.trimmingCharacters(in: .newlines))
        while entries.count > 1, entries.joined(separator: "\n\n").utf8.count + 2 > limit {
            entries.removeFirst()
        }
        var text = entries.joined(separator: "\n\n") + "\n\n"
        if text.utf8.count > limit {
            text = String(decoding: text.utf8.prefix(limit), as: UTF8.self)
        }
        return text
    }

    /// The Debug watchdog's line (`-HERMES_HANG_LOG`) for a ping the main thread answered late:
    /// nil under the threshold. Times are from the process's start, so a scenario's marks line up.
    /// `mainCPU` is the CPU time the main thread used meanwhile: near the duration it was busy,
    /// far below it was waiting or starved (a napping app on a loaded Mac).
    public static func watchdogLine(startMilliseconds start: Double, duration: Duration, mainCPU: Duration? = nil) -> String? {
        guard duration >= hangThreshold else { return nil }
        let line = String(format: "HANG start=%.0fms duration=%.0fms", start, milliseconds(duration))
        guard let mainCPU else { return line }
        return line + String(format: " main-cpu=%.0fms", milliseconds(mainCPU))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// MetricKit writes a duration as a formatted measurement ("2 sec", "1,500 ms", "1.5 min").
    static func seconds(in text: String) -> Double? {
        let parts = text.replacingOccurrences(of: ",", with: "").split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        switch parts[1].lowercased() {
        case "ms": return value / 1000
        case "s", "sec", "secs", "second", "seconds": return value
        case "min", "mins", "minute", "minutes": return value * 60
        case "h", "hr", "hour", "hours": return value * 3600
        default: return nil
        }
    }

    /// Letters, digits and `.`, `-`, `_`, `(`, `)`, space, at most 64 of them: binary names,
    /// versions and UUIDs fit; a sentence or an address doesn't come through whole.
    static func safe(_ value: Any?) -> String {
        guard let text = value as? String, !text.isEmpty else { return "?" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_() "))
        let kept = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.isASCII && allowed.contains($0) }))
        return kept.isEmpty ? "?" : String(kept.prefix(64))
    }

    /// The tree's frames, each before the frames it called, until `budget` runs out. A loop
    /// rather than recursion: a hang's stack can be hundreds of frames deep, and MetricKit
    /// calls back on a thread with a small stack.
    private static func collect(_ roots: [[String: Any]], into frames: inout [Frame], budget: inout Int) {
        var pending = roots.reversed().map { (frame: $0, depth: 0) }
        while budget > 0, let (frame, depth) = pending.popLast() {
            budget -= 1
            let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            frames.append(Frame(depth: depth, binary: safe(frame["binaryName"]), uuid: safe(frame["binaryUUID"]),
                                offset: offset, samples: (frame["sampleCount"] as? NSNumber)?.intValue ?? 0))
            let children = frame["subFrames"] as? [[String: Any]] ?? []
            pending.append(contentsOf: children.reversed().map { (frame: $0, depth: depth + 1) })
        }
    }
}

/// A JSON reader with no limit on nesting. Each frame of a call stack tree nests two levels inside
/// its caller, so a 300-frame SwiftUI stack is deeper than `JSONSerialization` reads (it refuses
/// the whole report); this one keeps its place on a heap stack instead of recursing. Objects come
/// back as `[String: Any]`, arrays as `[Any]`, numbers as `NSNumber`, booleans as `Bool`, null as
/// `NSNull`; nil for anything that isn't one JSON value.
enum DeepJSON {
    private struct Open {
        var array: [Any]?
        var object: [String: Any]?
        var key = ""
    }

    static func parse(_ data: Data) -> Any? {
        let bytes = [UInt8](data)
        var index = 0
        var stack: [Open] = []

        func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
        func next(is byte: Unicode.Scalar) -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: byte) else { return false }
            index += 1
            return true
        }
        // An object's key and its colon, for the object on top of the stack.
        func readKey() -> Bool {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = readString(), next(is: ":") else { return false }
            stack[stack.count - 1].key = key
            return true
        }
        func readString() -> String? {
            index += 1
            var text: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: text, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "b"): text.append(0x08)
                    case UInt8(ascii: "f"): text.append(0x0C)
                    case UInt8(ascii: "n"): text.append(0x0A)
                    case UInt8(ascii: "r"): text.append(0x0D)
                    case UInt8(ascii: "t"): text.append(0x09)
                    case UInt8(ascii: "u"):
                        guard var code = readHex() else { return nil }
                        // A pair of escapes for a character beyond the first plane.
                        if (0xD800..<0xDC00).contains(code), bytes.count > index + 1,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            guard let low = readHex() else { return nil }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low &- 0xDC00)
                        }
                        text.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
                    default: text.append(escape)
                    }
                default:
                    text.append(byte)
                }
            }
            return nil
        }
        func readHex() -> UInt32? {
            guard bytes.count >= index + 4,
                  let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { return nil }
            index += 4
            return code
        }
        func readWord(_ word: String) -> Bool {
            let utf8 = Array(word.utf8)
            guard bytes.count >= index + utf8.count, Array(bytes[index..<index + utf8.count]) == utf8 else { return false }
            index += utf8.count
            return true
        }
        func readNumber() -> NSNumber? {
            let start = index
            while index < bytes.count, "+-.eE0123456789".utf8.contains(bytes[index]) { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if let whole = Int64(text) { return NSNumber(value: whole) }
            if let whole = UInt64(text) { return NSNumber(value: whole) }
            return Double(text).map { NSNumber(value: $0) }
        }

        while true {
            skipSpace()
            guard index < bytes.count else { return nil }
            var value: Any
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                if next(is: "}") {
                    value = [String: Any]()
                } else {
                    stack.append(Open(object: [:]))
                    guard readKey() else { return nil }
                    continue
                }
            case UInt8(ascii: "["):
                index += 1
                if next(is: "]") {
                    value = [Any]()
                } else {
                    stack.append(Open(array: []))
                    continue
                }
            case UInt8(ascii: "\""):
                guard let text = readString() else { return nil }
                value = text
            case UInt8(ascii: "t"):
                guard readWord("true") else { return nil }
                value = true
            case UInt8(ascii: "f"):
                guard readWord("false") else { return nil }
                value = false
            case UInt8(ascii: "n"):
                guard readWord("null") else { return nil }
                value = NSNull()
            default:
                guard let number = readNumber() else { return nil }
                value = number
            }
            // The value goes into its container; each container it completes goes into the next.
            while true {
                guard var open = stack.popLast() else {
                    skipSpace()
                    return index == bytes.count ? value : nil
                }
                if open.array != nil { open.array?.append(value) } else { open.object?[open.key] = value }
                if next(is: ",") {
                    stack.append(open)
                    if open.object != nil, !readKey() { return nil }
                    break
                }
                guard next(is: open.array != nil ? "]" : "}") else { return nil }
                value = open.array ?? open.object ?? [:]
            }
        }
    }
}
