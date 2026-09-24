import Foundation

// What the app shows at a glance, computed in one place: today's tasks, the
// payments coming up, and a spend typed as one line ("coffee 25k"). Finance,
// Today, the palette and the edge dock all read these, so they can't drift.

enum Glance {
    // MARK: - Tasks

    /// Open tasks due by the end of today, overdue ones first.
    static func dueByToday(_ todos: [Todo], now: Date = Date()) -> [Todo] {
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        return todos
            .filter { !$0.done && $0.deletedAt == nil && (DateKit.date($0.dueAt).map { $0 <= end } ?? false) }
            .sorted { ($0.dueAt ?? "") < ($1.dueAt ?? "") }
    }

    /// Open tasks with no date, most important first — what to do when
    /// nothing is due.
    static func anytime(_ todos: [Todo]) -> [Todo] {
        todos
            .filter { !$0.done && $0.deletedAt == nil && $0.dueAt == nil }
            .sorted { $0.priority.rank != $1.priority.rank ? $0.priority.rank < $1.priority.rank : $0.createdAt > $1.createdAt }
    }

    /// Tasks ticked off today.
    static func doneToday(_ todos: [Todo], now: Date = Date()) -> [Todo] {
        let today = DateKit.localDate(now)
        return todos.filter {
            $0.done && $0.deletedAt == nil
                && DateKit.date($0.completedAt).map { DateKit.localDate($0) } == today
        }
    }

    // MARK: - Upcoming payments

    struct Payment: Identifiable, Equatable {
        var id: String
        /// The bill's task, when it is one; nil for a detected subscription.
        var todoId: String?
        /// YYYY-MM-DD
        var date: String
        var title: String
        var sub: String
        var category: String
        var amount: Double
        var currency: String
        /// Set when this is a detected subscription rather than a bill.
        var subscription: Subscription?
    }

    /// Bills due in the next `days`, and subscriptions likely to charge in
    /// that time that aren't already tracked as a bill.
    static func upcoming(todos: [Todo], transactions: [Transaction], currency: String,
                         days: Int = 35, limit: Int = 5, now: Date = Date()) -> [Payment] {
        let soon = now.addingTimeInterval(Double(days) * 86_400)
        let bills = todos.compactMap { t -> Payment? in
            guard !t.done, t.deletedAt == nil, let bill = t.bill, let dueAt = t.dueAt,
                  let due = DateKit.date(dueAt), due <= soon else { return nil }
            // The local day: a UTC timestamp's first ten characters are a day
            // early east of Greenwich before 7 in the morning (in Jakarta).
            return Payment(id: t.id, todoId: t.id, date: DateKit.localDate(due), title: t.title,
                           sub: t.rrule.map(repeatLabel) ?? "Bill", category: bill.category,
                           amount: bill.amount, currency: bill.currency ?? currency, subscription: nil)
        }
        func tracked(_ name: String) -> Bool {
            bills.contains { $0.title.lowercased().contains(name.lowercased()) }
        }
        let subs = Insights.detectSubscriptions(transactions.filter { $0.deletedAt == nil })
            .compactMap { s -> Payment? in
                guard let next = DateKit.date(s.nextDate), next <= soon, !tracked(s.merchant) else { return nil }
                return Payment(id: "sub:\(s.merchant)", todoId: nil, date: s.nextDate, title: s.merchant,
                               sub: "Likely subscription", category: s.category, amount: s.amount,
                               currency: s.currency, subscription: s)
            }
        return Array((bills + subs).sorted { $0.date < $1.date }.prefix(limit))
    }

    /// "Monthly" rather than "Every month": it sits beside an amount.
    static func repeatLabel(_ rrule: String) -> String {
        let label = Recurrence.label(rrule)
        let short = ["Every day": "Daily", "Every week": "Weekly", "Every month": "Monthly", "Every year": "Yearly"]
        return short[label] ?? label
    }

    // MARK: - A spend in one line

    /// Wording payment apps use and people typing a spend don't.
    static func looksLikeNotification(_ text: String) -> Bool {
        text.range(of: "\\b(berhasil|sukses|successful|success|pembayaran|payment (to|of|received)|"
                   + "transfer (ke|dari|to|from)|telah|has been|you (paid|received)|anda (membayar|menerima)|"
                   + "qris|top ?up|saldo|balance|ref(erence)?\\s*(no|#|:))\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    struct Spend: Equatable {
        var merchant: String
        /// Positive = spend, negative = income.
        var amount: Double
        var category: String
    }

    /// "coffee 25k", "Rp 45.000 di Warteg", or a pasted e-wallet message.
    /// Nil when there is no amount in it.
    static func spend(_ text: String) -> Spend? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        // A payment notification names the merchant its own way — but only
        // text that reads like one. Any "Rp" and a digit used to qualify, so
        // "kopi Rp 25.000" became "E-wallet payment", and "tiket masuk" or
        // "kartu kredit" were logged as income.
        if let parsed = Wallet.parseNotification(clean), parsed.wallet != nil || looksLikeNotification(clean) {
            return Spend(merchant: parsed.merchant, amount: parsed.amount, category: parsed.category)
        }
        guard let amount = Money.parse(clean), amount != 0 else { return nil }
        let withoutAmount = clean
            .replacingOccurrences(of: "[+-]?\\s*(rp|idr)?\\.?\\s*\\d[\\d.,]*\\s*(rb|ribu|k|jt|juta|m)?\\b",
                                  with: " ", options: [.regularExpression, .caseInsensitive])
        // "coffee 25k at Starbucks": the place is the merchant; what was
        // bought is only a hint for the category.
        var merchant = withoutAmount.range(of: "\\b(at|di|from|dari)\\s+(.+)$",
                                           options: [.regularExpression, .caseInsensitive])
            .map { String(withoutAmount[$0]).replacingOccurrences(
                of: "^(at|di|from|dari)\\s+", with: "", options: [.regularExpression, .caseInsensitive]) }
            ?? withoutAmount
        merchant = merchant
            .replacingOccurrences(of: "\\b(for|untuk)\\b", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–—:"))
        if let first = merchant.first, first.isLowercase {
            merchant = first.uppercased() + merchant.dropFirst()
        }
        let income = amount < 0
        if merchant.isEmpty { merchant = income ? "Income" : "Expense" }
        return Spend(merchant: String(merchant.prefix(60)), amount: amount,
                     category: income ? "Income" : Wallet.guessCategory(clean))
    }
}
