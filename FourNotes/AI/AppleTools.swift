import Foundation
import FoundationModels

// The app's actions as Foundation Models tools, so Apple's on-device model can
// file things the same way Claude does. These mirror src/lib/ai/tools.ts, with
// one deliberate difference: the model is never asked to do arithmetic.
//
// Measured against real requests (FourNotesTests/OnDeviceEvalTests), the small
// model picks the right tool well and converts badly. It turned "150rb" into
// 150, "2.5jt" into 25,000,000, "every Monday" into a monthly rule, dropped
// "tommorow at 10 am" altogether, and filed a question as a new expense. So it
// copies the user's words — "tomorrow at 10am", "150rb" — and the app resolves
// them with code that has tests, checking against what the user actually typed.

/// Collects what the model asked for during one turn.
actor ActionRecorder {
    private(set) var actions: [AIAction] = []
    func record(_ action: AIAction) { actions.append(action) }
}

/// What the tools need to know about the turn they run in.
struct TurnContext: Sendable {
    /// The user's newest message, verbatim.
    let message: String
    let now: Date
    /// Recent spending, to avoid filing an expense that is already recorded.
    let transactions: [ClientContext.TxLine]
    /// The user's spending categories.
    var categories: [String] = []

    /// A question gets an answer, never a new row: asked "what did I spend
    /// most on?", the model re-filed the top expense.
    var isQuestion: Bool { Intent.isQuestion(message) }
}

/// The reply a tool gives when it refuses. The model reads it, so it says what
/// to do instead.
private let questionRefusal = "Nothing saved: the user asked a question. Answer it from the user's data instead."

// MARK: - Reading the user's intent

enum Intent {
    private static let saveWords =
        "remind|reminder|add|save|log|set|create|record|track|split|schedule|put|make|"
        + "spent|paid|bought|got|received|ingatkan|catat|tambah|simpan|buat|bayar|beli"

