import Foundation

// Quick notes: short jottings written on Today (they replaced stickies). Each one is
// a normal note tagged "quick", titled from its first line, so it shows up in Notes too.

enum QuickNote {
    static let tag = "quick"

    static func apply(_ text: String, to note: inout Note) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = title(for: clean)
        note.content = clean
        note.tags = [tag]
    }

    /// The first line, shortened.
    static func title(for text: String) -> String {
        let first = (text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return first.count > 60
            ? String(first.prefix(57)).trimmingCharacters(in: .whitespaces) + "…"
            : first
    }

    static func isQuick(_ n: Note) -> Bool { n.tags.contains(tag) }
}
