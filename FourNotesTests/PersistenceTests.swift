import Foundation
import Testing
@testable import FourNotes

// The document on disk. Every failure here is measured in lost user data, so
// these are the tests that matter most.

@Suite("AppData decoding")
struct AppDataDecodingTests {

    private func decode(_ json: String) throws -> AppData {
        try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
    }

    @Test("a good document round-trips")
    func roundTrip() throws {
        var data = AppData()
        data.notes = [Note(id: "n1", createdAt: "2026-09-01T00:00:00.000Z",
                           updatedAt: "2026-09-01T00:00:00.000Z", title: "Hello")]
        data.settings.currency = "IDR"

        let encoded = try Persistence.shared.encode(data)
        let back = try JSONDecoder().decode(AppData.self, from: encoded)
        #expect(back.notes.count == 1)
        #expect(back.notes.first?.title == "Hello")
        #expect(back.settings.currency == "IDR")
    }

    @Test("one unreadable row does not discard the rest")
    func oneBadRowKeepsTheRest() throws {
        // Swift decodes arrays all-or-nothing, so without per-element handling
        // a single bad note empties the whole collection — and the next save
        // writes that loss to disk.
        let json = """
        {"notes":[
          {"id":"a","createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z",
           "title":"Keep me","content":"","source":"manual","tags":[]},
          {"id":"b","createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z",
           "title":"Bad source","content":"","source":"carrier-pigeon","tags":[]},
          {"id":"c","createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z",
           "title":"Keep me too","content":"","source":"manual","tags":[]}
        ]}
        """
        let data = try decode(json)
        #expect(data.notes.count == 2, "lost good rows alongside the bad one")
        #expect(data.notes.map(\.title) == ["Keep me", "Keep me too"])
        #expect(data.skippedRows == 1, "the skipped row should be reported, not hidden")
    }

    @Test("a missing key is not a failure")
    func missingKeys() throws {
        let data = try decode(#"{"notes":[]}"#)
        #expect(data.todos.isEmpty)
        #expect(data.settings.currency == "IDR")
        #expect(data.skippedRows == 0)
    }
}

@Suite("Persistence")
struct PersistenceTests {

    private func temporaryStore() -> (Persistence, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fournotes-test-\(UUID().uuidString).json")
        return (Persistence(fileURL: url), url)
    }

    @Test("saving then loading returns the same document")
    func saveLoad() async throws {
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var data = AppData()
        data.todos = [Todo(id: "t1", createdAt: "2026-09-01T00:00:00.000Z",
                           updatedAt: "2026-09-01T00:00:00.000Z", title: "Buy milk")]
        try store.saveNow(data)

        let loaded = try #require(store.load())
        #expect(loaded.todos.first?.title == "Buy milk")
    }

    @Test("an immediate save cannot be overwritten by an older queued save")
    func immediateSaveWins() throws {
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var queued = AppData()
        queued.notes = [Note(id: "old", createdAt: DateKit.nowIso(), updatedAt: DateKit.nowIso(),
                             title: "queued",
                             content: String(repeating: "stale data ", count: 500_000))]
        store.save(queued)

        var immediate = AppData()
        immediate.notes = [Note(id: "new", createdAt: DateKit.nowIso(), updatedAt: DateKit.nowIso(),
                                title: "flushed")]
        try store.saveNow(immediate)

        let loaded = try #require(store.load())
        #expect(loaded.notes.first?.id == "new",
                "the older background snapshot finished after the flush")
    }

    @Test("a non-finite amount does not silently disable saving")
    func nonFiniteAmount() throws {
        // JSONEncoder throws on NaN and infinity. Swallowing that error meant
        // every later save became a no-op — for this session and every one after.
        let (store, url) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        var data = AppData()
        data.transactions = [Transaction(id: "x1", createdAt: "2026-09-01T00:00:00.000Z",
                                         updatedAt: "2026-09-01T00:00:00.000Z",
                                         merchant: "Broken", amount: .nan,
                                         date: "2026-09-01")]
        // Either the document is sanitised and saves, or the failure is raised —
        // but it must never be swallowed.
        var raised = false
        do { try store.saveNow(data) } catch { raised = true }

        if !raised {
            let loaded = try #require(store.load(), "saved but could not be read back")
            #expect(loaded.transactions.first?.amount.isFinite == true)
        }
    }

    @Test("an unreadable file is kept, not overwritten")
    func corruptFileIsPreserved() throws {
        let (store, url) = temporaryStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: store.backupLocation)
        }
        try Data("this is not json".utf8).write(to: url)

        #expect(store.load() == nil)
        #expect(FileManager.default.fileExists(atPath: store.backupLocation.path),
                "a document we could not read must be backed up before anything overwrites it")
    }

    @Test("a document that can't be read is never saved over")
    @MainActor
    func unreadableIsNotOverwritten() throws {
        let (persistence, url) = temporaryStore()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: persistence.backupLocation)
        }
        let original = Data("{ not valid json".utf8)
        try original.write(to: url)

        let store = Store(persistence: persistence)
        #expect(!store.needsOnboarding, "an unreadable document is not a new install")
        #expect(store.saveFailure != nil)
        store.addNote { $0.title = "typed after launch" }
        #expect(store.flush() == false)
        #expect(try Data(contentsOf: url) == original)
    }
}
