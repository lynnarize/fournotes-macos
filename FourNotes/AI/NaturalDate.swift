import Foundation

// Turning "tomorrow at 10 am" into a real time, without asking a model to do it.
//
// Apple's on-device model is good at spotting *that* a time was mentioned and
// poor at calendar arithmetic: it dropped "tommorow at 10 am" entirely and
// scheduled "every Monday" monthly. So the model copies the words, and this
// resolves them with the system's own date detector — after fixing the
// misspellings people actually type and translating the Indonesian the app is
// used with.

enum NaturalDate {
    /// A resolved time, and the words it was read from so they can be taken
    /// out of a title.
    struct Match {
        var date: Date
        var range: Range<String.Index>
    }

    /// The first time `text` mentions, or nil. A day with no time of day is
    /// placed at 9:00; a time of day that has already passed today is tomorrow.
    static func resolve(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        find(in: text, now: now, calendar: calendar)?.date
    }

    static func find(in raw: String, now: Date = Date(), calendar: Calendar = .current) -> Match? {
        let text = normalised(raw)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // "in 2 hours": counted from `now` here, because the system detector
        // always counts from the real clock.
        if let m = text.firstMatch(of: /(?i)\bin\s+(\d{1,3})\s*(min|mins|minute|minutes|hr|hrs|hour|hours|day|days|week|weeks)\b/),
           let n = Int(m.1), let range = text.range(of: String(m.0)) {
            let unit = m.2.lowercased()
            let component: Calendar.Component = unit.hasPrefix("min") ? .minute
                : unit.hasPrefix("h") ? .hour : unit.hasPrefix("d") ? .day : .weekOfYear
            if let date = calendar.date(byAdding: component, value: n, to: now) {
                return Match(date: date, range: range)
            }
        }

        let detected = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue))?
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        let detectedRange = detected.flatMap { Range($0.range, in: text) }

        // "every month on the 5th at 9am": the detector sees only "9am" and
        // answers today. An ordinal day wins unless the detector found a real
        // day ("tomorrow", "Friday", "12 Oct") to go with it.
        if let dayOfMonth = dayOfMonthMatch(text, now: now, calendar: calendar),
           detectedRange.map({ !mentionsDay(String(text[$0])) }) ?? true {
            return Match(date: dayOfMonth, range: text.startIndex..<text.endIndex)
        }

        guard var date = detected?.date, let range = detectedRange else { return nil }

        let phrase = String(text[range])
        if !mentionsTimeOfDay(phrase) && !isRelativeDuration(phrase) {
            date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        } else if date < now, !mentionsDay(phrase) {
            // "at 7pm" said at 8pm means tomorrow.
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return Match(date: date, range: range)
    }

    /// The words to remove from a title: the time phrase and the little word
    /// that introduced it ("for", "at", "on", "by").
    static func removingTime(from title: String, now: Date = Date()) -> String {
        let text = normalised(title)
        guard let match = find(in: text, now: now) else { return title }
        var out = text
        out.removeSubrange(match.range)
        out = out.replacingOccurrences(of: "\\s+(for|at|on|by|this|next)\\s*$", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–—:"))
        return trimmed.isEmpty ? title : trimmed
    }

    /// A title that carries its own time — "Buy groceries at 10 AM tomorrow" —
    /// split into the task and the time. Nil unless the words clearly name a
    /// day or a time of day, so "Read chapter 5" stays as it is.
    static func splitTitle(_ title: String, now: Date = Date()) -> (title: String, date: Date)? {
        let text = normalised(title)
        guard let match = find(in: text, now: now),
              match.range != text.startIndex..<text.endIndex
        else { return nil }
        let phrase = String(text[match.range])
        guard mentionsDay(phrase) || mentionsTimeOfDay(phrase) || isRelativeDuration(phrase) else { return nil }
        let rest = removingTime(from: title, now: now)
        guard rest != title, !rest.isEmpty else { return nil }
        return (rest, match.date)
    }

    // MARK: - Normalising what people type

    /// Misspellings and Indonesian phrasing, rewritten into what the system
    /// date detector understands.
    static func normalised(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            // English misspellings
            ("\\b(tommorow|tomorow|tommorrow|tomorrw|tomoro|tmrw|tmr|tmrrw)\\b", "tomorrow"),
            ("\\b(tonite)\\b", "tonight"),
            ("\\b(\\d{1,2})\\s*(a\\.m\\.|a\\.m)", "$1am"),
            ("\\b(\\d{1,2})\\s*(p\\.m\\.|p\\.m)", "$1pm"),
            // Indonesian: times of day first, while "jam" is still there
            ("\\bjam\\s+(\\d{1,2})(?:[.:](\\d{2}))?\\s+pagi\\b", "at $1:$2am"),
            ("\\bjam\\s+(\\d{1,2})(?:[.:](\\d{2}))?\\s+(siang)\\b", "at $1:$2pm"),
            ("\\bjam\\s+(\\d{1,2})(?:[.:](\\d{2}))?\\s+(sore|malam)\\b", "at $1:$2pm"),
            ("\\bjam\\s+(\\d{1,2})[.:](\\d{2})\\b", "at $1:$2"),
            ("\\bjam\\s+(\\d{1,2})\\b", "at $1:00"),
            // Indonesian: days
            ("\\bbesok\\s+lusa\\b|\\blusa\\b", "the day after tomorrow"),
            ("\\bbesok\\b", "tomorrow"),
            ("\\bhari ini\\b", "today"),
            ("\\bnanti malam\\b|\\bmalam ini\\b", "tonight"),
            ("\\bminggu depan\\b", "next week"),
            ("\\bbulan depan\\b", "next month"),
            ("\\bsenin\\b", "Monday"), ("\\bselasa\\b", "Tuesday"), ("\\brabu\\b", "Wednesday"),
            ("\\bkamis\\b", "Thursday"), ("\\bjumat\\b|\\bjum'at\\b", "Friday"),
            ("\\bsabtu\\b", "Saturday"),
            ("\\b(\\d+)\\s+jam\\s+lagi\\b", "in $1 hours"),
            ("\\b(\\d+)\\s+menit\\s+lagi\\b", "in $1 minutes"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template,
                                       options: [.regularExpression, .caseInsensitive])
        }
        // "at 9:am" from a pagi/sore rule with no minutes.
        s = s.replacingOccurrences(of: ":(am|pm)\\b", with: "$1", options: .regularExpression)
        return s
    }

    // MARK: - Pieces

    private static func mentionsTimeOfDay(_ phrase: String) -> Bool {
        phrase.range(of: "\\d{1,2}(:\\d{2})?\\s*(am|pm)|\\d{1,2}:\\d{2}|noon|midnight|morning|afternoon|evening|tonight|night",
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isRelativeDuration(_ phrase: String) -> Bool {
        phrase.range(of: "\\bin\\s+\\d+\\s*(min|minute|hour|hr)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func mentionsDay(_ phrase: String) -> Bool {
        phrase.range(of: "today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next|\\d{1,2}/\\d{1,2}|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec",
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "the 5th", "on the 25th at 9am": the next time that day of the month
    /// comes round. The system detector does not read a bare ordinal as a date.
    private static func dayOfMonthMatch(_ text: String, now: Date, calendar: Calendar) -> Date? {
        guard let m = text.firstMatch(of: /(?i)\b(?:on\s+)?(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)\b/),
              let day = Int(m.1), (1...31).contains(day),
              // A month name next to it is an ordinary date the detector handles.
              text.range(of: "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec",
                         options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }

        var hour = 9, minute = 0
        if let t = text.firstMatch(of: /(?i)(\d{1,2})(?::(\d{2}))?\s*(am|pm)/), var h = Int(t.1) {
            let pm = t.3.lowercased() == "pm"
            if pm && h < 12 { h += 12 }
            if !pm && h == 12 { h = 0 }
            hour = h
            minute = t.2.flatMap { Int($0) } ?? 0
        }

        var components = calendar.dateComponents([.year, .month], from: now)
        for _ in 0..<13 {
            let range = calendar.range(of: .day, in: .month,
                                       for: calendar.date(from: components) ?? now) ?? 1..<29
            components.day = min(day, range.upperBound - 1)
            components.hour = hour
            components.minute = minute
            if let candidate = calendar.date(from: components), candidate > now { return candidate }
            components.day = nil
            components.month = (components.month ?? 1) + 1
        }
        return nil
    }
}
