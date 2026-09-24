import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import FourNotes

@Suite("Edge dock geometry")
struct DockGeometryTests {
    let screen = CGRect(x: 0, y: 70, width: 1470, height: 855)

    @Test("the handle sits flush against the chosen edge")
    func flush() {
        let right = DockGeometry.handle(in: screen, edge: .right, centerY: 500)
        #expect(right.frame.maxX == screen.maxX)
        let left = DockGeometry.handle(in: screen, edge: .left, centerY: 500)
        #expect(left.frame.minX == screen.minX)
        #expect(right.screenCenterY == 500)
    }

    @Test("dragged past the top or bottom, the handle stays on screen")
    func clamped() {
        let top = DockGeometry.handle(in: screen, edge: .right, centerY: 5_000)
        #expect(top.screenCenterY + DockGeometry.handleHeight / 2 + DockGeometry.handleFillet <= screen.maxY)
        let bottom = DockGeometry.handle(in: screen, edge: .right, centerY: -5_000)
        #expect(bottom.screenCenterY - DockGeometry.handleHeight / 2 - DockGeometry.handleFillet >= screen.minY)
    }

    @Test("the drawer fits a small screen and follows the handle on a big one")
    func drawer() {
        let small = CGRect(x: 0, y: 0, width: 1280, height: 600)
        let d = DockGeometry.drawer(in: small, edge: .right, centerY: 300)
        #expect(d.bodyHeight + 2 * DockGeometry.drawerFillet <= small.height)
        #expect(d.frame.maxX == small.maxX)

        let big = CGRect(x: 0, y: 0, width: 2560, height: 1400)
        let near = DockGeometry.drawer(in: big, edge: .right, centerY: 1_000)
        #expect(near.bodyHeight == DockGeometry.drawerMaxHeight)
        #expect(near.screenCenterY == 1_000)
    }

    @Test("opening starts with the handle exactly where it was")
    func handoff() {
        let handle = DockGeometry.handle(in: screen, edge: .right, centerY: 420)
        let drawer = DockGeometry.drawer(in: screen, edge: .right, centerY: handle.screenCenterY)
        let start = handle.handle(placedIn: drawer.frame)
        #expect(start.frame == drawer.frame)
        #expect(start.screenCenterY == handle.screenCenterY)
        #expect(start.bodyWidth == DockGeometry.handleWidth)
    }

    @Test("a saved position survives a round trip")
    func position() {
        let y: CGFloat = 612
        let fraction = DockGeometry.fraction(of: y, in: screen)
        #expect(abs(DockGeometry.centerY(fraction: fraction, in: screen) - y) < 0.001)
        #expect(DockGeometry.fraction(of: -100, in: screen) == 0)
    }
}

@Suite("Glance")
struct GlanceTests {
    @Test("a spend in one line", arguments: [
        ("coffee 25k at Starbucks", "Starbucks", 25_000.0, "Food & Drink"),
        ("gojek 18rb", "Gojek", 18_000, "Transport"),
        ("25k", "Expense", 25_000, "Other"),
        ("-150k refund", "Refund", -150_000, "Income"),
        ("lunch 45.000 di Warteg Bahari", "Warteg Bahari", 45_000, "Food & Drink"),
        ("kopi Rp 25.000", "Kopi", 25_000, "Food & Drink"),
        ("tiket masuk Rp 50.000", "Tiket masuk", 50_000, "Other"),
        ("Pembayaran berhasil Rp 45.000 ke Warteg Bahari via GoPay", "Warteg Bahari", 45_000, "Food & Drink"),
    ])
    func spend(text: String, merchant: String, amount: Double, category: String) {
        let s = Glance.spend(text)
        #expect(s?.merchant == merchant)
        #expect(s?.amount == amount)
        #expect(s?.category == category)
    }

    @Test("no amount, no spend")
    func noAmount() {
        #expect(Glance.spend("coffee at Starbucks") == nil)
        #expect(Glance.spend("   ") == nil)
        #expect(Glance.spend("25kg of rice") == nil)
    }

    private func todo(_ title: String, due: Date? = nil, done: Bool = false, completed: Date? = nil,
                      priority: Priority = .medium) -> Todo {
        Todo(id: UUID().uuidString, createdAt: DateKit.nowIso(), updatedAt: DateKit.nowIso(),
             title: title, done: done, completedAt: completed.map(DateKit.iso),
             dueAt: due.map(DateKit.iso), priority: priority)
    }

    @Test("due by today: overdue first, tomorrow and done left out")
    func dueByToday() {
        let now = Date()
        let cal = Calendar.current
        let todos = [
            todo("later today", due: cal.date(bySettingHour: 23, minute: 0, second: 0, of: now)),
            todo("last week", due: cal.date(byAdding: .day, value: -7, to: now)),
            todo("tomorrow", due: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))?
                .addingTimeInterval(3600)),
            todo("finished", due: now, done: true, completed: now),
            todo("undated"),
        ]
        #expect(Glance.dueByToday(todos, now: now).map(\.title) == ["last week", "later today"])
        #expect(Glance.doneToday(todos, now: now).map(\.title) == ["finished"])
    }

    @Test("anytime: undated open tasks, most important first")
    func anytime() {
        let todos = [todo("low", priority: .low), todo("high", priority: .high), todo("dated", due: Date())]
        #expect(Glance.anytime(todos).map(\.title) == ["high", "low"])
    }
}

