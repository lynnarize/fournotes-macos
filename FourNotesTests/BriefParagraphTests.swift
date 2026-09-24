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
        #expect(BriefParagraph.text(pieces) == "Nothing is due today.")
        #expect(pieces.allSatisfy { $0.target == nil })
    }

    @Test("tasks, spending, alerts and notes read as one paragraph, each a link")
    func full() {
        let pieces = BriefParagraph.compose(input(
            due: [.init(id: "a", title: "Call Budi", due: at(14, 30)),
                  .init(id: "b", title: "Pay rent", due: at(9, daysAgo: 2))],
            yesterday: [.init(category: "Food & Drink", amount: 80_000),
                        .init(category: "Transport", amount: 20_000)],
            alerts: ["Food & Drink budget 85% used (Rp 850rb of Rp 1jt)"],
            notes: [.init(id: "n", title: "Gift ideas")]))
        let text = BriefParagraph.text(pieces)
        #expect(text.hasPrefix("You have 2 things due today, starting with Call Budi at 2:30 PM, and Pay rent is overdue."))
        #expect(text.contains("mostly on Food & Drink."))
        #expect(text.contains("Heads-up: Food & Drink budget 85% used."))
        #expect(text.hasSuffix("You jotted down Gift ideas."))

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
        #expect(BriefParagraph.text(pieces) == "Nothing is due today, so Write report could be the one to move forward.")
        #expect(pieces.contains { $0.target == .todo("f") })
    }

    @Test("one overdue task says so once")
    func oneOverdue() {
        let pieces = BriefParagraph.compose(input(due: [.init(id: "x", title: "Renew SIM", due: at(9, daysAgo: 1))]))
        #expect(BriefParagraph.text(pieces) == "You have one thing due today: Renew SIM, which is overdue.")
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
