import Foundation

// Search across notes, tasks and spending. Keyword ranking (BM25) always works,
// offline too. Ported from src/lib/search.ts; the embedding blend stays on the
// hosted side, so the Mac app ranks locally and sends the top notes as context.

enum SearchHit: Identifiable {
    case note(Note, score: Double)
    case todo(Todo, score: Double)
    case transaction(Transaction, score: Double)

    var id: String {
        switch self {
        case .note(let n, _): return "note-" + n.id
        case .todo(let t, _): return "todo-" + t.id
        case .transaction(let t, _): return "tx-" + t.id
        }
    }

    var score: Double {
        switch self {
        case .note(_, let s), .todo(_, let s), .transaction(_, let s): return s
        }
    }

    var link: ChangeLink {
        switch self {
        case .note(let n, _): return ChangeLink(kind: .notes, id: n.id)
        case .todo(let t, _): return ChangeLink(kind: .todos, id: t.id)
        case .transaction(let t, _): return ChangeLink(kind: .transactions, id: t.id)
        }
    }
}

enum Search {
    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    /// BM25 with prefix matching, so "bal" finds "bali".
    static func bm25(_ docs: [String], _ query: String) -> [Double] {
        let q = tokenize(query)
        guard !q.isEmpty else { return docs.map { _ in 0 } }
        let toks = docs.map(tokenize)
        let avg = Double(toks.reduce(0) { $0 + $1.count }) / Double(max(1, toks.count))

        func matches(_ word: String, _ term: String) -> Bool {
            word == term || (term.count >= 3 && word.hasPrefix(term))
        }

        // Document frequency per query term: how many *documents* contain a word
        // the term matches. Summing the frequencies of every matching word
        // instead would count one document several times, push the count past
        // the corpus size, and make idf negative — at which point a real match
        // scores below zero and is dropped. Searching for a common prefix then
        // returned nothing at all.
        var documentFrequency: [String: Int] = [:]
        for term in Set(q) {
            documentFrequency[term] = toks.reduce(0) { count, doc in
                count + (doc.contains { matches($0, term) } ? 1 : 0)
            }
        }

        let total = Double(toks.count)
        return toks.map { t in
            var score = 0.0
            for term in q {
                let tf = Double(t.filter { matches($0, term) }.count)
                guard tf > 0 else { continue }
                let n = Double(documentFrequency[term] ?? 0)
                // Standard BM25 idf, which stays positive because n <= total.
                let idf = log(1 + (total - n + 0.5) / (n + 0.5))
                score += idf * ((tf * 2.2) / (tf + 1.2 * (0.25 + 0.75 * (Double(t.count) / avg))))
            }
            return score
        }
    }

    static func keyword(notes: [Note], todos: [Todo], transactions: [Transaction],
                        query: String, limit: Int = 12) -> [SearchHit] {
        let docs =
            notes.map { "\($0.title) \($0.title) \($0.tags.joined(separator: " ")) \($0.content)" }
            + todos.map { "\($0.title) \($0.notes ?? "")" }
            + transactions.map { "\($0.merchant) \($0.category) \($0.items.map(\.name).joined(separator: " "))" }

        let scores = bm25(docs, query)
        var hits: [SearchHit] = []
        for (i, n) in notes.enumerated() { hits.append(.note(n, score: scores[i])) }
        for (i, t) in todos.enumerated() { hits.append(.todo(t, score: scores[notes.count + i])) }
        for (i, t) in transactions.enumerated() {
            hits.append(.transaction(t, score: scores[notes.count + todos.count + i]))
        }
        return hits.filter { $0.score > 0 }.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// The notes to send with a chat message: the ones it names outright plus
    /// the best keyword matches.
    static func relevantNotes(for text: String, in notes: [Note], openNoteId: String?, limit: Int = 5) -> [Note] {
        var out: [Note] = []

        // A quoted title always goes in full, as does "this note" for the open one.
        let quoted = text.matches(of: /[“"«]([^”"»]{1,120})[”"»]/).map {
            String($0.1).trimmingCharacters(in: .whitespaces).lowercased()
        }
        for title in quoted {
            let hits = notes.filter { ($0.title.trimmingCharacters(in: .whitespaces).isEmpty ? "untitled" : $0.title)
                .lowercased() == title }
            if let pick = hits.first(where: { $0.id == openNoteId }) ?? hits.first,
               !out.contains(where: { $0.id == pick.id }) {
                out.append(pick)
            }
        }
        if let openNoteId, text.range(of: "\\bthis note\\b", options: [.regularExpression, .caseInsensitive]) != nil,
           let n = notes.first(where: { $0.id == openNoteId }), !out.contains(where: { $0.id == n.id }) {
            out.insert(n, at: 0)
        }

        let candidates = notes.filter { !$0.title.isEmpty || !$0.content.isEmpty }
        let scores = bm25(candidates.map { "\($0.title) \($0.title) \($0.content)" }, text)
        let ranked = zip(candidates, scores)
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        for n in ranked where !out.contains(where: { $0.id == n.id }) {
            if out.count >= limit { break }
            out.append(n)
        }
        return Array(out.prefix(limit))
    }
}
