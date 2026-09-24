import Foundation

// Optional sample data ("Explore with sample data").
// Every item is tagged `sample: true`, so it can be removed in one click and is
// never uploaded to cloud sync. A fresh install has none of this.

enum Samples {
    static let budgets: [String: Double] = ["Food & Drink": 1_500_000, "Transport": 600_000]

    struct Bundle {
        var notes: [Note]
        var todos: [Todo]
        var transactions: [Transaction]
        var stickies: [Sticky]
    }

    static func build(currency: String, now: Date = Date()) -> Bundle {
        let cal = Calendar.current
        func shift(_ days: Int, hour: Int? = nil) -> Date {
            var d = cal.date(byAdding: .day, value: days, to: now) ?? now
            if let hour { d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: d) ?? d }
            return d
        }
        func iso(_ days: Int, _ hour: Int? = nil) -> String { DateKit.iso(shift(days, hour: hour)) }
        func ymd(_ days: Int) -> String { DateKit.localDate(shift(days)) }

        let noteId = DateKit.uid()
        var note = Note(id: noteId, createdAt: iso(-6), updatedAt: iso(-6), sample: true,
                        title: "Weekend trip ideas", source: .manual, tags: ["sample"])
        note.content = """
        Places to consider
        • Bandung — short drive, good coffee
        • Bali — flights are cheaper midweek

        Budget roughly 2jt for two nights.

        Tip: type / on a line for commands like /todo.
        """

        var payBill = Todo(id: DateKit.uid(), createdAt: iso(-4), updatedAt: iso(-4), sample: true,
                           title: "Pay internet bill", source: .manual)
        payBill.dueAt = iso(3, 9)
        payBill.remindAt = iso(3, 8)
        payBill.rrule = "FREQ=MONTHLY;INTERVAL=1"
        payBill.bill = Bill(amount: 350_000, currency: nil, category: "Bills & Utilities")

        var groceries = Todo(id: DateKit.uid(), createdAt: iso(-2), updatedAt: iso(-2), sample: true,
                             title: "Buy groceries", source: .manual)
        groceries.dueAt = iso(0, 18)
        groceries.noteId = noteId

        var dentist = Todo(id: DateKit.uid(), createdAt: iso(-9), updatedAt: iso(-9), sample: true,
                           title: "Book dentist appointment", done: true, priority: .low, source: .manual)
        dentist.completedAt = iso(-1, 9)
        dentist.dueAt = iso(-1, 10)

        func tx(_ days: Int, _ merchant: String, _ amount: Double, _ category: String,
                items: [LineItem] = [], splits: [Split]? = nil) -> Transaction {
            var t = Transaction(id: DateKit.uid(), createdAt: iso(days), updatedAt: iso(days), sample: true,
                                merchant: merchant, amount: amount, currency: currency,
                                category: category, date: ymd(days), items: items, source: .manual)
            t.splits = splits
            return t
        }

        let transactions = [
            tx(0, "Kopi Kenangan", 28_000, "Food & Drink",
               items: [LineItem(name: "Kopi Susu", qty: 1, price: 28_000)]),
            tx(0, "Gojek", 35_000, "Transport"),
            tx(-2, "Indomaret", 87_500, "Groceries"),
            tx(-5, "Warteg Bahari", 90_000, "Food & Drink", splits: [
                Split(name: "Andi", amount: 30_000, settled: false),
                Split(name: "Budi", amount: 30_000, settled: true),
            ]),
            // Two months of the same charge, so the subscription detector has something to find.
            tx(-8, "Netflix", 186_000, "Entertainment"),
            tx(-38, "Netflix", 186_000, "Entertainment"),
        ]

        // A quick note (these replaced stickies).
        var quick = Note(id: DateKit.uid(), createdAt: iso(-3), updatedAt: iso(-3), sample: true, source: .manual)
        QuickNote.apply("Andi still owes 30k for Warteg", to: &quick)

        return Bundle(notes: [note, quick], todos: [payBill, groceries, dentist],
                      transactions: transactions, stickies: [])
    }
}
