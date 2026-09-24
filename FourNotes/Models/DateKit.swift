import Foundation

// Dates are stored exactly as the web app stores them: ISO-8601 UTC with
// milliseconds for timestamps ("2026-09-20T03:12:45.123Z"), and local calendar
// dates ("2026-09-20") for transaction dates. Keeping the same shape means
// string comparison orders timestamps correctly, as it does in JavaScript.

enum DateKit {
    private static let isoOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    // Foundation's formatters are thread-safe for formatting and parsing
    // (they have been since macOS 10.9); `nonisolated(unsafe)` records that
    // rather than paying to rebuild one on every call.
    nonisolated(unsafe) private static let isoIn: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoInNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func nowIso() -> String { iso(Date()) }

    static func iso(_ date: Date) -> String { isoOut.string(from: date) }

    /// Parses the app's timestamps and also bare "YYYY-MM-DD" dates (as local midnight).
    static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        if let d = isoIn.date(from: iso) { return d }
        if let d = isoInNoFraction.date(from: iso) { return d }
        if iso.count == 10 { return dayFormatter.date(from: iso) }
        return nil
    }

    /// Local calendar date. `toISOString()` is UTC and would be wrong early morning in Jakarta.
    static func localDate(_ date: Date = Date()) -> String { dayFormatter.string(from: date) }

    static func localMonth(_ date: Date = Date()) -> String { String(localDate(date).prefix(7)) }

    static func startOfMonth(_ month: String) -> Date? { dayFormatter.date(from: month + "-01") }

    static func uid() -> String { UUID().uuidString.lowercased() }
}

extension Date {
    var isoString: String { DateKit.iso(self) }
    var localDay: String { DateKit.localDate(self) }
}

// MARK: - Human-friendly formatting used across the views

enum Fmt {
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    static func dayMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }

    static func monthYear(_ month: String) -> String {
        guard let d = DateKit.startOfMonth(month) else { return month }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    /// "Today", "Tomorrow", "Yesterday", "Mon 14:00", or "14 Mar".
    static func due(_ iso: String?) -> String {
        guard let date = DateKit.date(iso) else { return "" }
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)
        let today = cal.startOfDay(for: Date())
        let diff = cal.dateComponents([.day], from: today, to: day).day ?? 0
        let hasTime = !(cal.component(.hour, from: date) == 0 && cal.component(.minute, from: date) == 0)
        let clock = hasTime ? " \(time(date))" : ""
        switch diff {
        case 0: return "Today" + clock
        case 1: return "Tomorrow" + clock
        case -1: return "Yesterday" + clock
        case 2...6:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "EEE"
            return f.string(from: date) + clock
        default: return dayMonth(date) + clock
        }
    }

    /// "just now", "5m ago", "3h ago", "2d ago", then a date.
    static func relative(_ iso: String?) -> String {
        guard let date = DateKit.date(iso) else { return "" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        return dayMonth(date)
    }

    static func greeting(_ date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    static func longDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: date)
    }
}
