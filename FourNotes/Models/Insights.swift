import Foundation

// Pure, synchronous analysis over local data: currency conversion, budgets,
// subscription detection, bill splits and smart reminder timing.
// Ported from src/lib/insights.ts.

struct BudgetStatus: Identifiable {
    var category: String
    var spent: Double
    var limit: Double
    var ratio: Double
    var id: String { category }
}

struct Subscription: Identifiable, Equatable {
    var merchant: String
    var amount: Double
    var currency: String
    var category: String
    var lastDate: String
    var nextDate: String
    var count: Int
    var id: String { merchant + lastDate }
}

enum Insights {
    /// Amount in the base currency.
    static func baseAmount(_ t: Transaction, _ base: String) -> Double {
        t.currency == base ? t.amount : t.amount * (t.fxRate ?? 1)
    }

    /// What the user actually paid, after other people's shares.
    static func myShare(_ t: Transaction, _ base: String) -> Double {
        let others = (t.splits ?? []).reduce(0) { $0 + $1.amount }
        var copy = t
        copy.amount = t.amount - others
        return baseAmount(copy, base)
    }

    static func spendByCategory(_ txs: [Transaction], _ base: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for t in txs where t.amount > 0 {
            out[t.category, default: 0] += myShare(t, base)
        }
        return out
    }

    static func budgetStatus(_ monthTxs: [Transaction], _ settings: AppSettings) -> [BudgetStatus] {
        let spent = spendByCategory(monthTxs, settings.currency)
        return settings.budgets
            .filter { $0.value > 0 }
            .map { category, limit in
                BudgetStatus(category: category, spent: spent[category] ?? 0, limit: limit,
                             ratio: (spent[category] ?? 0) / limit)
            }
            .sorted { $0.ratio > $1.ratio }
    }

    // MARK: - Subscriptions

    private static func normMerchant(_ m: String) -> String {
        let withoutWords = m.lowercased().replacingOccurrences(
            of: "\\b(pt|tbk|inc|ltd|id|indonesia|com)\\b", with: "", options: .regularExpression)
        let letters = withoutWords.filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII }
        return String(letters.prefix(20))
    }

    private static let dayInterval: TimeInterval = 86_400

    /// Same merchant, similar amount (±15%), roughly monthly (25–35 days apart), at least twice.
    static func detectSubscriptions(_ txs: [Transaction]) -> [Subscription] {
        var groups: [String: [Transaction]] = [:]
        for t in txs where t.amount > 0 && t.deletedAt == nil {
            let k = normMerchant(t.merchant)
            if !k.isEmpty { groups[k, default: []].append(t) }
        }

        var subs: [Subscription] = []
        for var list in groups.values where list.count >= 2 {
            list.sort { $0.date < $1.date }
            // Walk back from the latest charge while the pattern holds.
            var run = [list[list.count - 1]]
            var i = list.count - 2
            while i >= 0 {
                let newer = run[0], older = list[i]
                guard let nd = DateKit.date(newer.date), let od = DateKit.date(older.date) else { break }
                let gap = nd.timeIntervalSince(od) / dayInterval
                let similar = abs(newer.amount - older.amount) <= 0.15 * newer.amount
                if gap < 1 { i -= 1; continue }  // duplicate on the same day
                if gap >= 25 && gap <= 35 && similar { run.insert(older, at: 0); i -= 1 } else { break }
            }
            guard run.count >= 2, let last = run.last, let lastDate = DateKit.date(last.date) else { continue }
            // Ignore patterns that stopped more than ~2 months ago.
            if Date().timeIntervalSince(lastDate) > 70 * dayInterval { continue }
            let next = Calendar.current.date(byAdding: .month, value: 1, to: lastDate) ?? lastDate
            subs.append(Subscription(merchant: last.merchant, amount: last.amount, currency: last.currency,
                                     category: last.category, lastDate: last.date,
                                     nextDate: DateKit.localDate(next), count: run.count))
        }
        return subs.sorted { $0.nextDate < $1.nextDate }
    }

    // MARK: - Bill splits

    static func equalSplit(_ total: Double, _ people: [String], includeMe: Bool = true) -> [Split] {
        let n = people.count + (includeMe ? 1 : 0)
        guard n > 0, !people.isEmpty else { return [] }
        let share = (total / Double(n) * 100).rounded() / 100
        return people.map { Split(name: $0, amount: share, settled: false) }
    }

    /// Unsettled amounts owed to the user, per person, in the base currency.
    static func owedToMe(_ txs: [Transaction], _ base: String) -> [(name: String, amount: Double)] {
        var out: [String: Double] = [:]
        for t in txs where t.deletedAt == nil {
            for s in t.splits ?? [] where !s.settled {
                var copy = t
                copy.amount = s.amount
                out[s.name, default: 0] += baseAmount(copy, base)
            }
        }
        return out.map { (name: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }

    // MARK: - Smart reminder timing

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }

    /// Suggest a reminder time from when the user usually finishes similar tasks:
    /// take done tasks sharing words with this one, find their typical hour of
    /// completion, and pick the next such hour (before the due time if there is one).
    static func suggestReminder(_ todo: Todo, _ all: [Todo], now: Date = Date()) -> (at: String, reason: String)? {
        let mine = words(todo.title)
        let done = all.filter { $0.id != todo.id && $0.done && $0.completedAt != nil && $0.deletedAt == nil }
        var pool = done.filter { !words($0.title).isDisjoint(with: mine) }
        var basis = "similar tasks"
        if pool.count < 2 { pool = done; basis = "tasks" }
        if pool.count < 3 && basis == "tasks" { return nil }

        let cal = Calendar.current
        // Circular mean isn't needed for day-time habits; median hour is robust enough.
        let minutes = pool.compactMap { t -> Int? in
            guard let d = DateKit.date(t.completedAt) else { return nil }
            return cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d)
        }.sorted()
        guard !minutes.isEmpty else { return nil }
        let median = minutes[minutes.count / 2]
        let hour = median / 60
        let minute = Int((Double(median % 60) / 15).rounded()) * 15

        var at = cal.date(bySettingHour: hour, minute: minute % 60, second: 0, of: now) ?? now
        if minute >= 60 { at = cal.date(byAdding: .minute, value: 60, to: at) ?? at }
        if at <= now { at = cal.date(byAdding: .day, value: 1, to: at) ?? at }

        if let due = DateKit.date(todo.dueAt), at >= due {
            // Same habit hour on an earlier day, or 1 hour before due as a fallback.
            var earlier = cal.date(bySettingHour: hour, minute: minute % 60, second: 0, of: due) ?? due
            if earlier >= due { earlier = cal.date(byAdding: .day, value: -1, to: earlier) ?? earlier }
            at = earlier > now ? earlier : max(now.addingTimeInterval(300), due.addingTimeInterval(-3600))
        }

        let hh = String(format: "%02d:%02d", hour, minute % 60)
        return (at: DateKit.iso(at), reason: "You usually finish \(basis) around \(hh)")
    }
}
