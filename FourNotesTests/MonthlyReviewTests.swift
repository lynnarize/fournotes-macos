import Foundation
import Testing
@testable import FourNotes

@Suite("Monthly review")
struct MonthlyReviewTests {
    @Test("figures come from the app, judgement from the model")
    func compose() {
        // What the on-device model wrote: a wrong total and categories as lines.
        let written = """
            - Total: 350,000 IDR
            - Bills & Utilities: 700,000 (top category)
            - Food & Drink: 530,000
            - Internet: Rp 350,000 (twice)
            - Warteg Bahari: 90,000
            - Unusual: two internet bills on the same day
            - Saving tip: set a weekly grocery budget
            """
        let text = MonthlyReview.compose(written, total: 3_591_500,
                                         byCategory: ["Bills & Utilities": 2_850_000, "Food & Drink": 530_000,
                                                      "Groceries": 87_500, "Transport": 35_000],
                                         currency: "IDR")
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "- Total: \(Money.format(3_591_500, "IDR"))")
        #expect(lines[1].hasPrefix("- Top categories: Bills & Utilities"))
        #expect(lines.contains("- Unusual: two internet bills on the same day"))
        #expect(lines.contains("- Saving tip: set a weekly grocery budget"))
        #expect(!text.contains("350,000"))
        #expect(!text.contains("Food & Drink: 530,000"))
        #expect(!text.contains("Internet:"))
        #expect(!text.contains("Warteg Bahari:"))
    }

    @Test("a review shows amounts in the app's money format")
    func briefAmounts() {
        let lines = BriefText.lines("- Total: 3,975,000 IDR\n- Top 3: Bills & Utilities (2,500,000)", currency: "IDR")
        #expect(lines[0].label == "Total")
        #expect(lines[0].body == Money.format(3_975_000, "IDR"))
        #expect(lines[1].body.contains(Money.format(2_500_000, "IDR")))
    }
}