    static func isQuestion(_ message: String) -> Bool {
        // "About my note “X”: …" asks about a note that exists. Sent as it
        // stands, the model filed a second copy of the note.
        if let about = noteQuestion(message) {
            return about.ask.lowercased().range(of: "\\b(\(saveWords))\\b", options: .regularExpression) == nil
        }
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return false }
        // "Can you remind me…?" is a request, whatever its punctuation.
        if t.range(of: "\\b(\(saveWords))\\b", options: .regularExpression) != nil { return false }
        if t.hasSuffix("?") { return true }
        return t.range(of: "^(what|what's|whats|how|which|when|where|who|why|show|list|tell me|do i|did i|am i|"
                       + "apa|berapa|kapan|dimana|di mana|siapa|kenapa|mengapa|gimana|bagaimana)\\b",
                       options: .regularExpression) != nil
    }

    /// What the note editor's "Ask the assistant…" puts in the box:
    /// `About my note “Title”: <question>`. The question may be empty.
    static func noteQuestion(_ message: String) -> (title: String, ask: String)? {
        guard let m = message.firstMatch(of: /^\s*About my note [“"](.+?)[”"]\s*:?\s*([\s\S]*)$/) else { return nil }
        return (String(m.1), String(m.2).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The note question as the model should read it. Sent with nothing
    /// after the colon, the small model announced "I've saved your note" and
    /// saved nothing; asked plainly, it answers.
    static func expandingNoteQuestion(_ message: String) -> String {
        guard let about = noteQuestion(message), about.ask.isEmpty else { return message }
        return "About my note “\(about.title)”: give me a short summary of it and one or two useful suggestions."
    }

    /// Asking for what the world knows rather than what the user saved:
    /// recommendations, ideas, "what's the best…". A small local model answers
    /// these from memory, so the cloud is offered.
    static func wantsWorldKnowledge(_ message: String) -> Bool {
        message.range(of: "\\b(recommend\\w*|suggest\\w*|ideas?|best|tips?|advice|where (should|can|to)|"
                      + "what should i|which (one|is better)|worth (it|buying|visiting)|"
                      + "rekomendasi|saran|ide|terbaik|sebaiknya|bagusnya)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "yea save that", "save it as a note", "simpan itu": the reply just
    /// shown, kept as it is. Short on purpose — "save a note: …" with its own
    /// content is an ordinary request.
    static func savesPreviousReply(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.contains(":"), t.split(separator: " ").count <= 10,
              t.range(of: "\\b(save|keep|store|note down|simpan|catat)\\b", options: .regularExpression) != nil
        else { return false }
        return t.range(of: "\\b(that|this|it|them|those|itu|ini|as a note|to (my )?notes|in (my )?notes|"
                       + "jadi catatan|ke catatan|the (itinerary|list|plan|recommendations?|ideas?|answer|reply|table|tips))\\b",
                       options: .regularExpression) != nil
    }

    /// "yes", "sure, go ahead", "iya": agreeing to what the last reply offered.
    static func agrees(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.split(separator: " ").count <= 5 else { return false }
        return t.range(of: "^\\W*(yes|yeah|yea|yep|yup|sure|ok|okay|please|please do|go ahead|do it|sounds good|"
                       + "iya|ya|boleh|oke|mau|silakan)\\b", options: .regularExpression) != nil
    }

    /// Asked to save, add, log or remind — in so many words.
    static func asksToSave(_ message: String) -> Bool {
        message.lowercased().range(of: "\\b(\(saveWords))\\b", options: .regularExpression) != nil
    }

    /// A message to answer, not to file: a question, or a request for
    /// recommendations, with no word asking to save anything. Such a turn is
    /// given no tools at all — a cloud model asked for a Bandung itinerary
    /// declined, then filed an empty "Bandung itinerary" note and a quick note.
    static func answerOnly(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // "note: …", "task: …" are requests however they are worded.
        if t.range(of: "^(quick note|note|notes|task|to-?do|reminder|catatan|tugas)\\s*:",
                   options: [.regularExpression, .caseInsensitive]) != nil { return false }
        guard !asksToSave(t) else { return false }
        return isQuestion(t) || wantsWorldKnowledge(t)
    }

    /// Greetings, thanks and small talk: nothing to look up.
    static func isSmallTalk(_ message: String) -> Bool {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.split(separator: " ").count <= 6 && t.range(
            of: "^\\W*(hi|hello|hey|halo|hai|yo|thanks|thank you|thx|terima kasih|makasih|ok|okay|oke|cool|nice|"
                + "good (morning|afternoon|evening|night)|selamat (pagi|siang|sore|malam)|how are you|apa kabar|bye)\\b",
            options: .regularExpression) != nil
    }

    /// Worth offering a cloud model for: the question needs what the world
    /// knows, not what the user saved. Never small talk, never a request to
    /// file something.
    static func needsCloud(_ message: String, localReply: String, aboutNote: Bool) -> Bool {
        guard !isSmallTalk(message) else { return false }
        if aboutNote || wantsWorldKnowledge(message) { return true }
        // A real question the local model said it couldn't answer.
        return isQuestion(message) && looksOutOfScope(localReply)
    }

    /// A local reply that says the question was beyond it.
    static func looksOutOfScope(_ reply: String) -> Bool {
        reply.range(of: "I (can |only )?help with notes|can't (give|help with|provide)|cannot (give|help with|provide)|"
                    + "(not|n't) able to (give|provide|help)|don't have (access|information|details)",
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Asked to be reminded, in so many words.
    static func wantsReminder(_ message: String) -> Bool {
        message.range(of: "\\b(remind|reminder|don't forget|dont forget|ingatkan|ingetin|jangan lupa)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Money coming in rather than going out.
    static func isIncome(_ message: String) -> Bool {
        message.range(of: "\\b(salary|gaji|got paid|received|receive|refund|income|bonus|"
                      + "transfer masuk|dana masuk|diterima|terima|menerima|dapat uang)\\b",
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// How often something repeats, when the message says so plainly.
    static func repeats(_ message: String) -> Freq? {
        let m = message.lowercased()
        func has(_ pattern: String) -> Bool { m.range(of: pattern, options: .regularExpression) != nil }
        if has("\\b(every ?day|daily|each day|setiap hari|tiap hari)\\b") { return .DAILY }
        if has("\\b(every ?week|weekly|each week|setiap minggu|tiap minggu|every (monday|tuesday|wednesday|thursday|friday|saturday|sunday)|setiap (senin|selasa|rabu|kamis|jumat|sabtu))\\b") { return .WEEKLY }
        if has("\\b(every ?month|monthly|each month|setiap bulan|tiap bulan|per month|a month)\\b") { return .MONTHLY }
        if has("\\b(every ?year|yearly|annually|each year|setiap tahun|tiap tahun)\\b") { return .YEARLY }
        return nil
    }

    /// The one amount a message mentions, read the way a person wrote it.
    /// Nil when there is none, or several and it's unclear which is meant.
    static func amount(in message: String) -> Double? {
        let distinct = Set(amounts(in: message))
        return distinct.count == 1 ? distinct.first : nil
    }

    /// The amount to use: the message's own, or the model's reading when the
    /// message holds that very amount among others. Never a number the user
    /// didn't write — the model invented a Rp 150,000 bill for a reminder that
    /// named no price, lifted from an example in its instructions.
    static func amount(in message: String, modelSaid raw: String?) -> Double? {
        if let single = amount(in: message) { return single }
        guard let raw, let model = Money.parse(raw).map(abs) else { return nil }
        return amounts(in: message).contains(model) ? model : nil
    }

    /// Every amount the message states, as positive values.
    static func amounts(in message: String) -> [Double] {
        let pattern = "(?i)(?:rp\\.?\\s*|idr\\s*)-?\\d[\\d.,]*(?:\\s*(?:k|rb|ribu|jt|juta|m)\\b)?"
            + "|-?\\d[\\d.,]*\\s*(?:k|rb|ribu|jt|juta|m)\\b"
            + "|\\b\\d{1,3}(?:[.,]\\d{3})+\\b|\\b\\d{5,}\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(message.startIndex..., in: message)
        return re.matches(in: message, range: range).compactMap { m -> Double? in
            guard let r = Range(m.range, in: message) else { return nil }
            return Money.parse(String(message[r])).map(abs)
        }
    }

    /// Amounts a model filed, checked against what the user typed — for every
    /// provider, not only Apple's. Small models read "25k" as 25 and "2.5jt"
    /// as 25,000,000; when the message states one amount and the model's isn't
    /// among those it states, the message wins. Nothing changes when the
    /// message names no amount, or the model picked one it does name.
    static func ground(_ actions: [AIAction], in message: String) -> [AIAction] {
        let stated = amounts(in: message)
        guard !stated.isEmpty, let single = amount(in: message) else { return actions }
        func fix(_ value: Double) -> Double {
            stated.contains(abs(value)) ? value : (value < 0 ? -single : single)
        }
        return actions.map { action in
            switch action {
            case let .addTransaction(merchant, amount, currency, category, date, items, splitWith, noteRef):
                return .addTransaction(merchant: merchant, amount: fix(amount), currency: currency,
                                       category: category, date: date, items: items,
                                       splitWith: splitWith, noteRef: noteRef)
            case let .createTodo(title, notes, dueAt, remindAt, priority, status, rrule, bill, noteRef):
                var bill = bill
                if let amount = bill?.amount { bill?.amount = fix(amount) }
                return .createTodo(title: title, notes: notes, dueAt: dueAt, remindAt: remindAt,
                                   priority: priority, status: status, rrule: rrule, bill: bill, noteRef: noteRef)
            case let .setBudget(category, amount):
                return .setBudget(category: category, amount: fix(amount))
            default:
                return action
            }
        }
    }

    /// "gas" -> "Gas": the model copies a merchant as it was typed.
    static func merchantName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, t == t.lowercased() else { return t }
        return first.uppercased() + t.dropFirst()
    }

    /// A task title without the "remind me to" and the time it was said with.
    static func cleanTitle(_ raw: String, now: Date) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(
            of: "^(quick note|note|reminder|task|to-?do)\\s*:\\s*", with: "",
            options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: "^(please\\s+)?(remind me (to|about)|remember to|don't forget to|dont forget to|"
                + "ingatkan (saya|aku)( untuk)?|ingetin (gue|aku|saya)?( untuk)?|jangan lupa)\\s+",
            with: "", options: [.regularExpression, .caseInsensitive])
        t = NaturalDate.removingTime(from: t, now: now)
        guard let first = t.first else { return raw }
        return first.uppercased() + t.dropFirst()
    }
}

// MARK: - Notes

@Generable
struct CreateNoteArgs {
    @Guide(description: "Short title, at most 8 words")
    var title: String
    @Guide(description: "The note body. Keep every detail the user gave. Bullets start with •")
    var content: String
}

struct CreateNoteTool: Tool {
    let name = "create_note"
    let description = "Save a note in the Notes tab: ideas, lists, meeting notes, summaries — anything longer than a line."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: CreateNoteArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        await recorder.record(.createNote(title: arguments.title, content: arguments.content,
                                          tags: [], ref: "apple"))
        return "saved"
    }
}

@Generable
struct QuickNoteArgs {
    @Guide(description: "The whole fact in the user's words: what it is as well as its value, so it makes sense on its own later. At most about 15 words.")
    var text: String
}

struct QuickNoteTool: Tool {
    let name = "create_sticky"
    let description = "Keep a short fact on the Today page — a password, a code, a name, a number. Only when there is no time and nothing to do."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: QuickNoteArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        // "Remind me in 2 hours…" filed as a quick note never reminds anyone.
        // Anything with a time, or asked for as a reminder, is a to-do.
        let due = NaturalDate.resolve(turn.message, now: turn.now)
        if due != nil || Intent.wantsReminder(turn.message) {
            let iso = due.map(DateKit.iso)
            await recorder.record(.createTodo(
                title: Intent.cleanTitle(arguments.text, now: turn.now), notes: nil,
                dueAt: iso, remindAt: iso, priority: nil, status: nil,
                rrule: nil, bill: nil, noteRef: nil))
            return "saved as a to-do with a reminder"
        }
        await recorder.record(.createSticky(text: arguments.text, color: nil))
        return "saved"
    }
}

// MARK: - Tasks

@Generable
struct CreateTodoArgs {
    @Guide(description: "What needs doing, in a few words. Leave out the date, the time and 'remind me to'.")
    var title: String
    @Guide(description: "When it is due, copied word for word from the user's message. Empty when the user named no day or time.")
    var when: String?
    @Guide(description: "How often it repeats. never unless the user said every day, week, month or year.")
    @Guide(.anyOf(["never", "daily", "weekly", "monthly", "yearly"]))
    var repeats: String?
    @Guide(.anyOf(["low", "medium", "high"]))
    var priority: String?
    @Guide(description: "doing when the user is working on it right now, otherwise todo")
    @Guide(.anyOf(["todo", "doing"]))
    var status: String?
    @Guide(description: "For a bill: its price copied exactly as written in the user's message, including k, rb, jt or Rp. Empty unless the user wrote a price.")
    var billAmount: String?
    @Guide(description: "The spending category the bill belongs to, when billAmount is set")
    var billCategory: String?
}

struct CreateTodoTool: Tool {
    let name = "create_todo"
    let description = "Add a task or reminder to the To-Do tab — anything the user wants to do or be reminded of, with or without a time. Repeating bills (rent, internet, subscriptions) too."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: CreateTodoArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }

        // The model's copy of the time first; failing that, whatever time the
        // user's own message mentions.
        let said = arguments.when.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let resolved = said.flatMap { NaturalDate.resolve($0, now: turn.now) }
            ?? NaturalDate.resolve(turn.message, now: turn.now)

        // A repeat the user spelled out beats the model's reading of it.
        let freq = Intent.repeats(turn.message)
            ?? arguments.repeats.flatMap { Freq(rawValue: $0.uppercased()) }
        let rrule = freq.flatMap { Recurrence.normalised(Recurrence.make($0, 1), anchoredTo: resolved) }
        let due = Self.dueDate(resolved.map(DateKit.iso), rrule: rrule)

        let bill = billAmount(arguments).map {
            Bill(amount: $0, currency: nil, category: arguments.billCategory ?? "Bills & Utilities")
        }
        await recorder.record(.createTodo(
            title: Intent.cleanTitle(arguments.title, now: turn.now),
            notes: nil,
            dueAt: due,
            remindAt: due,
            priority: arguments.priority.flatMap { Priority(rawValue: $0) },
            status: arguments.status,
            rrule: rrule,
            bill: bill,
            noteRef: nil))
        return due == nil ? "saved" : "saved, due \(Fmt.due(due))"
    }

    /// The bill as the user wrote it. The model's copy is only trusted when
    /// the message itself doesn't say one clear amount.
    private func billAmount(_ arguments: CreateTodoArgs) -> Double? {
        guard arguments.billAmount?.trimmingCharacters(in: .whitespaces).isEmpty == false else { return nil }
        return Intent.amount(in: turn.message, modelSaid: arguments.billAmount)
            .flatMap { $0 > 0 && Money.isValidAmount($0) ? $0 : nil }
    }

    /// "Every month on the 5th" is usually resolved to the 5th of the current
    /// month, which may already be behind us. A repeating task is rolled forward
    /// to its next real occurrence rather than being scheduled in the past.
    static func dueDate(_ raw: String?, rrule: String?) -> String? {
        guard let raw, !raw.isEmpty, DateKit.date(raw) != nil else { return nil }
        guard let rrule else { return raw }
        return Recurrence.next(after: raw, rrule)
    }
}

@Generable
struct MatchTitleArgs {
    @Guide(description: "A distinctive word or two from the existing task's title, copied from the user's data")
    var titleContains: String
}

struct CompleteTodoTool: Tool {
    let name = "complete_todo"
    let description = "Mark one of the user's open tasks as done, when they say they finished it."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: MatchTitleArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        await recorder.record(.completeTodo(titleContains: arguments.titleContains))
        return "saved"
    }
}

struct StartTodoTool: Tool {
    let name = "start_todo"
    let description = "Move one of the user's open tasks to Doing, when they say they are working on it now."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: MatchTitleArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        await recorder.record(.startTodo(titleContains: arguments.titleContains))
        return "saved"
    }
}

// MARK: - Money

@Generable
struct AddTransactionArgs {
    @Guide(description: "Who was paid, or who paid the user")
    var merchant: String
    @Guide(description: "The amount copied exactly as written in the user's message, including k, rb, jt or Rp")
    var amount: String
    @Guide(description: "spent for money paid out, received for salary, refunds and other money coming in")
    @Guide(.anyOf(["spent", "received"]))
    var direction: String
    @Guide(description: "One of the spending categories listed in the instructions. Other when none fit.")
    var category: String
    @Guide(description: "The day it happened, copied from the user's message. Empty when no day was said.")
    var when: String?
    @Guide(description: "Names of other people splitting this bill with the user. Empty when not split.")
    var splitWith: [String]?
}

struct AddTransactionTool: Tool {
    let name = "add_transaction"
    let description = "Record money spent or received in the Finance tab, including pasted e-wallet and bank notifications."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: AddTransactionArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }

        // A pasted e-wallet or bank notification has a known shape; the
        // app's own parser reads it better than the model, which filed
        // "Pembayaran Rp 35.000 ke Gojek" under the merchant "GoPay".
        if let parsed = Wallet.parseNotification(turn.message), parsed.wallet != nil {
            let incoming = parsed.amount < 0 || Intent.isIncome(turn.message)
            await recorder.record(.addTransaction(
                merchant: parsed.merchant, amount: incoming ? -abs(parsed.amount) : parsed.amount,
                currency: nil, category: incoming ? "Income" : parsed.category,
                date: DateKit.localDate(turn.now), items: [],
                splitWith: arguments.splitWith ?? [], noteRef: nil))
            return "saved"
        }

        // The number as the user wrote it, read by the app's own parser.
        guard let value = Intent.amount(in: turn.message, modelSaid: arguments.amount),
              value > 0, Money.isValidAmount(value) else {
            return "Nothing saved: no amount was given. Ask the user how much it was."
        }
        let received = arguments.direction == "received" || Intent.isIncome(turn.message)
        let date = arguments.when
            .flatMap { $0.isEmpty ? nil : NaturalDate.resolve($0, now: turn.now) }
            .map { DateKit.localDate($0) } ?? DateKit.localDate(turn.now)

        // Already there — the same merchant, amount and day — and the user
        // didn't type an amount, so this is the model repeating a row back.
        if Intent.amount(in: turn.message) == nil, turn.transactions.contains(where: {
            abs($0.amount) == value && $0.date == date
                && ($0.merchant.localizedCaseInsensitiveContains(arguments.merchant)
                    || arguments.merchant.localizedCaseInsensitiveContains($0.merchant))
        }) {
            return "Nothing saved: that expense is already recorded."
        }

        await recorder.record(.addTransaction(
            merchant: Intent.merchantName(arguments.merchant),
            amount: received ? -value : value,
            currency: nil,
            category: received ? "Income" : category(arguments),
            date: date,
            items: [],
            splitWith: arguments.splitWith ?? [],
            noteRef: nil))
        return "saved"
    }
}

