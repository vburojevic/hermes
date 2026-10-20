import Foundation

/// Values are data, not formatted strings (contract §3): the client formats them for the reader's
/// locale (`docs/widgets.md` §9). Unknown is shown as unknown ("—"), never as 0.
public struct WidgetFormatter: Sendable {
    public var locale: Locale
    public var now: Date

    public init(locale: Locale = .autoupdatingCurrent, now: Date = .now) {
        self.locale = locale
        self.now = now
    }

    public static let unknown = "—"

    // MARK: - Quantities

    /// A quantity as shown: `display` when the producer gave one, else the value in its format,
    /// with its unit.
    public func string(_ quantity: WidgetQuantity) -> String {
        if let display = quantity.display, !display.isEmpty { return display }
        guard let value = quantity.value, value != .null else { return Self.unknown }
        let text: String
        switch (quantity.format, value) {
        case (.text, _), (_, .bool):
            text = value.plainText
        case (.currency, .number(let number)):
            return currency(number, code: quantity.currency, precision: quantity.precision)
        case (.percent, .number(let number)):
            return percent(number, precision: quantity.precision)
        case (.integer, .number(let number)):
            text = Self.number(number.rounded(), digits: 0, locale: locale)
        case (.duration, .number(let number)):
            text = duration(number)
        case (.bytes, .number(let number)):
            // A payload's number can be any size; Int64(_:) would stop the app past 2^63 (F1).
            guard let bytes = Int64(checking: number) else { return Self.unknown }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        case (.number, .number(let number)), (.countdown, .number(let number)), (.date, .number(let number)),
             (.time, .number(let number)), (.datetime, .number(let number)), (.relative, .number(let number)):
            text = Self.number(number, digits: quantity.precision, locale: locale)
        case (.date, .string(let raw)):
            text = date(raw) ?? raw
        case (.time, .string(let raw)):
            text = time(raw) ?? raw
        case (.datetime, .string(let raw)):
            text = dateTime(raw) ?? raw
        case (.relative, .string(let raw)), (.countdown, .string(let raw)):
            text = relative(raw) ?? raw
        case (_, .string(let raw)):
            text = raw
        case (_, .null):
            return Self.unknown
        }
        guard let unit = quantity.unit, !unit.isEmpty, quantity.format != .currency, quantity.format != .percent else { return text }
        return Self.isTight(unit) ? text + unit : "\(text) \(unit)"
    }

    /// The raw number, when the quantity has one.
    public static func number(_ quantity: WidgetQuantity?) -> Double? {
        quantity?.value?.number
    }

    /// Units written against the number: "%", "°", "°C".
    static func isTight(_ unit: String) -> Bool {
        unit.hasPrefix("°") || unit == "%" || unit == "′" || unit == "″"
    }

    public func currency(_ value: Double, code: String?, precision: Int? = nil) -> String {
        let code = code ?? "EUR"
        var style = FloatingPointFormatStyle<Double>.Currency(code: code, locale: locale)
        if let precision {
            style = style.precision(.fractionLength(precision))
        } else if value.rounded() == value, abs(value) >= 100 {
            style = style.precision(.fractionLength(0))
        }
        return value.formatted(style)
    }

    /// A percent `value` is a fraction: 0.12 is 12% (contract §3).
    public func percent(_ value: Double, precision: Int? = nil) -> String {
        let digits = precision ?? (abs(value * 100 - (value * 100).rounded()) < 0.05 ? 0 : 1)
        return value.formatted(.percent.precision(.fractionLength(digits)).locale(locale))
    }

