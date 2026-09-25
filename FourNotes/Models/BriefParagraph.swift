import Foundation

// Today's brief as one short paragraph told like a story, for when a
// point-by-point list is more than you want to read. Written from the same
// data as the list, so it is there at once and needs no model. The phrases
// worth a closer look are links — a task, yesterday's spending, a budget —
// and clicking one goes to where the details are.

enum BriefParagraph {
    /// Where a phrase leads.
    enum Target: Equatable, Sendable {
        case todos
        case todo(String)
        case finance
        case notes
        case note(String)
    }

    /// A run of the paragraph: plain text, or a phrase that leads somewhere.
    struct Piece: Equatable, Sendable {
        var text: String
        var target: Target?
    }

    struct Item: Sendable {
        var id: String
        var title: String
        var due: Date?
    }

    struct Spend: Sendable {
        var category: String
        var amount: Double
    }

    struct NoteRef: Sendable {
        var id: String
        var title: String
    }

    struct Input: Sendable {
        var now: Date
        /// Due today or overdue, soonest first.
        var due: [Item]
        /// High-priority tasks with no date, used when nothing is due.
        var focus: [Item]
        var yesterday: [Spend]
        var currency: String
        /// Budgets, subscriptions and money owed, as the list shows them.
        var alerts: [String]
        /// Quick notes written today, newest first.
        var notesToday: [NoteRef]
    }

    /// The day told as a short story, in order: how yesterday ended, what
    /// today holds, what to keep an eye on along the way, and what's already
    /// been jotted down. Only the parts with something to say are told.
    static func compose(_ input: Input) -> [Piece] {
        var out: [Piece] = []
        func plain(_ s: String) { out.append(Piece(text: s, target: nil)) }
        func link(_ s: String, _ t: Target) { out.append(Piece(text: s, target: t)) }
        func space() { if !out.isEmpty { plain(" ") } }

        // How yesterday ended.
        let total = input.yesterday.reduce(0) { $0 + $1.amount }
        if total > 0 {
            plain("Yesterday closed with ")
            link(Money.format(total, input.currency, compact: true), .finance)
            plain(" spent")
            if let top = topCategory(input.yesterday), !top.isEmpty {
                let categories = Set(input.yesterday.map(\.category)).count
                plain(categories > 1 ? ", most of it on \(top)" : " on \(top)")
            }
            plain(".")
        }

        // What today holds.
        space()
        let startOfToday = Calendar.current.startOfDay(for: input.now)
        let isLate = { (t: Item) in (t.due ?? input.now) < startOfToday }
        let when = { (t: Item) -> String in
            if isLate(t) { return ", carried over from an earlier day" }
            if let due = t.due, hasTime(due) { return " at \(Fmt.time(due))" }
            return ""
        }
        if let first = input.due.first {
            plain("\(stage(input.now)) holds ")
            if input.due.count == 1 {
                plain("just ")
                link("one task", .todos)
                plain(": ")
                link(name(first.title), .todo(first.id))
                plain(when(first))
            } else {
                link("\(input.due.count) tasks", .todos)
                plain(", and it opens with ")
                link(name(first.title), .todo(first.id))
                plain(when(first))
                if !isLate(first), let late = input.due.dropFirst().first(where: isLate) {
                    plain(", while ")
                    link(name(late.title), .todo(late.id))
                    plain(" has been waiting since an earlier day")
                }
            }
            plain(".")
        } else if let top = input.focus.first {
            plain("Nothing is pressing today, which leaves room for ")
            link(name(top.title), .todo(top.id))
            plain(" to finally move forward.")
        } else {
            plain("Nothing is pressing today, so the page is yours to fill.")
        }

        // Along the way: at most two, without the figures in brackets.
        let alerts = input.alerts.prefix(2).map { asClause(shortAlert($0)) }
        if !alerts.isEmpty {
            plain(" Along the way, keep in mind that ")
            for (i, alert) in alerts.enumerated() {
                if i > 0 { plain(" and ") }
                link(alert, .finance)
            }
            plain(".")
        }

        // What's already been jotted down.
        if let only = input.notesToday.first, input.notesToday.count == 1 {
            plain(" And ")
            link(name(only.title, fallback: "the quick note"), .note(only.id))
            plain(", jotted down earlier, is right where you left it.")
        } else if input.notesToday.count > 1 {
            plain(" And the ")
            link("\(input.notesToday.count) quick notes", .notes)
            plain(" you jotted down today are right where you left them.")
        }

        return merged(out)
    }

