import Foundation
import Testing
@testable import FourNotes

// An evaluation of Apple's on-device model as the app's assistant: typical
// requests, and whether each one lands in the right feature with the right
// details. It runs the real model, so it is slow and needs Apple Intelligence —
// off by default, on with:
//
//   TEST_RUNNER_FOURNOTES_EVAL_AFM=1 ./run-tests.sh
//
// A small model is not deterministic; a case that fails once in a while is a
// prompt worth tightening, one that fails every run is a bug.

private let enabled = ProcessInfo.processInfo.environment["FOURNOTES_EVAL_AFM"] == "1"

@Suite("On-device assistant evaluation", .serialized, .enabled(if: enabled))
struct OnDeviceEvalTests {

    struct Case: CustomTestStringConvertible, Sendable {
        let prompt: String
        /// Nil when the actions are right, otherwise what was wrong.
        let check: @Sendable ([AIAction]) -> String?
        /// For questions: the reply must mention one of these.
        var replyMentions: [String] = []
        var testDescription: String { prompt }
    }

    // MARK: - Context

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    private static func context() -> ClientContext {
        ClientContext(
            now: DateKit.nowIso(), timezone: TimeZone.current.identifier, currency: "IDR",
            notes: [.init(title: "Weekend trip ideas", snippet: "Bandung, Bali")],
            relevantNotes: [],
            todos: [
                .init(title: "Book dentist appointment", done: false, doing: nil, dueAt: nil, rrule: nil),
                .init(title: "Write quarterly report", done: false, doing: nil, dueAt: nil, rrule: nil),
            ],
            transactions: [.init(merchant: "Warteg Bahari", amount: 30000, category: "Food & Drink",
                                 date: DateKit.localDate())],
            budgets: [:],
            categories: ["Food & Drink", "Transport", "Groceries", "Shopping", "Bills & Utilities",
                         "Entertainment", "Health", "Income", "Other"])
    }

    // MARK: - Checks

    private static func todo(_ actions: [AIAction]) -> (title: String, due: Date?, rrule: String?,
                                                          bill: Bill?, priority: Priority?)? {
        for case let .createTodo(title, _, dueAt, _, priority, _, rrule, bill, _) in actions {
            return (title, DateKit.date(dueAt), rrule, bill, priority)
        }
        return nil
    }

    private static func transaction(_ actions: [AIAction]) -> (merchant: String, amount: Double,
                                                                 category: String, split: [String])? {
        for case let .addTransaction(merchant, amount, _, category, _, _, split, _) in actions {
            return (merchant, amount, category, split)
        }
        return nil
    }

    private static func describe(_ actions: [AIAction]) -> String {
        actions.isEmpty ? "no actions" : actions.map { "\($0)" }.joined(separator: "; ")
    }

    /// A to-do due on `day` days from today, at `hour` when given.
    private static func todoDue(days: Int, hour: Int? = nil, titleHas word: String) -> @Sendable ([AIAction]) -> String? {
        { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard t.title.localizedCaseInsensitiveContains(word) else { return "title \"\(t.title)\" lacks \"\(word)\"" }
            guard let due = t.due else { return "to-do has no due time" }
            let today = cal.startOfDay(for: Date())
            let want = cal.date(byAdding: .day, value: days, to: today)!
            guard cal.isDate(due, inSameDayAs: want) else { return "due \(due), wanted \(want)" }
            if let hour, cal.component(.hour, from: due) != hour {
                return "due at \(cal.component(.hour, from: due)):00, wanted \(hour):00"
            }
            return nil
        }
    }

    private static func noActions(_ actions: [AIAction]) -> String? {
        actions.isEmpty ? nil : "expected no actions, got \(describe(actions))"
    }

