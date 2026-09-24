import Testing
@testable import FourNotes

@Suite("Search")
struct SearchTests {

    private func note(_ id: String, _ title: String, _ content: String = "") -> Note {
        Note(id: id, createdAt: "2026-09-01T00:00:00.000Z",
             updatedAt: "2026-09-01T00:00:00.000Z", title: title, content: content)
    }

    @Test("finds an exact word")
    func exactWord() {
        let notes = [note("1", "Bali trip"), note("2", "Groceries")]
        let hits = Search.keyword(notes: notes, todos: [], transactions: [], query: "bali")
        #expect(hits.count == 1)
    }

    @Test("prefix matching finds the word it starts")
    func prefix() {
        let notes = [note("1", "Bali trip"), note("2", "Groceries")]
        #expect(!Search.keyword(notes: notes, todos: [], transactions: [], query: "bal").isEmpty)
    }

    @Test("more matches must not mean fewer results")
    func manyMatchesStillRank() {
        // The idf term summed document frequencies across every prefix-matched
        // word, so several such words in each note pushed `n` above the corpus
        // size, made idf negative, and every hit was filtered out. The effect
        // was that the better a query matched, the less it found.
        let notes = [
            note("1", "Balance sheet", "balance balancing balanced balances"),
            note("2", "Bank balance", "balance balancing balanced balloon"),
            note("3", "Balanced diet", "balance balanced ballet balloon"),
            note("4", "Ballet class", "ballet balancing balloon balances"),
        ]
        let hits = Search.keyword(notes: notes, todos: [], transactions: [], query: "bal")
        #expect(hits.count == 4, "every note contains the prefix, found \(hits.count)")
        #expect(hits.allSatisfy { $0.score > 0 }, "a matching note scored zero or negative")
    }

    @Test("scores are never negative")
    func nonNegative() {
        let notes = (1...20).map { note("\($0)", "meeting notes \($0)", "meeting meeting meeting") }
        for hit in Search.keyword(notes: notes, todos: [], transactions: [], query: "meeting") {
            #expect(hit.score > 0)
        }
    }

    @Test("an empty query finds nothing")
    func emptyQuery() {
        #expect(Search.keyword(notes: [note("1", "Bali")], todos: [], transactions: [],
                               query: "").isEmpty)
    }
}