    /// A plain number for the reader's locale, without a needless ".0".
    public static func number(_ value: Double, digits: Int? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        if let digits { return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) }
        if value.rounded() == value { return value.formatted(.number.precision(.fractionLength(0)).locale(locale)) }
        return value.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    /// Seconds as the design writes them, short: "1h 20m", "12d", "45s".
    public func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? Int(checking: seconds).map { "\($0) s" } ?? Self.unknown
    }

    // MARK: - Times

    /// An RFC 3339 time in its own offset's zone: a flight at 10:55 in Lisbon reads 10:55
    /// wherever it's read.
    public func time(_ raw: String) -> String? {
        guard let (date, zone) = Self.parse(raw) else { return nil }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
    }

    /// A date (`YYYY-MM-DD`) or a time's day: "Fri 16 Oct".
    public func date(_ raw: String) -> String? {
        if let components = JSONSchemaValidator.parseDate(raw) {
            let utc = TimeZone(identifier: "UTC") ?? .gmt
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            guard let day = calendar.date(from: components) else { return nil }
            return day.formatted(Date.FormatStyle(locale: locale, timeZone: utc).weekday(.abbreviated).day().month(.abbreviated))
        }
        guard let (date, zone) = Self.parse(raw) else { return nil }
        return date.formatted(Date.FormatStyle(locale: locale, timeZone: zone).weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Fri 16 Oct at 10:55".
    public func dateTime(_ raw: String) -> String? {
        guard let (date, zone) = Self.parse(raw) else { return self.date(raw) }
        let day = date.formatted(Date.FormatStyle(locale: locale, timeZone: zone).weekday(.abbreviated).day().month(.abbreviated))
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
        return String(localized: "\(day) at \(time)")
    }

    /// "in 4 days", "3 days ago", from now.
    public func relative(_ raw: String) -> String? {
        let target: Date
        if let (date, _) = Self.parse(raw) {
            target = date
        } else if let components = JSONSchemaValidator.parseDate(raw), let date = Calendar.current.date(from: components) {
            target = date
        } else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: target, relativeTo: now)
    }

    /// The data's age, for the stale badge: "3 h old".
    public func age(since asOf: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(asOf))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 86_400 ? [.day] : seconds >= 3600 ? [.hour] : [.minute]
        formatter.maximumUnitCount = 1
        let amount = formatter.string(from: max(seconds, 60)) ?? ""
        return String(localized: "\(amount) old")
    }

    /// A time and the zone of its offset.
    public static func parse(_ raw: String) -> (Date, TimeZone)? {
        guard let date = WidgetClock.date(raw) else { return nil }
        return (date, offsetZone(raw) ?? .current)
    }

    static func offsetZone(_ raw: String) -> TimeZone? {
        if raw.hasSuffix("Z") || raw.hasSuffix("z") { return TimeZone(identifier: "UTC") }
        guard raw.count >= 6 else { return nil }
        let tail = raw.suffix(6)
        guard let sign = tail.first, sign == "+" || sign == "-", tail.dropFirst(3).first == ":",
              let hours = Int(tail.dropFirst().prefix(2)), let minutes = Int(tail.suffix(2)) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    // MARK: - Deltas

    public enum Direction: Sendable {
        case up, down, flat
    }

    /// How a change reads: its arrow, its colour's meaning (good, bad or neither) and its words.
    public struct DeltaText: Hashable, Sendable {
        public var text: String
        public var direction: Direction
        /// `true` good, `false` bad, `nil` neither (a cost going up is never good).
        public var isGood: Bool?
        /// "up 12 percent versus last Tuesday", for VoiceOver.
        public var spoken: String
    }

    public func delta(_ delta: WidgetDelta) -> DeltaText {
        let direction: Direction = delta.value > 0 ? .up : delta.value < 0 ? .down : .flat
        let magnitude = abs(delta.value)
        let amount: String
        switch delta.format {
        case .percent: amount = percent(magnitude)
        case .currency: amount = currency(magnitude, code: delta.currency)
        case .points: amount = String(localized: "\(Self.number(magnitude, digits: nil, locale: locale)) pts")
        case .number: amount = Self.number(magnitude, digits: nil, locale: locale)
        }
        let isGood: Bool? = switch (delta.good, direction) {
        case (_, .flat), (.neutral, _): nil
        case (.up, .up), (.down, .down): true
        case (.up, .down), (.down, .up): false
        }
        let words = switch direction {
        case .up: String(localized: "up \(amount)")
        case .down: String(localized: "down \(amount)")
        case .flat: String(localized: "no change")
        }
        let spoken = delta.period.map { "\(words) \($0)" } ?? words
        return DeltaText(text: amount, direction: direction, isGood: isGood, spoken: spoken)
    }
}

