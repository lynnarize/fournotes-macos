import Foundation

// Cleaning up what free models write. Some put their chain of thought in the
// reply, tagged (<think>) or not ("Here's a thinking process: …").
// Ported from src/lib/ai/text.ts.

enum AIText {
    /// Removes <think> blocks, including an unterminated one or a stray closing tag.
    static func clean(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: "^[\\s\\S]*?</think>", with: "", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "<think>[\\s\\S]*?(</think>|$)", with: "", options: [.regularExpression, .caseInsensitive])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let thinkingPattern = [
        "thinking process",
        "analy[sz]e the (request|data|prompt)",
        "deconstruct the",
        "^\\s*[-*\\d.)\\s]*\\**constraints?:",
        "\\bthe user (wants|asked|is asking)\\b",
        "\\blet me (think|analy[sz]e|draft)\\b",
        "\\bdraft(ing)? (the|a|an) (response|answer|brief)\\b",
        "\\boutput format:",
    ].joined(separator: "|")

    /// True when text reads like a model reasoning about the task rather than doing it.
    static func looksLikeThinking(_ text: String) -> Bool {
        text.range(of: thinkingPattern,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The last <answer> block if there is one, otherwise the cleaned text.
    static func extractAnswer(_ raw: String) -> String {
        let matches = raw.matches(of: /(?i)<answer>([\s\S]*?)(?:<\/answer>|$)/)
        return clean(matches.last.map { String($0.1) } ?? raw)
    }

    /// The brief's three emoji lines, or nil if the text isn't a usable brief.
    /// Takes the last ones, since a model that drafts first writes its final lines last.
    static func briefLines(_ text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
            .map { line -> String in
                line.replacingOccurrences(of: "^[\\s>*•\\-\\d.)]+", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "**", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { line in
                guard let first = line.unicodeScalars.first,
                      first.properties.isEmojiPresentation || first.properties.isEmoji,
                      line.count <= 240, !looksLikeThinking(line) else { return false }
                return true
            }
        return lines.count >= 3 ? Array(lines.suffix(3)) : nil
    }

    /// A usable brief as stored text, or false for one written by a model thinking out loud.
    static func isUsableBrief(_ text: String) -> Bool {
        !looksLikeThinking(text) && briefLines(text) != nil
    }
}
