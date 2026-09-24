import Foundation

// Converts between a note's two forms:
//   content — plain text with light markdown ("☐ task", "• item", "# Heading").
//             Search, the assistant, the daily brief and older notes all use this.
//   html    — rich text from the editor. Only the editor reads it.
// Ported from src/lib/noteText.ts.

enum NoteText {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// **bold** and *italic*, the only inline markdown the assistant writes.
    private static func inline(_ s: String) -> String {
        var out = esc(s)
        out = out.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>",
                                       options: .regularExpression)
        out = out.replacingOccurrences(of: "(^|[^*\\w])\\*(?!\\s)([^*]+?)\\*(?!\\*)",
                                       with: "$1<em>$2</em>", options: .regularExpression)
        return out
    }

    private struct Block {
        enum Kind: String { case ul, ol, task }
        var kind: Kind
        var items: [(text: String, checked: Bool)] = []
    }

    /// The plain-text form converted to the HTML the editor reads.
    static func plainToHtml(_ text: String) -> String {
        var out: [String] = []
        var list: Block?

        func flush() {
            guard let block = list else { return }
            switch block.kind {
            case .task:
                let items = block.items.map {
                    "<li data-type=\"taskItem\" data-checked=\"\($0.checked ? "true" : "false")\"><p>\(inline($0.text))</p></li>"
                }.joined()
                out.append("<ul data-type=\"taskList\">\(items)</ul>")
            case .ul, .ol:
                let items = block.items.map { "<li><p>\(inline($0.text))</p></li>" }.joined()
                out.append("<\(block.kind.rawValue)>\(items)</\(block.kind.rawValue)>")
            }
            list = nil
        }

        func add(_ kind: Block.Kind, _ item: (text: String, checked: Bool)) {
            if list?.kind != kind { flush() }
            if list == nil { list = Block(kind: kind) }
            list?.items.append(item)
        }

        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for raw in normalised.components(separatedBy: "\n") {
            let line = String(raw.reversed().drop { $0 == " " || $0 == "\t" }.reversed())

            if let m = line.firstMatch(of: /^\s*(☐|☑|\[ \]|\[[xX]\])\s*(.*)$/) {
                let marker = String(m.1)
                add(.task, (text: String(m.2),
                            checked: marker == "☑" || marker.lowercased().contains("x")))
            } else if line.range(of: "^\\s*[-*]{2,}", options: .regularExpression) == nil,
                      let m = line.firstMatch(of: /^\s*[-•*](?:\s+(.*))?$/) {
                add(.ul, (text: m.1.map(String.init) ?? "", checked: false))
            } else if let m = line.firstMatch(of: /^\s*\d+[.)](?:\s+(.*))?$/) {
                add(.ol, (text: m.1.map(String.init) ?? "", checked: false))
            } else {
                flush()
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                if let m = line.firstMatch(of: /^(#{1,3})\s+(.*)$/) {
                    let level = m.1.count
                    out.append("<h\(level)>\(inline(String(m.2)))</h\(level)>")
                } else if line.range(of: "^\\s*(-{3,}|_{3,}|\\*{3,})\\s*$",
                                     options: .regularExpression) != nil {
                    out.append("<hr>")
                } else if let m = line.firstMatch(of: /^>\s?(.*)$/) {
                    out.append("<blockquote><p>\(inline(String(m.1)))</p></blockquote>")
                } else {
                    out.append("<p>\(inline(line))</p>")
                }
            }
        }
        flush()
        return out.joined()
    }

    /// A short preview line for the note list.
    static func snippet(_ content: String, max: Int = 140) -> String {
        var s = content.replacingOccurrences(of: "^#+\\s*", with: "",
                                             options: [.regularExpression])
        s = s.replacingOccurrences(of: "(?m)^#+\\s*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[☐☑•>]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    /// The checklist items in a note's plain text, so ticking a box can keep a
    /// linked to-do in step.
    static func taskStates(_ content: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for line in content.components(separatedBy: "\n") {
            guard let m = line.firstMatch(of: /^\s*(☐|☑)\s*(.*)$/) else { continue }
            let title = String(m.2).replacingOccurrences(of: "⏰", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { out[title] = String(m.1) == "☑" }
        }
        return out
    }

    // MARK: - Tags

    /// A tag as the web app stores it: no "#", lower case, hyphens for spaces,
    /// at most 30 characters. Nil when nothing is left.
    static func tag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        tag = String(tag.prefix(30))
        return tag.isEmpty ? nil : tag
    }

    /// A note's tags cleaned and without repeats, in their original order.
    /// Tags written by the assistant or another device can arrive as "#Quick"
    /// and "quick" — the same tag, which used to show twice and confuse the
    /// row that draws them.
    static func tags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap(tag).filter { seen.insert($0).inserted }
    }
}
