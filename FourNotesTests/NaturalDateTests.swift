import Foundation
import Testing
@testable import FourNotes

// The on-device model copies the user's words for a time; this is what turns
// them into one. Every case here is a phrasing that went wrong when the model
// was asked to produce an ISO timestamp itself.

@Suite("NaturalDate")
struct NaturalDateTests {
    private let cal = Calendar.current

    /// Noon today, so "tomorrow" and "at 7pm" are unambiguous whatever time
    /// the suite runs.
    private var now: Date { cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())! }

    private func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let d = cal.date(byAdding: .day, value: offset, to: now)!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
    }

    @Test("tomorrow with a time, however it is typed", arguments: [
        "tomorrow at 10 am", "tommorow at 10 am", "tomorow 10am", "tmrw at 10:00am", "tomorrow at 10 a.m.",
    ])
    func tomorrow(_ phrase: String) throws {
        #expect(NaturalDate.resolve(phrase, now: now) == day(1, 10))
    }

    @Test("Indonesian", arguments: [
        ("besok jam 9 pagi", 1, 9, 0), ("besok jam 7 malam", 1, 19, 0),
        ("besok jam 14.30", 1, 14, 30), ("lusa jam 8 pagi", 2, 8, 0),
    ])
    func indonesian(_ phrase: String, _ offset: Int, _ hour: Int, _ minute: Int) {
        #expect(NaturalDate.resolve(phrase, now: now) == day(offset, hour, minute))
    }

    @Test("a day with no time is placed in the morning")
    func dayOnly() {
        #expect(NaturalDate.resolve("tomorrow", now: now) == day(1, 9))
        #expect(NaturalDate.resolve("besok", now: now) == day(1, 9))
    }

    @Test("a time that has passed today means tomorrow")
    func pastTime() {
        #expect(NaturalDate.resolve("at 9am", now: now) == day(1, 9))
        #expect(NaturalDate.resolve("at 7pm", now: now) == day(0, 19))
    }

    @Test("in a couple of hours")
    func relative() throws {
        let when = try #require(NaturalDate.resolve("in 2 hours", now: now))
        #expect(abs(when.timeIntervalSince(now) - 7200) < 60)
        let later = try #require(NaturalDate.resolve("2 jam lagi", now: now))
        #expect(abs(later.timeIntervalSince(now) - 7200) < 60)
    }

    @Test("a weekday lands on that weekday")
    func weekday() throws {
        let monday = try #require(NaturalDate.resolve("Monday at 8am", now: now))
        #expect(cal.component(.weekday, from: monday) == 2)
        #expect(cal.component(.hour, from: monday) == 8)
        #expect(monday > now)
    }

    @Test("a day of the month is its next occurrence")
    func dayOfMonth() throws {
        let fifth = try #require(NaturalDate.resolve("every month on the 5th at 9am", now: now))
        #expect(cal.component(.day, from: fifth) == 5)
        #expect(cal.component(.hour, from: fifth) == 9)
        #expect(fifth > now)
    }

    @Test("no time means nothing")
    func none() {
        #expect(NaturalDate.resolve("buy milk", now: now) == nil)
        #expect(NaturalDate.resolve("", now: now) == nil)
    }

    @Test("titles lose the time they were said with")
    func titles() {
        #expect(NaturalDate.removingTime(from: "Book lounge room for tommorow at 10 am", now: now) == "Book lounge room")
        #expect(NaturalDate.removingTime(from: "Call mom tomorrow at 7pm", now: now) == "Call mom")
        #expect(NaturalDate.removingTime(from: "Buy milk", now: now) == "Buy milk")
    }

    @Test("a time left in a task title is read out of it")
    func splitTitle() throws {
        let split = try #require(NaturalDate.splitTitle("Buy groceries at 10 AM tomorrow", now: now))
        #expect(split.title == "Buy groceries")
        #expect(split.date == day(1, 10))
        // No day or time: the title stays whole.
        #expect(NaturalDate.splitTitle("Read chapter 5", now: now) == nil)
        #expect(NaturalDate.splitTitle("Buy milk", now: now) == nil)
    }
}