extension WidgetFieldValue {
    /// The value as shown.
    public func string(_ formatter: WidgetFormatter) -> String {
        switch self {
        case .text(let text): text
        case .quantity(let quantity): formatter.string(quantity)
        }
    }
}

/// A text diff by words (`diff` in text mode): numbers and punctuation count as words, spaces
/// stay with the word before them.
public enum WordDiff {
    public enum Kind: Hashable, Sendable { case same, removed, added }

    public struct Segment: Hashable, Sendable {
        public var kind: Kind
        public var text: String
    }

    public static func diff(_ before: String, _ after: String) -> [Segment] {
        let old = words(before), new = words(after)
        // Longest common subsequence over words: texts here are short (a passage, ≤ 4,000 characters).
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var segments: [Segment] = []
        func append(_ kind: Kind, _ text: String) {
            if let last = segments.last, last.kind == kind {
                segments[segments.count - 1].text += text
            } else {
                segments.append(Segment(kind: kind, text: text))
            }
        }
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i] == new[j] {
                append(.same, old[i]); i += 1; j += 1
            } else if j < new.count, i == old.count || table[i][j + 1] >= table[i + 1][j] {
                append(.added, new[j]); j += 1
            } else {
                append(.removed, old[i]); i += 1
            }
        }
        return hunks(segments)
    }

    /// Each change as one struck run, then one added run (`Things.diff` text mode): a word or two
    /// both sides share in the middle of a change ("as", "the") joins both runs instead of
    /// splitting the change into pieces that read as nonsense.
    static func hunks(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        var removed = "", added = "", held = ""
        func flush() {
            if !removed.isEmpty { out.append(Segment(kind: .removed, text: removed)) }
            if !added.isEmpty { out.append(Segment(kind: .added, text: added)) }
            removed = ""
            added = ""
        }
        func same(_ text: String) {
            if let last = out.last, last.kind == .same { out[out.count - 1].text += text } else { out.append(Segment(kind: .same, text: text)) }
        }
        for segment in segments {
            switch segment.kind {
            case .removed, .added:
                removed += held
                added += held
                held = ""
                if segment.kind == .removed { removed += segment.text } else { added += segment.text }
            case .same:
                let inChange = !removed.isEmpty || !added.isEmpty
                if inChange, isFiller(segment.text) {
                    held += segment.text
                } else {
                    flush()
                    same(held + segment.text)
                    held = ""
                }
            }
        }
        flush()
        if !held.isEmpty { same(held) }
        return out
    }

    /// Shared text too small to stand between two parts of one change: spaces, or one or two short words.
    private static func isFiller(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count <= 2 && words.allSatisfy { $0.count <= 3 }
    }

    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                current.append(character)
            } else if character.isPunctuation, !current.isEmpty, !(current.last?.isWhitespace ?? true) {
                words.append(current)
                current = String(character)
            } else {
                if let last = current.last, last.isWhitespace || last.isPunctuation {
                    words.append(current)
                    current = ""
                }
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Ranges from a payload's numbers, which can come in any order: `lo...hi` with lo above hi stops
/// the app (security scan F4, F20).
public enum WidgetRange {
    /// From the smaller to the larger, and never without width (a slider over nothing can't move).
    public static func ordered(_ a: Double, _ b: Double) -> ClosedRange<Double> {
        let low = Swift.min(a, b), high = Swift.max(a, b)
        return low < high ? low...high : low...(low + 1)
    }

    /// A chart's domain around its values: a little room under the lowest and over the highest,
    /// measured by their size, so negative values get room outward too.
    public static func padded(_ values: [Double]) -> ClosedRange<Double> {
        guard let lowest = values.min(), let highest = values.max() else { return 0...1 }
        return ordered(lowest - abs(lowest) * 0.02, highest + abs(highest) * 0.01)
    }
}

extension ControlWidget.Control {
    /// A slider's range, whichever way round the payload gave its ends.
    public var sliderRange: ClosedRange<Double> {
        WidgetRange.ordered(min ?? 0, max ?? 100)
    }

    /// A step that moves: positive, else the given default.
    public func step(default fallback: Double) -> Double {
        step.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? fallback
    }
}
