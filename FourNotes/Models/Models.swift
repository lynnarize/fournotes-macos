import Foundation

// The shared data model, ported field-for-field from src/lib/types.ts so the
// JSON on disk stays interchangeable with the web app's "four-notes:v1" blob.

enum Tab: String, CaseIterable, Codable, Identifiable {
    case today, notes, todo, finance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .notes: return "Notes"
        case .todo: return "To-Do"
        case .finance: return "Finance"
        }
    }
    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .notes: return "doc.text"
        case .todo: return "checkmark.circle"
        case .finance: return "creditcard"
        }
    }
}

enum NoteSource: String, Codable {
    case manual, chat, ocr, recording, share
}

protocol BaseItem: Identifiable, Codable {
    var id: String { get }
    var createdAt: String { get }
    var updatedAt: String { get set }
    var deletedAt: String? { get set }
    var spaceId: String? { get set }
    var sample: Bool? { get }
}

struct Note: BaseItem, Equatable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var spaceId: String?
    var sample: Bool?

    var title: String
    /// Plain text / light markdown: what search, the AI and the brief read.
    var content: String
    /// Rich text as the web app's editor stores it. The Mac app reads this once
    /// for a note it has not opened before, and writes it on export — it is no
    /// longer the live storage format, because round-tripping it lost lists,
    /// checklists and dividers in both directions.
    var html: String?
    /// The Mac editor's own representation, kept only when the note carries
    /// formatting the plain text cannot express. See Views/Notes/NoteDocument.swift.
    var richText: Data?
    var source: NoteSource
    var tags: [String]
    /// Kept for documents written by the web app, and for export. New scans go
    /// to `imageFile` instead — see Store/Attachments.swift.
    var imageDataUrl: String?
    /// The scanned page, stored beside the document rather than inside it.
    var imageFile: String?

    init(id: String, createdAt: String, updatedAt: String, deletedAt: String? = nil,
         spaceId: String? = nil, sample: Bool? = nil, title: String = "Untitled",
         content: String = "", html: String? = nil, richText: Data? = nil,
         source: NoteSource = .manual,
         tags: [String] = [], imageDataUrl: String? = nil, imageFile: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.spaceId = spaceId; self.sample = sample
        self.title = title; self.content = content; self.html = html
        self.richText = richText
        self.source = source; self.tags = tags; self.imageDataUrl = imageDataUrl
        self.imageFile = imageFile
    }
}

enum Priority: String, Codable, CaseIterable {
    case low, medium, high
    var label: String { rawValue.capitalized }
    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// A to-do that also logs spending when completed (rent, internet, subscriptions).
struct Bill: Codable, Equatable {
    var amount: Double
    var currency: String?
    var category: String
}

struct Todo: BaseItem, Equatable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var spaceId: String?
    var sample: Bool?

    var title: String
    var notes: String?
    var done: Bool
    /// In progress: the "Doing" column of the board. Ignored once done.
    var doing: Bool?
    var completedAt: String?
    var dueAt: String?
    var remindAt: String?
    var reminded: Bool?
    var priority: Priority
    var source: NoteSource
    /// Subset of RFC 5545, e.g. "FREQ=MONTHLY;INTERVAL=1".
    var rrule: String?
    var bill: Bill?
    var noteId: String?

    init(id: String, createdAt: String, updatedAt: String, deletedAt: String? = nil,
         spaceId: String? = nil, sample: Bool? = nil, title: String = "New task",
         notes: String? = nil, done: Bool = false, doing: Bool? = nil,
         completedAt: String? = nil, dueAt: String? = nil, remindAt: String? = nil,
         reminded: Bool? = nil, priority: Priority = .medium, source: NoteSource = .manual,
         rrule: String? = nil, bill: Bill? = nil, noteId: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.spaceId = spaceId; self.sample = sample
        self.title = title; self.notes = notes; self.done = done; self.doing = doing
        self.completedAt = completedAt; self.dueAt = dueAt; self.remindAt = remindAt
        self.reminded = reminded; self.priority = priority; self.source = source
        self.rrule = rrule; self.bill = bill; self.noteId = noteId
    }

    /// Which board column this task belongs in.
    var column: BoardColumn { done ? .done : (doing == true ? .doing : .todo) }
}

enum BoardColumn: String, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todo: return "To do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}

/// Built-in categories. Users can add their own (Settings -> Categories).
let EXPENSE_CATEGORIES = [
    "Food & Drink", "Groceries", "Transport", "Shopping", "Bills & Utilities",
    "Health", "Entertainment", "Education", "Income", "Other",
]

let CURRENCIES = ["IDR", "USD", "SGD", "MYR", "EUR", "JPY", "AUD", "GBP", "THB", "KRW", "CNY", "SAR"]