extension AddTransactionTool {
    /// The model's category, or — when it shrugged with "Other" or named one
    /// that doesn't exist — the app's own guess from the merchant and message.
    fileprivate func category(_ arguments: AddTransactionArgs) -> String {
        let named = arguments.category.trimmingCharacters(in: .whitespaces)
        if !named.isEmpty, named.caseInsensitiveCompare("Other") != .orderedSame,
           turn.categories.contains(where: { $0.caseInsensitiveCompare(named) == .orderedSame }) {
            return named
        }
        return Wallet.guessCategory("\(arguments.merchant) \(turn.message)")
    }
}

@Generable
struct SplitArgs {
    @Guide(description: "A distinctive part of the existing expense's merchant name, from the user's data")
    var merchantContains: String
    @Guide(description: "The other people sharing the bill")
    var people: [String]
    @Guide(description: "Whether the user also pays a share. Usually true.")
    var includeMe: Bool?
}

struct SplitTransactionTool: Tool {
    let name = "split_transaction"
    let description = "Split an expense that is already recorded, equally with other people."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: SplitArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        // "Spent 45k at Warteg, split with Andi" names a price, so it is a new
        // expense to share — not the Warteg meal already on the list, which is
        // where the model sent it.
        if let value = Intent.amount(in: turn.message), value > 0, Money.isValidAmount(value) {
            let merchant = Intent.merchantName(arguments.merchantContains)
            await recorder.record(.addTransaction(
                merchant: merchant, amount: value, currency: nil,
                category: Wallet.guessCategory("\(merchant) \(turn.message)"),
                date: DateKit.localDate(turn.now), items: [],
                splitWith: arguments.people, noteRef: nil))
            return "saved as a new expense, split"
        }
        await recorder.record(.splitTransaction(merchantContains: arguments.merchantContains,
                                                people: arguments.people,
                                                includeMe: arguments.includeMe))
        return "saved"
    }
}

