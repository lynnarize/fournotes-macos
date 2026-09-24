import Foundation

// The persisted document, same shape as the web app's localStorage["four-notes:v1"].
struct AppData: Codable, Equatable {
    var notes: [Note] = []
    var todos: [Todo] = []
    var transactions: [Transaction] = []
    var stickies: [Sticky] = []
    var summaries: [MonthlySummary] = []
    var briefs: [DailyBrief] = []
    var settings = AppSettings()
    var spaces: [Space] = []
    /// null = personal
    var currentSpaceId: String?

    /// Rows this document had but the app could not read. Not persisted — it
    /// describes the load that just happened, so the file can be backed up
    /// before anything overwrites it.
    var skippedRows = 0

    /// Fill in fields added after the first release so older saved data keeps
    /// working, and keep the rows we can read when one of them is broken.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var skipped = 0
        notes = c.lenientArray(Note.self, forKey: .notes, skipped: &skipped)
        todos = c.lenientArray(Todo.self, forKey: .todos, skipped: &skipped)
        transactions = c.lenientArray(Transaction.self, forKey: .transactions, skipped: &skipped)
        stickies = c.lenientArray(Sticky.self, forKey: .stickies, skipped: &skipped)
        summaries = c.lenientArray(MonthlySummary.self, forKey: .summaries, skipped: &skipped)
        briefs = c.lenientArray(DailyBrief.self, forKey: .briefs, skipped: &skipped)
        spaces = c.lenientArray(Space.self, forKey: .spaces, skipped: &skipped)
        settings = ((try? c.decodeIfPresent(AppSettings.self, forKey: .settings)) ?? nil) ?? AppSettings()
        currentSpaceId = (try? c.decodeIfPresent(String.self, forKey: .currentSpaceId)) ?? nil
        skippedRows = skipped
    }

    init() {}
}

extension AppData {
    /// The keys written to disk. `skippedRows` is state about a load, not part
    /// of the document.
    enum CodingKeys: String, CodingKey {
        case notes, todos, transactions, stickies, summaries, briefs, settings, spaces, currentSpaceId
    }
}

enum ListKind: String {
    case notes, todos, transactions, stickies
}

/// Where one filed item lives, so the chat can jump to it.
struct ChangeLink: Equatable, Hashable {
    enum Kind: String { case notes, todos, transactions, stickies, budget }
    var kind: Kind
    var id: String
}

struct ApplyResult {
    var filed: [String] = []
    /// Same order and length as `filed`.
    var links: [ChangeLink?] = []
    var transactionIds: [String] = []
    /// Everything created/changed, so the UI can highlight it.
    var created: [ChangeLink] = []
}
