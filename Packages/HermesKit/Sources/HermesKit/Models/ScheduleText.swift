import Foundation

/// A task's schedule in plain words (`screens/iphone/tasks.elyx`): "Every day at 07:30",
/// "Mondays at 09:00", "Every 6 hours". Hermes reports either its own "every 1d at 07:30" form
/// or a cron expression; anything else is shown as it came.
public enum ScheduleText {
    public static func humanize(_ display: String) -> String {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if let words = interval(trimmed) { return words }
        if let words = cron(trimmed) { return words }
        return trimmed
    }

    // MARK: "every 1d at 07:30"

    private static func interval(_ text: String) -> String? {
        let lower = text.lowercased()
        guard lower.hasPrefix("every ") else { return nil }
        let parts = lower.dropFirst(6).components(separatedBy: " at ")
        let span = parts[0].trimmingCharacters(in: .whitespaces)
        let time = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        guard let unit = span.last, let count = Int(span.dropLast()) else { return nil }
        let base: String
        switch (unit, count) {
        case ("d", 1): base = "Every day"
        case ("d", _): base = "Every \(count) days"
        case ("w", 1): base = "Every week"
        case ("w", _): base = "Every \(count) weeks"
        case ("h", 1): base = "Every hour"
        case ("h", _): base = "Every \(count) hours"
        case ("m", 1): base = "Every minute"
        case ("m", _): base = "Every \(count) minutes"
        default: return nil
        }
        return time.map { "\(base) at \($0)" } ?? base
    }

    // MARK: Cron

    private static let weekdays = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]

    private static func cron(_ text: String) -> String? {
        let fields = text.split(separator: " ").map(String.init)
        guard fields.count == 5 else { return nil }
        let (minute, hour, day, month, weekday) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        guard month == "*" else { return nil }
        // Every N minutes / hours.
        if minute.hasPrefix("*/"), hour == "*", day == "*", weekday == "*", let n = Int(minute.dropFirst(2)) {
            return n == 1 ? "Every minute" : "Every \(n) minutes"
        }
        if let m = Int(minute), hour.hasPrefix("*/"), day == "*", weekday == "*", let n = Int(hour.dropFirst(2)) {
            let base = n == 1 ? "Every hour" : "Every \(n) hours"
            return m == 0 ? base : "\(base) at :\(String(format: "%02d", m))"
        }
        if let m = Int(minute), hour == "*", day == "*", weekday == "*" {
            return m == 0 ? "Every hour" : "Every hour at :\(String(format: "%02d", m))"
        }
        guard let m = Int(minute), let h = Int(hour) else { return nil }
        let time = String(format: "%02d:%02d", h, m)
        if day == "*", weekday == "*" { return "Every day at \(time)" }
        if day == "*" {
            if weekday == "1-5" { return "Weekdays at \(time)" }
            if weekday == "0,6" || weekday == "6,0" { return "Weekends at \(time)" }
            let days = weekday.split(separator: ",").compactMap { Int($0) }.filter { (0...7).contains($0) }
            guard !days.isEmpty, days.count == weekday.split(separator: ",").count else { return nil }
            let names = days.map { weekdays[$0 % 7] }
            return "\(names.formatted(.list(type: .and))) at \(time)"
        }
        if weekday == "*", let d = Int(day) {
            return "Monthly on the \(ordinal(d)) at \(time)"
        }
        return nil
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
