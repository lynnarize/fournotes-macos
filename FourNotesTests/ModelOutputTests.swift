import Foundation
import Testing
@testable import FourNotes

// Everything a model sends is untrusted input. These are the shapes it actually
// produces when it gets something slightly wrong — and what must not happen.

@Suite("Model output")
struct ModelOutputTests {

    private func context(categories: [String] = ["Food & Drink", "Transport", "Other"]) -> ClientContext {
        ClientContext(now: DateKit.nowIso(), timezone: "Asia/Jakarta", currency: "IDR",
                      notes: [], relevantNotes: [], todos: [], transactions: [],
                      budgets: [:], categories: categories)
    }

    // MARK: - Decoding a batch

    @Test("one unreadable action does not drop the others")
    func onePoisonAction() {
        let raw: [[String: Any]] = [
            ["type": "create_todo", "title": "Keep me"],
            ["type": "create_todo", "title": "Bad priority", "priority": "urgent"],
            ["type": "create_todo", "title": "Keep me too"],
        ]
        let actions = AITools.decodeActions(raw)
        #expect(actions.count >= 2, "a batch should survive one bad action, got \(actions.count)")
    }

    @Test("an unknown enum value is ignored, not fatal")
    func unknownEnum() {
        // `decodeIfPresent` throws for a present-but-invalid value, which used
        // to discard the whole action rather than just the field.
        let actions = AITools.decodeActions([["type": "create_todo", "title": "Call the bank",
                                              "priority": "urgent"]])
        #expect(actions.count == 1, "the task itself should still be created")
    }

    @Test("a non-finite amount never reaches the store")
    func nonFiniteAmount() {
        // JSONSerialization raises an Objective-C exception on NaN that `try?`
        // cannot catch, and a NaN that got through disabled saving permanently.
        for bad in [Double.nan, .infinity, -.infinity, 1e300] {
            let actions = AITools.decodeActions([[
                "type": "add_transaction", "merchant": "Broken", "amount": bad,
                "category": "Other", "date": "2026-09-01",
            ]])
            for case let .addTransaction(_, amount, _, _, _, _, _, _) in actions {
                #expect(Money.isValidAmount(amount), "\(bad) reached the store as \(amount)")
            }
        }
    }

    @Test("an empty batch is empty, not a crash")
    func emptyBatch() {
        #expect(AITools.decodeActions([]).isEmpty)
    }

    // MARK: - Capture

    @Test("an impossible date is replaced with today")
    func impossibleDate() {
        // "2026-13-45" passes a regex shape check, then the transaction is
        // invisible in every month view and crashes the month picker.
        let result = CaptureMapper.toActions([
            "kind": "receipt", "reply": "Filed it.",
            "receipt": ["merchant": "Warung", "total": 25_000, "date": "2026-13-45",
                        "category": "Food & Drink"],
        ], ctx: context())

        for case let .addTransaction(_, _, _, _, date, _, _, _) in result.actions {
            #expect(DateKit.date(date) != nil, "stored an unreadable date: \(date)")
        }
        #expect(!result.actions.isEmpty)
    }

    @Test("a category the user does not have becomes Other")
    func unknownCategory() {
        let result = CaptureMapper.toActions([
            "kind": "receipt", "reply": "Filed it.",
            "receipt": ["merchant": "Warung", "total": 25_000, "date": "2026-09-01",
                        "category": "Hallucinated"],
        ], ctx: context())

        for case let .addTransaction(_, _, _, category, _, _, _, _) in result.actions {
            #expect(context().categories.contains(category), "kept an unknown category: \(category)")
        }
    }

    @Test("line items the model mangled do not lose the transaction")
    func mangledLineItems() {
        // A price as a formatted string, or a missing name, used to fail the
        // whole add_transaction decode — so the receipt vanished while the
        // reply still said it had been filed.
        let result = CaptureMapper.toActions([
            "kind": "receipt", "reply": "Filed it.",
            "receipt": [
                "merchant": "Warung", "total": 128_500, "date": "2026-09-01",
                "category": "Food & Drink",
                "items": [["name": "Nasi Goreng", "price": "70.000"], ["price": 16_000]],
            ],
        ], ctx: context())
        #expect(!result.actions.isEmpty, "the transaction was lost with its line items")
    }

    @Test("a bogus currency does not become the transaction's currency")
    func bogusCurrency() {
        let result = CaptureMapper.toActions([
            "kind": "receipt", "reply": "Filed it.",
            "receipt": ["merchant": "Warung", "total": 25_000, "date": "2026-09-01",
                        "currency": "US Dollar", "category": "Food & Drink"],
        ], ctx: context())

        for case let .addTransaction(_, _, currency, _, _, _, _, _) in result.actions {
            #expect(currency == nil || FXRates.isCurrencyCode(currency!),
                    "stored \(currency ?? "nil") as a currency code")
        }
    }

    @Test("a recurring task from a capture gets a usable rule")
    func captureRecurrence() {
        let result = CaptureMapper.toActions([
            "kind": "todo_list", "reply": "Filed it.",
            "todos": [["title": "Pay rent", "rrule": "MONTHLY",
                       "dueAt": DateKit.iso(Date().addingTimeInterval(86_400))]],
        ], ctx: context())

        for case let .createTodo(_, _, _, _, _, _, rrule, _, _) in result.actions {
            #expect(Recurrence.parse(rrule) != nil, "unparseable rule survived: \(rrule ?? "nil")")
        }
    }
}

@Suite("Store actions")
@MainActor
struct StoreActionTests {
    @Test("model data is normalised before it reaches persisted rows")
    func normalisesUntrustedActions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fournotes-actions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = Store(persistence: Persistence(fileURL: url))
        store.addTransaction {
            $0.merchant = "Existing"
            $0.amount = 90_000
            $0.splits = [Split(name: "Andi", amount: 30_000, settled: false)]
        }

        store.applyActions([
            .createTodo(title: "Rent", notes: nil, dueAt: "2026-13-45", remindAt: nil,
                        priority: nil, status: nil, rrule: "MONTHLY",
                        bill: Bill(amount: .infinity, currency: "USD",
                                   category: "Bills & Utilities"), noteRef: nil),
            .addTransaction(merchant: "Warung", amount: 10, currency: "US Dollar",
                            category: "Food & Drink", date: "2026-13-45", items: [],
                            splitWith: ["   "], noteRef: nil),
            .completeTodo(titleContains: "   "),
            .splitTransaction(merchantContains: "Existing", people: [], includeMe: true),
            .setBudget(category: "Food & Drink", amount: .infinity),
        ])

        let todo = try #require(store.liveTodos.first)
        let transaction = try #require(store.liveTransactions.first)
        let existing = try #require(store.liveTransactions.first { $0.merchant == "Existing" })
        #expect(todo.dueAt == nil)
        #expect(todo.remindAt == nil)
        #expect(todo.rrule == "FREQ=MONTHLY;INTERVAL=1")
        #expect(todo.bill == nil)
        #expect(!todo.done, "an empty match completed an arbitrary task")
        #expect(DateKit.date(transaction.date) != nil)
        #expect(transaction.currency == "IDR")
        #expect(transaction.splits == nil)
        #expect(existing.splits?.count == 1, "an empty split cleared an existing bill split")
        #expect(store.settings.budgets["Food & Drink"] == nil)
    }
}
