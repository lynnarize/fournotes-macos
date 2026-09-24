import Foundation
import Testing
@testable import FourNotes

// Ticking a repeating bill logs it and schedules the next one. Ticking it,
// unticking and ticking again did both twice: two "Pay internet bill" rows in
// Upcoming payments, and the bill counted twice in today's spending.

@Suite("Repeating tasks")
@MainActor
struct RepeatingTaskTests {
    private func store() -> (Store, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fournotes-repeat-\(UUID().uuidString).json")
        return (Store(persistence: Persistence(fileURL: url)), url)
    }

    @Test("tick, untick, tick: one bill logged, one next repeat")
    func retick() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let bill = store.addTodo {
            $0.title = "Pay internet bill"
            $0.dueAt = "2026-09-23T02:00:00.000Z"
            $0.rrule = "FREQ=MONTHLY;INTERVAL=1"
            $0.bill = Bill(amount: 350_000, currency: "IDR", category: "Bills & Utilities")
        }

        store.toggleTodo(bill.id, done: true)
        store.toggleTodo(bill.id, done: false)
        store.toggleTodo(bill.id, done: true)

        let logged = store.liveTransactions.filter { $0.merchant == "Pay internet bill" }
        let upcoming = store.liveTodos.filter { $0.title == "Pay internet bill" && !$0.done }
        #expect(logged.count == 1)
        #expect(upcoming.count == 1)
        #expect(upcoming.first?.dueAt?.hasPrefix("2026-10-23") == true)
    }

    @Test("unticking takes the bill and the next repeat back")
    func untick() {
        let (store, url) = store()
        defer { try? FileManager.default.removeItem(at: url) }
        let bill = store.addTodo {
            $0.title = "Rent"
            $0.dueAt = "2026-09-05T02:00:00.000Z"
            $0.rrule = "FREQ=MONTHLY;INTERVAL=1"
            $0.bill = Bill(amount: 2_500_000, currency: "IDR", category: "Bills & Utilities")
        }
        store.toggleTodo(bill.id, done: true)
        store.toggleTodo(bill.id, done: false)

        #expect(store.liveTransactions.filter { $0.merchant == "Rent" }.isEmpty)
        #expect(store.liveTodos.filter { $0.title == "Rent" }.count == 1)
    }
}