@Suite("Dictation levels")
struct TranscriberLevelTests {
    private func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { QuickTranscriber.level(of: $0) }
    }

    @Test("silence is zero, speech fills the bar, nothing overflows")
    func levels() {
        #expect(level([]) == 0)
        #expect(level([Float](repeating: 0, count: 512)) == 0)
        let quiet = level([Float](repeating: 0.001, count: 512))   // -60 dB
        let speech = level((0..<512).map { Float(sin(Double($0) / 8)) * 0.2 })
        let loud = level([Float](repeating: 1, count: 512))
        #expect(quiet == 0)
        #expect(speech > 0.5 && speech < 1)
        #expect(loud == 1)
        #expect(level([Float.nan, 1]) == 0)
    }
}

@Suite("Edge dock layout")
struct DockLayoutTests {
    @Test("a saved arrangement comes back as it was")
    func roundTrip() {
        let layout: [[MiniApp]] = [[.note, .ask], [.tasks, .bills, .transcribe, .spend]]
        #expect(MiniApp.layout(from: MiniApp.encode(layout)) == layout)
    }

    @Test("nothing saved is the default")
    func fallback() {
        #expect(MiniApp.layout(from: nil) == MiniApp.defaultLayout)
        #expect(MiniApp.layout(from: "") == MiniApp.defaultLayout)
    }

    @Test("repeats and unknown names are dropped, missing mini apps come back")
    func repaired() {
        let layout = MiniApp.layout(from: "ask,ask,weather|note")
        #expect(layout[0].first == .ask)
        #expect(layout.flatMap { $0 }.count == MiniApp.allCases.count)
        #expect(Set(layout.flatMap { $0 }) == Set(MiniApp.allCases))
    }

    @Test("an empty column is kept, so cards can be dropped into it")
    func emptyColumn() {
        let layout = MiniApp.layout(from: "|note,tasks,bills,transcribe,spend,ask")
        #expect(layout[0].isEmpty)
        #expect(layout[1].count == 6)
    }
}

@Suite("Dictation segments")
struct TranscriptSegmentTests {
    @Test("a revision of the same words is not a new segment")
    func revision() {
        #expect(!QuickTranscriber.startsOver(previous: "The phones even", next: "The phone's evening"))
        #expect(!QuickTranscriber.startsOver(previous: "Meet Budi", next: "Meet Budi tomorrow at nine"))
        #expect(!QuickTranscriber.startsOver(previous: "", next: "Hello"))
    }

    @Test("after a pause the recognizer starts over, and the earlier words are kept")
    func newSegment() {
        let before = "We should book the hotel near Bugis for the twelfth"
        #expect(QuickTranscriber.startsOver(previous: before, next: "And the flights"))
        #expect(QuickTranscriber.join(before, "And the flights") == before + " And the flights")
        #expect(QuickTranscriber.join("", "Hi") == "Hi")
    }
}

@Suite("Themes")
struct ThemeTests {
    @Test("Paper is a light look on warm paper; dark always wins at night")
    func paper() {
        #expect(ThemeChoice.paper.colorScheme == .light)
        #expect(ThemeChoice.paper.palette(for: .light).bg == Palette.paper.bg)
        #expect(ThemeChoice.paper.palette(for: .dark).bg == Palette.dark.bg)
        #expect(ThemeChoice.light.palette(for: .light).bg == Palette.light.bg)
    }
}

@Suite("Reply tidying")
struct ReplyTidyTests {
    @Test("a tool's name written into an answer is removed")
    func toolLabels() {
        #expect(ModelText.withoutToolLabels("create_todo: Pay internet bill, Go to Bali")
                == "Pay internet bill, Go to Bali")
        #expect(ModelText.withoutToolLabels("`create_note`: gift ideas") == "Gift ideas")
        #expect(ModelText.withoutToolLabels("Nothing is due this week.") == "Nothing is due this week.")
        #expect(ModelText.withoutToolLabels("I can create_todo: later") == "I can create_todo: later")
        #expect(ModelText.withoutToolLabels("/todo: Buy groceries (due today)") == "Buy groceries (due today)")
        #expect(ModelText.withoutToolLabels("Time: 9am") == "Time: 9am")
    }
}

@Suite("Dictation revisions")
struct TranscriptRevisionTests {
    @Test("numbers rewritten as digits are a revision, not a new segment")
    func digits() {
        #expect(!QuickTranscriber.startsOver(previous: "Coffee twenty", next: "Coffee 20"))
        #expect(!QuickTranscriber.startsOver(previous: "I spent twenty five thousand", next: "I spent 25,000"))
    }
}

@Suite("Upcoming payments")
struct UpcomingDateTests {
    @Test("a bill's day is the local day, not the UTC one")
    func localDay() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 1; comps.hour = 6
        let due = Calendar.current.date(from: comps)!
        let todo = Todo(id: "b", createdAt: DateKit.nowIso(), updatedAt: DateKit.nowIso(), title: "Rent",
                        dueAt: DateKit.iso(due), bill: Bill(amount: 100, currency: "IDR", category: "Bills & Utilities"))
        let list = Glance.upcoming(todos: [todo], transactions: [], currency: "IDR", days: 400,
                                   now: Calendar.current.date(byAdding: .day, value: -1, to: due)!)
        #expect(list.first?.date == "2026-10-01")
    }
}

@MainActor
@Suite("Edge dock pointer")
struct DockPointerTests {
    @Test("the pointer is reported from the top left, the way the dock lays itself out")
    func topLeft() throws {
        let host = DockHostingView(rootView: DockScene(model: AppModel.shared, dock: EdgeDock.shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 200)
        // 10 points below the window's top (window coordinates start at the bottom).
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 10, y: 190),
                                                    modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 0, pressure: 0))
        let point = host.point(of: event)
        #expect(point.x == 10)
        #expect(point.y == 10)
    }
}
