import Foundation
import Testing
@testable import FourNotes

// Repeat rules. A bill that repeats is the one place where getting a date wrong
// compounds: every completion schedules the next one.

@Suite("Recurrence")
struct RecurrenceTests {

    @Test("parses the canonical form")
    func canonical() {
        let r = Recurrence.parse("FREQ=MONTHLY;INTERVAL=1")
        #expect(r?.freq == .MONTHLY)
        #expect(r?.interval == 1)
    }

    @Test("accepts what a small model actually writes")
    func bareFrequency() {
        // The on-device model answers "MONTHLY" as often as the full rule.
        // Dropping it silently means the task never repeats.
        #expect(Recurrence.parse("MONTHLY")?.freq == .MONTHLY)
        #expect(Recurrence.normalised("MONTHLY") == "FREQ=MONTHLY;INTERVAL=1")
        #expect(Recurrence.normalised("weekly") == "FREQ=WEEKLY;INTERVAL=1")
        #expect(Recurrence.normalised("not a rule") == nil)
        #expect(Recurrence.normalised("") == nil)
    }

    @Test("a hostile interval cannot overflow")
    func hugeInterval() {
        // rrule comes from JSON and from models; 7 * Int.max traps.
        let rule = "FREQ=WEEKLY;INTERVAL=9223372036854775807"
        if let parsed = Recurrence.parse(rule) {
            #expect(parsed.interval <= 1000, "interval should be bounded")
        }
        _ = Recurrence.nextOccurrence(DateKit.nowIso(), rule)   // must not trap
    }

    @Test("month-end does not ratchet down")
    func monthEndAnchor() throws {
        // A bill due on the 31st must stay on the 31st. Clamping Jan 31 to
        // Feb 28 is right; carrying 28 forever afterwards is not.
        var date = try #require(DateKit.date("2026-01-31T09:00:00.000Z"))
        // The day the user picked is recorded in the rule, so it survives a
        // month that cannot represent it.
        let rule = try #require(Recurrence.normalised("MONTHLY", anchoredTo: date))
        #expect(rule.contains("BYMONTHDAY=31"))
        var days: [Int] = []
        let cal = Calendar.current
        for _ in 0..<4 {
            let next = Recurrence.nextOccurrence(DateKit.iso(date), rule)
            date = try #require(DateKit.date(next))
            days.append(cal.component(.day, from: date))
        }
        // Feb clamps to 28, then March must return to 31.
        #expect(days == [28, 31, 30, 31], "got \(days)")
    }

    @Test("advancing always lands in the future")
    func rollsForward() throws {
        // Completing a daily task that was due months ago must not schedule the
        // next one in the past.
        // A fixed reference point, so the assertion cannot race the clock.
        let now = try #require(DateKit.date("2026-09-21T12:00:00.000Z"))
        let longAgo = DateKit.iso(now.addingTimeInterval(-90 * 86_400))

        for rule in ["FREQ=DAILY;INTERVAL=1", "FREQ=WEEKLY;INTERVAL=2", "FREQ=MONTHLY;INTERVAL=1"] {
            let next = Recurrence.next(after: longAgo, rule, notBefore: now)
            let date = try #require(DateKit.date(next))
            #expect(date >= now, "\(rule) scheduled in the past: \(next)")
        }
    }

    @Test("a future date is left alone")
    func alreadyFuture() throws {
        let now = try #require(DateKit.date("2026-09-21T12:00:00.000Z"))
        let soon = DateKit.iso(now.addingTimeInterval(3 * 86_400))
        #expect(Recurrence.next(after: soon, "FREQ=DAILY;INTERVAL=1", notBefore: now) == soon)
    }

    @Test("completing early advances past the completed occurrence")
    func completingFutureOccurrence() throws {
        let now = try #require(DateKit.date("2026-09-21T12:00:00.000Z"))
        let future = DateKit.iso(now.addingTimeInterval(3 * 86_400))
        let futureDate = try #require(DateKit.date(future))
        let next = Recurrence.nextAfterCompleting(future, "FREQ=DAILY;INTERVAL=1",
                                                  notBefore: now)
        let date = try #require(DateKit.date(next))
        #expect(date > futureDate)
    }

    @Test("an undated repeat advances from the completion time")
    func completingUndatedRepeat() throws {
        let now = try #require(DateKit.date("2026-09-21T12:00:00.000Z"))
        let next = Recurrence.nextAfterCompleting(DateKit.iso(now),
                                                  "FREQ=DAILY;INTERVAL=1",
                                                  notBefore: now)
        let date = try #require(DateKit.date(next))
        #expect(date >= now.addingTimeInterval(86_400))
    }

    @Test("one step is still exactly one step")
    func singleStep() throws {
        // next(after:) rolls forward; nextOccurrence stays pure and advances once.
        let start = "2026-03-10T09:00:00.000Z"
        let next = Recurrence.nextOccurrence(start, "FREQ=MONTHLY;INTERVAL=1")
        let date = try #require(DateKit.date(next))
        #expect(Calendar.current.component(.month, from: date) == 4)
        #expect(Calendar.current.component(.day, from: date) == 10)
    }

    @Test("labels")
    func labels() {
        #expect(Recurrence.label("FREQ=MONTHLY;INTERVAL=1") == "Every month")
        #expect(Recurrence.label("FREQ=DAILY;INTERVAL=3") == "Every 3 days")
        #expect(Recurrence.label(nil) == "")
    }
}
