import Foundation

// Turning an assistant reply into a note — as it was shown, not rewritten.
//
// "yea save that" used to go to the model like any other message. The local
// model sees only the last exchange, so it wrote a new note from its own
// memory of the conversation: a cloud model's itinerary came out as a garbled
// copy of the user's note, cut off mid-word. Saving a reply is not a job for a
// model; the app saves the exact text, with the chat's Markdown turned into
// the note format.

enum ReplyNote {
    /// Worth a "Save as note" button: more than a line or two.
    static func isWorthSaving(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines).count >= 160
    }

    /// The reply as note text: Markdown turned into the note's own form, and
    /// the closing offer ("Would you like me to…") left out.
    static func content(fromReply reply: String) -> String {
        var lines = reply.components(separatedBy: .newlines)
        // The offer at the end is chat, not content: cut from where it starts,
        // in the second half of the reply.
        if let offer = lines.indices.first(where: { $0 >= lines.count / 2 && isClosingOffer(lines[$0]) }) {
            lines = Array(lines[..<offer])
        }
        // A trailing divider or blank lines left behind by the cut.
        while let last = lines.last?.trimmingCharacters(in: .whitespaces),
              last.isEmpty || last.firstMatch(of: /^(-{3,}|_{3,}|\*{3,})$/) != nil {
            lines.removeLast()
        }
        return noteText(fromMarkdown: lines.joined(separator: "\n"))
    }

    /// Chat Markdown in the note's plain-text form: headings and lists kept,
    /// emphasis markers dropped, tables as "a — b" bullets.
    static func noteText(fromMarkdown markdown: String) -> String {
        var out: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // Tables: the separator row goes, each other row becomes a bullet.
            if trimmed.hasPrefix("|") {
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } }) { continue }
                out.append("• " + cells.map(inline).joined(separator: " — "))
                continue
            }
            let indent = String(raw.prefix { $0 == " " })
            if let bullet = trimmed.firstMatch(of: /^[-*+]\s+(.*)$/) {
                out.append(indent + "• " + inline(String(bullet.1)))
            } else if let heading = trimmed.firstMatch(of: /^#{4,6}\s+(.*)$/) {
                out.append("### " + inline(String(heading.1)))
            } else {
                out.append(indent + inline(trimmed))
            }
        }
        // No more than one blank line in a row.
        var collapsed: [String] = []
        for line in out where !(line.isEmpty && collapsed.last?.isEmpty == true) {
            collapsed.append(line)
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bold, italic and code markers removed; the words stay.
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "(\\*\\*|__)(.+?)\\1", with: "$2", options: .regularExpression)
            .replacingOccurrences(of: "(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
    }

    /// The reply ends by offering to save itself: "Want me to create a note…?",
    /// "Shall I save this itinerary?" — so a "yes" means saving it.
    static func offersToSave(_ reply: String) -> Bool {
        let lines = reply.components(separatedBy: .newlines)
        guard let offer = lines.indices.first(where: { $0 >= lines.count / 2 && isClosingOffer(lines[$0]) }) else {
            return false
        }
        return lines[offer...].joined(separator: " ")
            .range(of: "\\b(save|create|make|put|keep|add)\\b.{0,40}\\b(note|notes|this|it|that|itinerary|list|plan)\\b|"
                   + "simpan|catatan",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isClosingOffer(_ line: String) -> Bool {
        line.range(of: "^\\W*(would you like|do you want|want me to|let me know|shall i|should i|"
                   + "anything else|mau saya|apakah (anda|kamu) mau)",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A title for a saved reply, best source first: a heading in the reply;
    /// the reply's own opening ("Here's a recommended 5-day Japan itinerary for
    /// October — …" is "5-day Japan itinerary for October"); the question it
    /// answered ("any recommendation for a rainy weekend in Bandung?" is "A
    /// rainy weekend in Bandung"); its first line.
    static func title(reply: String, question: String?) -> String {
        if let heading = reply.components(separatedBy: .newlines)
            .compactMap({ $0.firstMatch(of: /^#{1,3}\s+(.+)$/).map { inline(String($0.1)) } }).first {
            return shortened(heading)
        }
        if let lead = leadPhrase(reply) { return shortened(lead) }
        if let question {
            let topic = question
                .replacingOccurrences(
                    of: "^\\W*(hi|hey|please|pls|tolong)?\\W*(can you |could you )?"
                        + "(give me |show me |i need |i want |what are |make me |plan |recommend |suggest )?"
                        + "(me )?(any |some |a few |good |the best |an? )?"
                        + "(recommendations?|suggestions?|ideas?|tips?|advice|rekomendasi|saran|ide)?\\s*"
                        + "(for|on|about|untuk|buat|tentang)?\\s*",
                    with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,"))
            if topic.split(separator: " ").count >= 2 { return shortened(topic) }
        }
        let first = reply.components(separatedBy: .newlines)
            .map { inline($0).trimmingCharacters(in: CharacterSet(charactersIn: " :#*•-")) }
            .first { !$0.isEmpty } ?? "Saved from chat"
        // "Plan for Saturday: rest." — the part before the colon names it.
        if let lead = first.split(separator: ":").first, lead.split(separator: " ").count >= 2 {
            return shortened(String(lead))
        }
        return shortened(first)
    }

    /// What a reply says it is, from its first line: "Here's a recommended
    /// Bandung itinerary you can adapt…" → "Bandung itinerary".
    private static func leadPhrase(_ reply: String) -> String? {
        guard let first = reply.components(separatedBy: .newlines)
            .map({ inline($0).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }),
              let match = first.firstMatch(
                of: /(?i)^(?:here's|here is|here are|below is|this is)\s+(?:a |an |your |some |the )?(?:recommended |suggested |quick |simple |relaxed |detailed |sample |possible )?(.+)$/)
        else { return nil }
        var phrase = String(match.1)
        // Stop at the first break — "— great weather", ":", "." — and before a
        // clause about the reader ("you can adapt…", "that fits…").
        for stop in [" — ", " – ", " - ", ":", ". ", "!", ", "] {
            if let range = phrase.range(of: stop) { phrase = String(phrase[..<range.lowerBound]) }
        }
        if let clause = phrase.range(of: " (you|that|which|to help|for you|i ) ?", options: [.regularExpression, .caseInsensitive]) {
            phrase = String(phrase[..<clause.lowerBound])
        }
        phrase = phrase.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
        return phrase.split(separator: " ").count >= 2 ? phrase : nil
    }

    private static func shortened(_ text: String) -> String {
        let words = text.split(separator: " ").prefix(8).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :.,!?"))
        guard let first = words.first else { return "Saved from chat" }
        return first.uppercased() + words.dropFirst()
    }
}