@Generable
struct BudgetArgs {
    @Guide(description: "One of the spending categories listed in the instructions, never Income")
    var category: String
    @Guide(description: "The monthly limit copied exactly as written in the user's message, including k, rb, jt or M")
    var amount: String
}

struct SetBudgetTool: Tool {
    let name = "set_budget"
    let description = "Set a monthly spending budget for one category."
    let recorder: ActionRecorder
    let turn: TurnContext

    func call(arguments: BudgetArgs) async throws -> String {
        guard !turn.isQuestion else { return questionRefusal }
        guard let value = Intent.amount(in: turn.message, modelSaid: arguments.amount),
              value > 0, Money.isValidAmount(value) else {
            return "Nothing saved: no amount was given. Ask the user for the monthly limit."
        }
        await recorder.record(.setBudget(category: arguments.category, amount: value))
        return "saved"
    }
}

// MARK: - Structured capture

/// One tidied note from captured text.
///
/// Deliberately tiny: a wide schema with many optional fields costs this model
/// minutes rather than seconds, so receipts are read by `OnDevice.readReceipt`
/// (which is both faster and more accurate) and the model only handles prose.
@Generable
struct CapturedNote {
    @Guide(description: "A short title for this text, at most 8 words")
    var title: String
    @Guide(description: "The text tidied up: keep the wording and every fact, fix the formatting")
    var content: String
    @Guide(description: "Any tasks or action items mentioned. Empty when there are none.")
    var todos: [String]
}
