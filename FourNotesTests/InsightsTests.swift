import Foundation
import Testing
@testable import FourNotes

// Budgets, splits and subscription detection — the arithmetic the Finance tab
// is built on.

@Suite("Insights")
struct InsightsTests {

    private func tx(_ merchant: String, _ amount: Double, _ category: String = "Food & Drink",
                    date: String = "2026-09-01", currency: String = "IDR",
                    fxRate: Double? = nil, splits: [Split]? = nil) -> Transaction {
        var t = Transaction(id: UUID().uuidString, createdAt: "2026-09-01T00:00:00.000Z",
                            updatedAt: "2026-09-01T00:00:00.000Z", merchant: merchant,
                            amount: amount, currency: currency, fxRate: fxRate,
                            category: category, date: date)
        t.splits = splits
        return t
    }

    @Test("spending counts only the user's share of a split bill")
    func myShare() {
        let bill = tx("Warteg", 90_000, splits: [
            Split(name: "Andi", amount: 30_000, settled: false),
            Split(name: "Budi", amount: 30_000, settled: true),
        ])
        #expect(Insights.myShare(bill, "IDR") == 30_000)
    }

    @Test("income is negative and does not count as spending")
    func income() {
        let byCategory = Insights.spendByCategory([tx("Salary", -5_000_000, "Income")], "IDR")
        #expect(byCategory["Income"] == nil, "income was counted as spending")
    }

    @Test("budget status reports what is spent against each limit")
    func budgets() {
        var settings = AppSettings()
        settings.budgets = ["Food & Drink": 1_000_000]
        let status = Insights.budgetStatus([tx("Warung", 250_000)], settings)
        #expect(status.first?.spent == 250_000)
        #expect(status.first?.ratio == 0.25)
    }

    @Test("an equal split divides the whole bill")
    func equalSplit() {
        let splits = Insights.equalSplit(90_000, ["Andi", "Budi"], includeMe: true)
        #expect(splits.count == 2)
        #expect(splits.allSatisfy { $0.amount == 30_000 })
    }

    @Test("what others owe excludes anyone who has settled")
    func owed() {
        let bill = tx("Warteg", 90_000, splits: [
            Split(name: "Andi", amount: 30_000, settled: false),
            Split(name: "Budi", amount: 30_000, settled: true),
        ])
        let owed = Insights.owedToMe([bill], "IDR")
        #expect(owed.count == 1)
        #expect(owed.first?.name == "Andi")
    }

    @Test("a repeated monthly charge is recognised")
    func subscriptions() {
        let now = Date()
        let cal = Calendar.current
        let recent = DateKit.localDate(cal.date(byAdding: .day, value: -3, to: now)!)
        let previous = DateKit.localDate(cal.date(byAdding: .day, value: -33, to: now)!)
        let found = Insights.detectSubscriptions([
            tx("Netflix", 186_000, "Entertainment", date: previous),
            tx("Netflix", 186_000, "Entertainment", date: recent),
        ])
        #expect(found.count == 1)
        #expect(found.first?.merchant == "Netflix")
    }

    @Test("two unrelated charges are not a subscription")
    func notASubscription() {
        let found = Insights.detectSubscriptions([
            tx("Kopi", 28_000, date: "2026-09-01"),
            tx("Gojek", 35_000, date: "2026-09-02"),
        ])
        #expect(found.isEmpty)
    }

    @Test("a foreign amount uses its rate when it has one")
    func foreignCurrency() {
        let usd = tx("Amazon", 20, currency: "USD", fxRate: 16_000)
        #expect(Insights.baseAmount(usd, "IDR") == 320_000)
    }
}