struct LineItem: Codable, Equatable, Identifiable {
    var name: String
    var qty: Double?
    var price: Double?
    var id: String { "\(name)-\(qty ?? 0)-\(price ?? 0)" }

    enum CodingKeys: String, CodingKey { case name, qty, price }

    init(name: String, qty: Double? = nil, price: Double? = nil) {
        self.name = name; self.qty = qty; self.price = price
    }

    /// Decoded leniently: these come from a model reading a photograph, so a
    /// price arrives as "70.000" as often as 70000, and a name is sometimes
    /// missing altogether. A bad line must not cost the whole receipt.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        qty = LineItem.number(c, .qty)
        price = LineItem.number(c, .price)
    }

    private static func number(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double? {
        if let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil {
            return Money.isValidAmount(value) ? value : nil
        }
        if let text = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil {
            return Money.parse(text)
        }
        return nil
    }
}

struct Split: Codable, Equatable, Identifiable {
    var name: String
    /// In the transaction's currency.
    var amount: Double
    var settled: Bool
    var id: String { name }
}

struct Transaction: BaseItem, Equatable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var spaceId: String?
    var sample: Bool?

    var merchant: String
    /// Positive = spend, negative = income.
    var amount: Double
    var currency: String
    /// 1 unit of `currency` in the base currency (only when currency differs).
    var fxRate: Double?
    var category: String
    /// YYYY-MM-DD
    var date: String
    var items: [LineItem]
    var source: NoteSource
    /// Kept for documents written by the web app, and for export.
    var imageDataUrl: String?
    /// The scanned receipt, stored beside the document rather than inside it.
    var imageFile: String?
    /// Other people's shares of this bill.
    var splits: [Split]?
    var noteId: String?

    init(id: String, createdAt: String, updatedAt: String, deletedAt: String? = nil,
         spaceId: String? = nil, sample: Bool? = nil, merchant: String = "Unknown",
         amount: Double = 0, currency: String = "IDR", fxRate: Double? = nil,
         category: String = "Other", date: String = "", items: [LineItem] = [],
         source: NoteSource = .manual, imageDataUrl: String? = nil,
         imageFile: String? = nil, splits: [Split]? = nil, noteId: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.spaceId = spaceId; self.sample = sample
        self.merchant = merchant; self.amount = amount; self.currency = currency
        self.fxRate = fxRate; self.category = category; self.date = date
        self.items = items; self.source = source; self.imageDataUrl = imageDataUrl
        self.imageFile = imageFile; self.splits = splits; self.noteId = noteId
    }
}

enum StickyColor: String, Codable, CaseIterable, Identifiable {
    case yellow, pink, blue, green
    var id: String { rawValue }
}

struct Sticky: BaseItem, Equatable {
    var id: String
    var createdAt: String
    var updatedAt: String
    var deletedAt: String?
    var spaceId: String?
    var sample: Bool?

    var text: String
    var color: StickyColor
    /// Pinned stickies show in the daily brief.
    var pinned: Bool?

    init(id: String, createdAt: String, updatedAt: String, deletedAt: String? = nil,
         spaceId: String? = nil, sample: Bool? = nil, text: String = "",
         color: StickyColor = .yellow, pinned: Bool? = nil) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.deletedAt = deletedAt; self.spaceId = spaceId; self.sample = sample
        self.text = text; self.color = color; self.pinned = pinned
    }
}

struct MonthlySummary: Codable, Equatable, Identifiable {
    /// YYYY-MM
    var month: String
    var total: Double
    var currency: String
    var byCategory: [String: Double]
    /// AI written summary.
    var text: String
    var createdAt: String
    var id: String { month }
}

struct DailyBrief: Codable, Equatable, Identifiable {
    /// YYYY-MM-DD
    var date: String
    var text: String
    /// A fingerprint of what it was written from: when today's data no longer
    /// matches, the brief is written again.
    var basis: String? = nil
    var id: String { date }
}

struct AppSettings: Codable, Equatable {
    /// Base currency.
    var currency: String = "IDR"
    /// Monthly, in the base currency.
    var budgets: [String: Double] = [:]
    /// Extra categories the user created.
    var categories: [String]?
    /// Speak replies aloud in voice mode.
    var voiceReplies: Bool = true
    /// Last change, so sync can keep the newer settings.
    var updatedAt: String?
    var name: String?
    /// Mac-only: appearance preference. Ignored by the web app, preserved on sync.
    var theme: ThemeChoice?
}

struct Space: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var inviteCode: String?
}

struct ChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var role: Role
    var content: String
    var id = UUID().uuidString

    enum CodingKeys: String, CodingKey { case role, content }
}
