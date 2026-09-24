import Foundation

// A small subset of RFC 5545 RRULE: FREQ, INTERVAL and BYMONTHDAY. The same
// format calendars use, so a rule can be handed to Google Calendar unchanged.
//
// BYMONTHDAY exists to stop month-end bills drifting. Advancing from January
// 31st has to clamp to February 28th, but the *next* step must return to the
// 31st — so the day the user actually chose is recorded in the rule rather than
// being re-read from the last occurrence.

enum Freq: String, CaseIterable, Identifiable {
    case DAILY, WEEKLY, MONTHLY, YEARLY
    var id: String { rawValue }
    var unit: String {
        switch self {
        case .DAILY: return "day"
        case .WEEKLY: return "week"
        case .MONTHLY: return "month"
        case .YEARLY: return "year"
        }
    }
}

enum Recurrence {
    struct Rule: Equatable {
        var freq: Freq
        var interval: Int
        /// The day of the month the user chose, when it cannot be represented
        /// by every month (29–31).
        var monthDay: Int?
    }

    /// Nobody repeats something every thousand months, and an unbounded value
    /// read from JSON overflows when multiplied out.
    static let maxInterval = 1000

    // MARK: - Reading and writing rules

    static func parse(_ rrule: String?) -> Rule? {
        guard let rrule, !rrule.isEmpty else { return nil }
        let body = rrule.replacingOccurrences(
            of: "^RRULE:", with: "", options: [.regularExpression, .caseInsensitive])

        // A bare frequency ("MONTHLY", "monthly") is what small models write.
        if let freq = Freq(rawValue: body.trimmingCharacters(in: .whitespaces).uppercased()) {
            return Rule(freq: freq, interval: 1, monthDay: nil)
        }

        var parts: [String: String] = [:]
        for pair in body.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces).uppercased()
            }
            if kv.count == 2 { parts[kv[0]] = kv[1] }
        }
        guard let raw = parts["FREQ"], let freq = Freq(rawValue: raw) else { return nil }

        let interval = min(maxInterval, max(1, Int(parts["INTERVAL"] ?? "1") ?? 1))
        let monthDay = (parts["BYMONTHDAY"].flatMap { Int($0) }).flatMap { (1...31).contains($0) ? $0 : nil }
        return Rule(freq: freq, interval: interval, monthDay: monthDay)
    }

    static func make(_ freq: Freq, _ interval: Int = 1, monthDay: Int? = nil) -> String {
        var out = "FREQ=\(freq.rawValue);INTERVAL=\(min(maxInterval, max(1, interval)))"
        if let monthDay, (1...31).contains(monthDay) { out += ";BYMONTHDAY=\(monthDay)" }
        return out
    }

    /// The canonical form of whatever a model or an older document contained.
    /// Pass the task's due date so a month-end day can be anchored.
    static func normalised(_ rrule: String?, anchoredTo date: Date? = nil) -> String? {
        guard let rule = parse(rrule) else { return nil }
        var monthDay = rule.monthDay
        if monthDay == nil, rule.freq == .MONTHLY || rule.freq == .YEARLY, let date {
            let day = Calendar.current.component(.day, from: date)
            // Only days that some months lack need recording.
            if day >= 29 { monthDay = day }
        }
        return make(rule.freq, rule.interval, monthDay: monthDay)
    }

    // MARK: - Advancing

    /// The next occurrence after `iso`, exactly one interval later.
    static func nextOccurrence(_ iso: String, _ rrule: String) -> String {
        guard let rule = parse(rrule), let date = DateKit.date(iso) else { return iso }
        let cal = Calendar.current

        switch rule.freq {
        case .DAILY:
            return DateKit.iso(cal.date(byAdding: .day, value: rule.interval, to: date) ?? date)
        case .WEEKLY:
            return DateKit.iso(cal.date(byAdding: .day, value: 7 * rule.interval, to: date) ?? date)
        case .MONTHLY, .YEARLY:
            let months = rule.freq == .MONTHLY ? rule.interval : 12 * rule.interval
            guard let moved = cal.date(byAdding: .month, value: months, to: date) else { return iso }
            // Calendar already clamps (Jan 31 -> Feb 28). When the rule records
            // the day the user chose, restore it wherever the month allows.
            guard let anchor = rule.monthDay else { return DateKit.iso(moved) }
            return DateKit.iso(applying(day: anchor, to: moved, calendar: cal))
        }
    }

    /// The first occurrence at or after `notBefore`. Completing a task that was
    /// due months ago must not schedule the next one in the past.
    static func next(after iso: String, _ rrule: String, notBefore: Date = Date()) -> String {
        guard parse(rrule) != nil else { return iso }
        var current = iso
        // Bounded: a daily rule three years behind still settles well inside this.
        for _ in 0..<2000 {
            guard let date = DateKit.date(current), date < notBefore else { break }
            let advanced = nextOccurrence(current, rrule)
            if advanced == current { break }
            current = advanced
        }
        return current
    }

    /// The occurrence after the one just completed. A task completed early must
    /// advance past its future due date, and a task with no date must not be
    /// rescheduled for the exact completion instant.
    static func nextAfterCompleting(_ iso: String, _ rrule: String,
                                    notBefore: Date = Date()) -> String {
        guard parse(rrule) != nil else { return iso }
        let completed = nextOccurrence(iso, rrule)
        return next(after: completed, rrule, notBefore: notBefore)
    }

    private static func applying(day: Int, to date: Date, calendar cal: Calendar) -> Date {
        let lastDay = cal.range(of: .day, in: .month, for: date)?.count ?? 28
        var parts = cal.dateComponents([.year, .month, .hour, .minute, .second], from: date)
        parts.day = min(day, lastDay)
        return cal.date(from: parts) ?? date
    }

    // MARK: - Display

    static func label(_ rrule: String?) -> String {
        guard let rule = parse(rrule) else { return "" }
        return rule.interval == 1 ? "Every \(rule.freq.unit)" : "Every \(rule.interval) \(rule.freq.unit)s"
    }
}
