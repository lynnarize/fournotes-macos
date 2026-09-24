import Foundation

// Applying AI actions, and building the compact context the AI sees.
// Ported from applyActions() / buildContext() in src/lib/store.tsx.

extension Store {
    @discardableResult
    func applyActions(_ actions: [AIAction], imageFile: String? = nil,
                      source: NoteSource = .chat) -> ApplyResult {
        var result = ApplyResult()
        var refs: [String: String] = [:]   // AI ref -> created note id

        func file(_ label: String, _ link: ChangeLink?) {
            result.filed.append(label)
            result.links.append(link)
            if let link, link.kind != .budget { result.created.append(link) }
        }
        func fallbackNote() -> String? { refs.count == 1 ? refs.values.first : nil }
        func normalisedDate(_ raw: String) -> String {
            DateKit.date(raw).map(DateKit.localDate) ?? DateKit.localDate()
        }
        func normalisedCurrency(_ raw: String?, fallback: String) -> String {
            guard let raw, FXRates.isCurrencyCode(raw) else { return fallback }
            return raw.uppercased()
        }
        func normalisedPeople(_ raw: [String]) -> [String] {
            raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        func safeBill(_ raw: Bill?) -> Bill? {
            guard let raw, Money.isValidAmount(raw.amount), raw.amount > 0 else { return nil }
            var bill = raw
            if let currency = bill.currency {
                bill.currency = FXRates.isCurrencyCode(currency) ? currency.uppercased() : nil
            }
            return bill
        }

        // Notes first so tasks and spending in the same batch can link to them.
        // A partition, not a sort: `sorted` needs a strict weak ordering, and
        // "is a note" is not one — it reported two notes as each preceding the
        // other, which reversed them and mislinked their tasks.
        let isNote: (AIAction) -> Bool = { if case .createNote = $0 { return true }; return false }
        let ordered = actions.filter(isNote) + actions.filter { !isNote($0) }

        for action in ordered {
            switch action {
            case let .createNote(title, content, tags, ref):
                let n = addNote {
                    // Models write Markdown; a note shows "**" as it is.
                    $0.title = title.replacingOccurrences(of: "**", with: "")
                    $0.content = ReplyNote.noteText(fromMarkdown: content)
                    $0.tags = tags
                    $0.source = source
                    $0.imageFile = imageFile
                }
                refs[ref ?? "note\(refs.count)"] = n.id
                file("📝 Note: \(title)", ChangeLink(kind: .notes, id: n.id))

            case let .createTodo(title, notes, dueAt, remindAt, priority, status, rrule, bill, noteRef):
                // A model that left the time in the title ("Buy groceries at
                // 10 AM tomorrow", from a recording) gets it read here.
                var title = title
                var dueAt = dueAt
                if dueAt == nil, let split = NaturalDate.splitTitle(title) {
                    title = split.title
                    dueAt = DateKit.iso(split.date)
                }
                // "Remind me … at 7pm" given only as a reminder is due then too,
                // so it shows under Due today and sorts with dated tasks.
                if dueAt == nil { dueAt = remindAt }
                let due = dueAt.flatMap { DateKit.date($0) }.map(DateKit.iso)
                let reminder = (remindAt ?? dueAt).flatMap { DateKit.date($0) }.map(DateKit.iso)
                let normalisedRule = rrule.flatMap {
                    Recurrence.normalised($0, anchoredTo: due.flatMap(DateKit.date))
                }
                let todo = addTodo {
                    $0.title = title
                    $0.notes = notes
                    $0.dueAt = due
                    $0.remindAt = reminder
                    $0.priority = priority ?? .medium
                    $0.source = source
                    $0.rrule = normalisedRule
                    $0.bill = safeBill(bill)
                    $0.doing = status == "doing" ? true : nil
                    $0.noteId = noteRef.flatMap { refs[$0] } ?? fallbackNote()
                }
                let icon = normalisedRule != nil ? "🔁" : (status == "doing" ? "▶️" : "✅")
                let kind = status == "doing" ? "Doing" : "To-do"
                file("\(icon) \(kind): \(title)", ChangeLink(kind: .todos, id: todo.id))

            case let .addTransaction(merchant, amount, currency, category, date, items, splitWith, noteRef):
                let safeAmount = Money.isValidAmount(amount) ? amount : 0
                let people = normalisedPeople(splitWith)
                let splits = safeAmount > 0 && !people.isEmpty
                    ? Insights.equalSplit(safeAmount, people) : nil
                let t = addTransaction {
                    $0.merchant = merchant
                    $0.amount = safeAmount
                    $0.currency = normalisedCurrency(currency, fallback: settings.currency)
                    $0.category = Store.matchCategory(category, categories)
                    $0.date = normalisedDate(date)
                    $0.items = items
                    $0.source = source
                    $0.imageFile = imageFile
                    $0.splits = splits
                    $0.noteId = noteRef.flatMap { refs[$0] } ?? fallbackNote()
                }
                result.transactionIds.append(t.id)
                let suffix = splits == nil ? "" : " (split \(people.count + 1))"
                file("💸 Finance: \(merchant)\(suffix)", ChangeLink(kind: .transactions, id: t.id))

            case let .createSticky(text, _):
                // Stickies became quick notes; the tool keeps its name.
                let n = addNote {
                    QuickNote.apply(text, to: &$0)
                    $0.source = source
                }
                file("📝 Quick note: \(String(text.prefix(30)))", ChangeLink(kind: .notes, id: n.id))

            case let .startTodo(titleContains):
                let q = titleContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !q.isEmpty,
                   let hit = liveTodos.first(where: { !$0.done && $0.title.lowercased().contains(q) }) {
                    updateTodo(hit.id) { $0.doing = true }
                    file("▶️ Doing: \(hit.title)", ChangeLink(kind: .todos, id: hit.id))
                }

            case let .completeTodo(titleContains):
                let q = titleContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !q.isEmpty,
                   let hit = liveTodos.first(where: { !$0.done && $0.title.lowercased().contains(q) }) {
                    file("☑️ Done: \(hit.title)", ChangeLink(kind: .todos, id: hit.id))
                    // Follow-ups (the next repeat, a bill logged) have no single row to show.
                    for extra in toggleTodo(hit.id, done: true) { file(extra, nil) }
                }

            case let .setBudget(category, amount):
                let matched = Store.matchCategory(category, categories)
                setBudget(matched, amount)
                file("🎯 Budget: \(matched)", ChangeLink(kind: .budget, id: matched))

            case let .splitTransaction(merchantContains, people, includeMe):
                let q = merchantContains.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let names = normalisedPeople(people)
                let hit = q.isEmpty || names.isEmpty ? nil : liveTransactions
                    .filter { $0.amount > 0 && $0.merchant.lowercased().contains(q) }
                    .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
                    .first
                if let hit {
                    let splits = Insights.equalSplit(hit.amount, names,
                                                     includeMe: includeMe ?? true)
                    guard !splits.isEmpty else { continue }
                    updateTransaction(hit.id) {
                        $0.splits = splits
                    }
                    result.transactionIds.append(hit.id)
                    file("👥 Split: \(hit.merchant) with \(names.joined(separator: ", "))",
                         ChangeLink(kind: .transactions, id: hit.id))
                }
            }
        }
        return result
    }

    /// Compact context the client sends so the AI can answer questions about data.
    func buildContext(relevantNotes: [Note] = []) -> ClientContext {
        ClientContext(
            now: DateKit.nowIso(),
            timezone: TimeZone.current.identifier,
            currency: settings.currency,
            notes: liveNotes.prefix(30).map {
                .init(title: $0.title, snippet: String($0.content.prefix(240)))
            },
            relevantNotes: relevantNotes.map {
                .init(title: $0.title, content: String($0.content.prefix(3000)), updatedAt: $0.updatedAt)
            },
            todos: liveTodos.prefix(50).map {
                .init(title: $0.title, done: $0.done, doing: $0.doing, dueAt: $0.dueAt, rrule: $0.rrule)
            },
            transactions: liveTransactions.prefix(80).map {
                .init(merchant: $0.merchant, amount: $0.amount, category: $0.category, date: $0.date)
            },
            budgets: settings.budgets,
            categories: categories
        )
    }
}

// MARK: - Wire types for the hosted API

struct ClientContext: Encodable {
    struct NoteSnippet: Encodable { var title: String; var snippet: String }
    struct RelevantNote: Encodable { var title: String; var content: String; var updatedAt: String }
    struct TodoLine: Encodable {
        var title: String; var done: Bool; var doing: Bool?
        var dueAt: String?; var rrule: String?
    }
    struct TxLine: Encodable { var merchant: String; var amount: Double; var category: String; var date: String }

    var now: String
    var timezone: String
    var currency: String
    var notes: [NoteSnippet]
    var relevantNotes: [RelevantNote]
    var todos: [TodoLine]
    var transactions: [TxLine]
    var budgets: [String: Double]
    var categories: [String]
}

struct BriefInput: Encodable {
    struct TaskLine: Encodable { var title: String; var dueAt: String?; var overdue: Bool }
    struct SpendLine: Encodable { var merchant: String; var amount: Double; var category: String }

    var now: String
    var timezone: String
    var currency: String
    var name: String?
    var tasksToday: [TaskLine]
    var yesterdaySpend: [SpendLine]
    var stickies: [String]
    /// Budgets near limit, subscriptions due, money owed.
    var alerts: [String]
}
