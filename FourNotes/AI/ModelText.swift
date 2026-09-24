import Foundation

// Cleaning up what free and open models write, and the data-only versions
// used when what they wrote isn't usable. Some put their chain of thought in
// the reply, tagged (<think>) or not ("Here's a thinking process: …"); some
// describe a tool call in prose instead of making it.
// Ported from src/lib/ai/text.ts, openrouter.ts and local.ts.

enum ModelText {
    /// Removes <think> blocks, including an unterminated one or a stray closing tag.
    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "^[\\s\\S]*?</think>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<think>[\\s\\S]*?(</think>|$)", with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let thinking = try! NSRegularExpression(pattern: [
        "thinking process",
        "analy[sz]e the (request|data|prompt)",
        "deconstruct the",
        "^\\s*[-*\\d.)\\s]*\\**constraints?:",
        "\\bthe user (wants|asked|is asking)\\b",
        "\\blet me (think|analy[sz]e|draft)\\b",
        "\\bdraft(ing)? (the|a|an) (response|answer|brief)\\b",
        "\\boutput format:",
    ].joined(separator: "|"), options: [.caseInsensitive, .anchorsMatchLines])

    /// Text that reads like a model reasoning about the task rather than doing it.
    static func looksLikeThinking(_ text: String) -> Bool {
        thinking.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let planning: NSRegularExpression = {
        let tools = (AITools.actionTools + [AITools.captureTool]).compactMap { $0["name"] as? String }
        let names = (tools.isEmpty ? ["create_todo", "create_note", "add_transaction", "file_capture"] : tools)
            .joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(\(names)|dueAt|remindAt|tool_calls?|function call)\\b",
                                        options: .caseInsensitive)
    }()

    private static let toolLabel: NSRegularExpression = {
        let tools = (AITools.actionTools + [AITools.captureTool]).compactMap { $0["name"] as? String }
        let names = (tools.isEmpty ? ["create_todo", "create_note", "add_transaction", "file_capture"] : tools)
            .joined(separator: "|")
        // Its tool names, or a slash command it made up: "/todo:", "/note:".
        return try! NSRegularExpression(pattern: "^[ \\t]*[`*]*(\(names)|/[a-z_]{2,20})[`*]*[ \\t]*[:：][ \\t]*",
                                        options: [.caseInsensitive, .anchorsMatchLines])
    }()

    /// "create_todo: Pay internet bill…" → "Pay internet bill…": the on-device
    /// model sometimes writes a tool's name into an answer it should only say.
    static func withoutToolLabels(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let out = toolLabel.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        guard let first = out.first, first.isLowercase, out != text else { return out }
        return first.uppercased() + out.dropFirst()
    }

    /// A "reply" that is the model talking through a tool call instead of making it.
    static func looksLikePlanning(_ text: String) -> Bool {
        planning.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Appended to plain-text prompts; pairs with `extractAnswer`.
    static let answerInstruction =
        "Reply with only the final text inside <answer></answer> tags. Do not explain your reasoning or restate these instructions."

    /// The last <answer> block if there is one, otherwise the cleaned text.
    static func extractAnswer(_ raw: String) -> String {
        let blocks = raw.matches(of: /(?i)<answer>([\s\S]*?)(?:<\/answer>|$)/)
        return clean(blocks.last.map { String($0.1) } ?? raw)
    }

    /// The brief's three emoji lines, or nil if the text isn't a usable brief.
    /// The last ones, since a model that drafts first writes its final lines last.
    static func briefLines(_ text: String) -> [String]? {
        let lines = text.split(separator: "\n").map { line in
            String(line)
                .replacingOccurrences(of: "^[\\s>*•\\-\\d.)]+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
        }.filter { line in
            line.range(of: "^\\p{Extended_Pictographic}", options: .regularExpression) != nil
                && line.count <= 240 && !looksLikeThinking(line)
        }
        return lines.count >= 3 ? Array(lines.suffix(3)) : nil
    }

    /// JSON from a model's text: bare, or wrapped in prose or ``` fences.
    static func json(_ text: String) -> [String: Any]? {
        func parse(_ s: Substring) -> [String: Any]? {
            s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        if let object = parse(Substring(text)) { return object }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return parse(text[start...end])
    }

    /// Some models reject JSON Schema union types like ["string", "null"].
    static func simplifySchema(_ schema: Any) -> Any {
        if let array = schema as? [Any] { return array.map(simplifySchema) }
        guard let object = schema as? [String: Any] else { return schema }
        var out: [String: Any] = [:]
        for (key, value) in object {
            if key == "type", let types = value as? [String] {
                out[key] = types.first { $0 != "null" } ?? "string"
            } else {
                out[key] = simplifySchema(value)
            }
        }
        return out
    }

    /// "Done: 1 to-do, 2 transactions." — a reply built from what was saved.
    static func describe(_ actions: [AIAction]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for action in actions {
            let key = noun(action)
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let parts = order.map { key -> String in
            let n = counts[key] ?? 0
            let (one, many) = nouns[key] ?? ("item", "items")
            return "\(n) \(n == 1 ? one : many)"
        }
        return "Done: \(parts.joined(separator: ", "))."
    }

    private static let nouns: [String: (String, String)] = [
        "todo": ("to-do", "to-dos"), "complete": ("task marked done", "tasks marked done"),
        "start": ("task started", "tasks started"), "note": ("note", "notes"),
        "transaction": ("transaction", "transactions"), "split": ("split", "splits"),
        "budget": ("budget", "budgets"), "sticky": ("quick note", "quick notes"),
    ]

    private static func noun(_ action: AIAction) -> String {
        switch action {
        case .createTodo: return "todo"
        case .completeTodo: return "complete"
        case .startTodo: return "start"
        case .createNote: return "note"
        case .addTransaction: return "transaction"
        case .splitTransaction: return "split"
        case .setBudget: return "budget"
        case .createSticky: return "sticky"
        }
    }
}

// MARK: - Written from the data alone

/// The brief and the review with no model at all: what the app falls back to
/// when a model's answer isn't usable. Ported from src/lib/ai/local.ts.
enum LocalSummaries {
    static func brief(_ input: BriefInput) -> String {
        let tasks = input.tasksToday
        let overdue = tasks.filter(\.overdue).count
        let spent = input.yesterdaySpend.reduce(0) { $0 + max(0, $1.amount) }
        let count = input.yesterdaySpend.count
        let first = tasks.isEmpty
            ? "No tasks due today. A good day to plan ahead."
            : "\(tasks.count) task\(tasks.count == 1 ? "" : "s") today\(overdue > 0 ? ", \(overdue) overdue" : ""). Start with “\(tasks[0].title)”."
        let second = count > 0
            ? "Yesterday you spent \(Money.format(spent, input.currency)) across \(count) transaction\(count == 1 ? "" : "s")."
            : "No spending recorded yesterday."
        let third = input.alerts.first ?? input.stickies.first ?? "Nothing urgent. Have a good day!"
        return "🎯 \(first)\n💸 \(second)\n📌 \(third)"
    }

    static func monthly(month: String, currency: String, transactions: [Transaction]) -> String {
        var byCategory: [String: Double] = [:]
        var total = 0.0
        for t in transactions where t.amount > 0 {
            total += t.amount
            byCategory[t.category, default: 0] += t.amount
        }
        let top = byCategory.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key) \(Money.format($0.value, currency))" }
        return "\(month): spent \(Money.format(total, currency)).\nTop: \(top.isEmpty ? "—" : top.joined(separator: ", "))."
    }
}