    static let cases: [Case] = [
        // Reminders and tasks
        Case(prompt: "remind me to book lounge room for tommorow at 10 am",
             check: todoDue(days: 1, hour: 10, titleHas: "lounge")),
        Case(prompt: "remind me to call mom tomorrow at 7pm", check: todoDue(days: 1, hour: 19, titleHas: "mom")),
        Case(prompt: "ingatkan saya bayar listrik besok jam 9 pagi", check: { actions in
            // The reply is in English, so "Pay electricity" is as right as "Bayar listrik".
            let word = todo(actions)?.title.localizedCaseInsensitiveContains("electric") == true ? "electric" : "listrik"
            if let problem = todoDue(days: 1, hour: 9, titleHas: word)(actions) { return problem }
            // No price was said, so there is no bill.
            return todo(actions)?.bill == nil ? nil : "a bill was invented: \(String(describing: todo(actions)?.bill))"
        }),
        Case(prompt: "remind me in 2 hours to take out the laundry", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard let due = t.due else { return "no due time" }
            let delta = due.timeIntervalSinceNow
            return (5400...9000).contains(delta) ? nil : "due \(Int(delta / 60)) minutes from now, wanted ~120"
        }),
        Case(prompt: "add task: prepare the slides, high priority", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            return t.priority == .high ? nil : "priority \(String(describing: t.priority)), wanted high"
        }),
        Case(prompt: "Remind me to pay rent of 2.5jt every month on the 5th at 9am", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard t.rrule?.contains("MONTHLY") == true else { return "rrule \(t.rrule ?? "nil"), wanted monthly" }
            guard t.bill?.amount == 2_500_000 else { return "bill \(String(describing: t.bill?.amount)), wanted 2500000" }
            guard let due = t.due, cal.component(.day, from: due) == 5 else { return "not due on the 5th" }
            return nil
        }),
        Case(prompt: "water the plants every Monday at 8am", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard t.rrule?.contains("WEEKLY") == true else { return "rrule \(t.rrule ?? "nil"), wanted weekly" }
            guard let due = t.due, cal.component(.weekday, from: due) == 2 else { return "not due on a Monday" }
            return nil
        }),

        Case(prompt: "Netflix 186k every month", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard t.rrule?.contains("MONTHLY") == true else { return "rrule \(t.rrule ?? "nil"), wanted monthly" }
            return t.bill?.amount == 186_000 ? nil : "bill \(String(describing: t.bill?.amount)), wanted 186000"
        }),
        Case(prompt: "submit the tax form by Friday 5pm", check: { actions in
            guard let t = todo(actions) else { return "expected a to-do, got \(describe(actions))" }
            guard let due = t.due else { return "no due time" }
            guard cal.component(.weekday, from: due) == 6 else { return "due \(due), not a Friday" }
            return cal.component(.hour, from: due) == 17 ? nil : "due at \(cal.component(.hour, from: due)):00"
        }),
        Case(prompt: "buy groceries after work", check: { actions in
            todo(actions) != nil ? nil : "expected a to-do, got \(describe(actions))"
        }),

        // Existing tasks
        Case(prompt: "I finished booking the dentist", check: { actions in
            for case let .completeTodo(match) in actions where "Book dentist appointment".localizedCaseInsensitiveContains(match) {
                return nil
            }
            return "expected complete_todo on the dentist task, got \(describe(actions))"
        }),
        Case(prompt: "working on the quarterly report now", check: { actions in
            for case let .startTodo(match) in actions where "Write quarterly report".localizedCaseInsensitiveContains(match) {
                return nil
            }
            return "expected start_todo on the report, got \(describe(actions))"
        }),

        // Money
        Case(prompt: "coffee 25k at Kopi Kenangan", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == 25_000 else { return "amount \(t.amount), wanted 25000" }
            return t.category == "Food & Drink" ? nil : "category \(t.category)"
        }),
        Case(prompt: "paid 150rb for gas", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == 150_000 else { return "amount \(t.amount), wanted 150000" }
            return t.category == "Transport" ? nil : "category \(t.category)"
        }),
        Case(prompt: "got my salary today, 10jt", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == -10_000_000 else { return "amount \(t.amount), wanted -10000000" }
            return t.category == "Income" ? nil : "category \(t.category)"
        }),
        Case(prompt: "spent 45k on lunch at Warteg, split with Andi", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == 45_000 else { return "amount \(t.amount), wanted 45000" }
            return t.split.contains { $0.localizedCaseInsensitiveContains("Andi") } ? nil : "not split with Andi"
        }),
        Case(prompt: "GoPay: Pembayaran Rp 35.000 ke Gojek berhasil", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == 35_000 else { return "amount \(t.amount), wanted 35000" }
            return t.merchant.localizedCaseInsensitiveContains("Gojek") ? nil : "merchant \(t.merchant)"
        }),
        Case(prompt: "OVO: Anda menerima Rp 500.000 dari Budi", check: { actions in
            guard let t = transaction(actions) else { return "expected a transaction, got \(describe(actions))" }
            guard t.amount == -500_000 else { return "amount \(t.amount), wanted -500000" }
            return t.category == "Income" ? nil : "category \(t.category)"
        }),
        Case(prompt: "set my food budget to 1.5M a month", check: { actions in
            for case let .setBudget(category, amount) in actions where amount == 1_500_000 && category == "Food & Drink" {
                return nil
            }
            return "expected set_budget Food & Drink 1500000, got \(describe(actions))"
        }),

        // Notes and quick notes
        Case(prompt: "note: ideas for the weekend — Bandung for coffee, Bali for the beach, Lombok to hike", check: { actions in
            actions.contains { if case .createNote = $0 { true } else { false } }
                ? nil : "expected a note, got \(describe(actions))"
        }),
        Case(prompt: "the wifi password at the office is guest123", check: { actions in
            let ok = actions.contains {
                switch $0 { case .createSticky, .createNote: true; default: false }
            }
            return ok ? nil : "expected a quick note or note, got \(describe(actions))"
        }),

        // Questions and small talk: nothing is filed
        Case(prompt: "hello", check: noActions),
        Case(prompt: "what did I spend most on this month?", check: noActions,
             replyMentions: ["Warteg", "Food"]),
        Case(prompt: "what's on my to-do list?", check: noActions, replyMentions: ["dentist", "report"]),
        Case(prompt: "what is the capital of France?", check: noActions),
        // Sent straight from the note editor's "Ask the assistant…": it used to
        // save the note again.
        Case(prompt: "About my note “Weekend trip ideas”: ", check: noActions,
             replyMentions: ["Bandung", "Bali"]),
        Case(prompt: "About my note “Weekend trip ideas”: which one is best for a rainy weekend?", check: noActions,
             replyMentions: ["Bandung", "Bali"]),
    ]

    @Test("request lands in the right feature", arguments: cases)
    func routes(_ c: Case) async throws {
        let response = try await AppleProvider().chat([ChatMessage(role: .user, content: c.prompt)],
                                                      ctx: Self.context())
        var problem = c.check(response.actions)
        if problem == nil, !c.replyMentions.isEmpty,
           !c.replyMentions.contains(where: { response.reply.localizedCaseInsensitiveContains($0) }) {
            problem = "reply mentions none of \(c.replyMentions)"
        }
        let reply = response.reply.replacingOccurrences(of: "\n", with: " ⏎ ")
        print("EVAL \(problem == nil ? "PASS" : "FAIL") | \(c.prompt) | \(problem ?? "") | reply: \(reply)")
        #expect(problem == nil, "\(c.prompt): \(problem ?? "")")
    }
}