    /// The paragraph as plain text, for accessibility and tests.
    static func text(_ pieces: [Piece]) -> String { pieces.map(\.text).joined() }

    // MARK: - Links as URLs

    /// Links in the paragraph are URLs so SwiftUI's `Text` can draw and click
    /// them; this app's own scheme, handled by Today, never the system.
    static let scheme = "fournotes-brief"

    static func url(_ target: Target) -> URL? {
        let path: String
        switch target {
        case .todos: path = "todos"
        case .todo(let id): path = "todo/\(id)"
        case .finance: path = "finance"
        case .notes: path = "notes"
        case .note(let id): path = "note/\(id)"
        }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(scheme)://\(encoded)")
    }

    static func target(_ url: URL) -> Target? {
        guard url.scheme == scheme else { return nil }
        let host = url.host(percentEncoded: false) ?? ""
        let id = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch (host, id.isEmpty) {
        case ("todos", true): return .todos
        case ("finance", true): return .finance
        case ("notes", true): return .notes
        case ("todo", false): return .todo(id)
        case ("note", false): return .note(id)
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func name(_ title: String, fallback: String = "an untitled task") -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return fallback }
        return t.count > 48 ? String(t.prefix(45)).trimmingCharacters(in: .whitespaces) + "…" : t
    }

    private static func hasTime(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }

    private static func topCategory(_ spends: [Spend]) -> String? {
        var totals: [String: Double] = [:]
        for s in spends { totals[s.category, default: 0] += s.amount }
        return totals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// Where the day's story picks up, going by the time of day.
    private static func stage(_ now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 0..<12: return "The day ahead"
        case 12..<18: return "The rest of the afternoon"
        default: return "The evening"
        }
    }

    /// "Food budget 85% used" → "your Food budget is 85% used", so it reads
    /// in a sentence; the other heads-ups already do.
    static func asClause(_ alert: String) -> String {
        alert.replacingOccurrences(of: "^(.+) budget (\\d+% used)$", with: "your $1 budget is $2",
                                   options: .regularExpression)
    }

    /// "Food budget 85% used (Rp 850k of Rp 1jt)" → "Food budget 85% used".
    static func shortAlert(_ alert: String) -> String {
        alert.replacingOccurrences(of: "\\s*\\([^)]*\\)\\s*$", with: "", options: .regularExpression)
    }

    /// Neighbouring plain runs joined, so the text has fewer pieces.
    private static func merged(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        for piece in pieces {
            if piece.target == nil, let last = out.last, last.target == nil {
                out[out.count - 1].text += piece.text
            } else {
                out.append(piece)
            }
        }
        return out
    }
}

/// How Today's brief reads: one short paragraph (the default), or the
/// written brief and what's due, point by point. Chosen in Settings and
/// during setup.
enum BriefStyle: String, CaseIterable, Sendable {
    case paragraph, points

    static let storageKey = "fournotes.today.briefStyle"

    var label: String {
        switch self {
        case .paragraph: return "One paragraph"
        case .points: return "Point by point"
        }
    }

    var detail: String {
        switch self {
        case .paragraph: return "Your day told as a short story. Click an underlined phrase for the details."
        case .points: return "The written brief, then each task and heads-up on its own line."
        }
    }

    var icon: String {
        switch self {
        case .paragraph: return "alignLeft"
        case .points: return "listBullet"
        }
    }
}
