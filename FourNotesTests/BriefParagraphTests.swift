import Foundation
import Testing
@testable import FourNotes

@Suite("Today's brief as one paragraph")
struct BriefParagraphTests {
    let now = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!

    private func at(_ hour: Int, _ minute: Int = 0, daysAgo: Int = 0) -> Date {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func input(due: [BriefParagraph.Item] = [], focus: [BriefParagraph.Item] = [],
                       yesterday: [BriefParagraph.Spend] = [], alerts: [String] = [],
                       notes: [BriefParagraph.NoteRef] = []) -> BriefParagraph.Input {
        .init(now: now, due: due, focus: focus, yesterday: yesterday, currency: "IDR",
              alerts: alerts, notesToday: notes)
    }

    @Test("a quiet day is one short sentence")
    func quiet() {
        let pieces = BriefParagraph.compose(input())
        #expect(BriefParagraph.text(pieces) == "Nothing is pressing today, so the page is yours to fill.")
        #expect(pieces.allSatisfy { $0.target == nil })
    }

    @Test("yesterday, today, heads-ups and notes read as one story, each a link")
    func full() {
        let pieces = BriefParagraph.compose(input(
            due: [.init(id: "a", title: "Call Budi", due: at(14, 30)),
                  .init(id: "b", title: "Pay rent", due: at(9, daysAgo: 2))],
            yesterday: [.init(category: "Food & Drink", amount: 80_000),
                        .init(category: "Transport", amount: 20_000)],
            alerts: ["Food & Drink budget 85% used (Rp 850rb of Rp 1jt)"],
            notes: [.init(id: "n", title: "Gift ideas")]))
        let text = BriefParagraph.text(pieces)
        #expect(text.hasPrefix("Yesterday closed with "))
        #expect(text.contains(" spent, most of it on Food & Drink. "))
        #expect(text.contains("The day ahead holds 2 tasks, and it opens with Call Budi at 2:30 PM, "
                              + "while Pay rent has been waiting since an earlier day."))
        #expect(text.contains("Along the way, keep in mind that your Food & Drink budget is 85% used."))
        #expect(text.hasSuffix("And Gift ideas, jotted down earlier, is right where you left it."))

        let targets = pieces.compactMap(\.target)
        #expect(targets.contains(.todos))
        #expect(targets.contains(.todo("a")))
        #expect(targets.contains(.todo("b")))
        #expect(targets.contains(.finance))
        #expect(targets.contains(.note("n")))
        // Plain runs are merged: no two in a row.
        #expect(!zip(pieces, pieces.dropFirst()).contains { $0.target == nil && $1.target == nil })
    }

    @Test("with nothing due, the top priority is suggested")
    func focus() {
        let pieces = BriefParagraph.compose(input(focus: [.init(id: "f", title: "Write report", due: nil)]))
        #expect(BriefParagraph.text(pieces) == "Nothing is pressing today, which leaves room for Write report to finally move forward.")
        #expect(pieces.contains { $0.target == .todo("f") })
    }

    @Test("one overdue task says so once")
    func oneOverdue() {
        let pieces = BriefParagraph.compose(input(due: [.init(id: "x", title: "Renew SIM", due: at(9, daysAgo: 1))]))
        #expect(BriefParagraph.text(pieces) == "The day ahead holds just one task: Renew SIM, carried over from an earlier day.")
    }

    @Test("the story picks up where the day is")
    func timeOfDay() {
        let evening = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: now)!
        let pieces = BriefParagraph.compose(.init(
            now: evening, due: [.init(id: "a", title: "Call Budi", due: at(21))], focus: [],
            yesterday: [.init(category: "Transport", amount: 20_000)], currency: "IDR",
            alerts: ["Andi still owes you Rp 50,000", "Rent budget 90% used (Rp 4,5jt of Rp 5jt)"],
            notesToday: [.init(id: "1", title: "a"), .init(id: "2", title: "b")]))
        let text = BriefParagraph.text(pieces)
        #expect(text.contains(" spent on Transport. The evening holds just one task: Call Budi at 9:00 PM."))
        #expect(text.contains("keep in mind that Andi still owes you Rp 50,000 and your Rent budget is 90% used."))
        #expect(text.hasSuffix("And the 2 quick notes you jotted down today are right where you left them."))
    }

    @Test("links survive the trip through a URL, odd ids included")
    func urls() throws {
        let targets: [BriefParagraph.Target] = [.todos, .finance, .notes, .todo("abc-123"), .note("a b/c")]
        for target in targets {
            let url = try #require(BriefParagraph.url(target))
            #expect(BriefParagraph.target(url) == target)
        }
        #expect(BriefParagraph.target(URL(string: "https://example.com/todo/1")!) == nil)
        #expect(BriefParagraph.target(URL(string: "fournotes-brief://delete/1")!) == nil)
    }
}
