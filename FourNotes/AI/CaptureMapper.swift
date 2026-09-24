import Foundation

// Converts the forced `file_capture` tool output into app actions.
// Ported from captureToActions() / receiptFields() in src/lib/ai/provider.ts.

enum CaptureMapper {
    /// Totals arrive as numbers, or as text like "128.500" / "Rp 128.500"
    /// (which a plain Double() would read as 128.5).
    private static func amount(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Int { return Double(n) }
        if let s = value as? String { return Money.parse(s) }
        return nil
    }

    struct ReceiptFields {
        var merchant: String?
        var total: Double?
        var currency: String?
        var date: String?
        var category: String?
        var items: [[String: Any]]
    }

    /// The receipt's fields, from `receipt` or, for models that flatten the
    /// object, from the top level.
    static func receiptFields(_ input: [String: Any]) -> ReceiptFields {
        var merged = input
        if let nested = input["receipt"] as? [String: Any] {
            for (k, v) in nested { merged[k] = v }
        }
        let merchant = (merged["merchant"] as? String)?.trimmingCharacters(in: .whitespaces)
        return ReceiptFields(
            merchant: merchant?.isEmpty == true ? nil : merchant,
            total: amount(merged["total"] ?? merged["amount"]),
            currency: merged["currency"] as? String,
            date: merged["date"] as? String,
            category: merged["category"] as? String,
            items: merged["items"] as? [[String: Any]] ?? [])
    }

    static func toActions(_ input: [String: Any], ctx: ClientContext) -> CaptureResult {
        let kindRaw = input["kind"] as? String ?? "other"
        let kind = CaptureResult.Kind(rawValue: kindRaw) ?? .other
        var reply = input["reply"] as? String ?? "Filed it."
        var raw: [[String: Any]] = []

        if kind == .receipt {
            let r = receiptFields(input)
            if let merchant = r.merchant, let total = r.total {
                // A date the app can actually read, or today in the user's own
                // timezone — not the first ten characters of a UTC timestamp,
                // which lands in the previous month before 07:00 in Jakarta.
                let isoDate = r.date.flatMap { DateKit.date($0) != nil ? $0 : nil }
                    ?? DateKit.localDate()
                // A model will happily answer "US Dollar" or invent a category.
                // Both are normalised here: an unknown currency reaches a URL,
                // and an unknown category matches no budget, chart or filter.
                let currency = r.currency.flatMap { FXRates.isCurrencyCode($0) ? $0 : nil }
                    ?? ctx.currency
                raw.append([
                    "type": "add_transaction",
                    "merchant": merchant,
                    "amount": total,
                    "currency": currency,
                    "category": Store.matchCategory(r.category, ctx.categories),
                    "date": isoDate,
                    "items": r.items,
                ])
            } else {
                reply = "I could read this receipt but not its total, so nothing was saved. "
                    + "Try a clearer photo, or type the amount in the chat."
            }
            // Receipts have line items, not tasks: some models put the items in `todos`.
            return CaptureResult(kind: kind, reply: reply, actions: AITools.decodeActions(raw))
        }

        let note = input["note"] as? [String: Any]
        if let note, let title = note["title"] as? String, let content = note["content"] as? String {
            raw.append([
                "type": "create_note",
                "title": title,
                "content": content,
                "tags": note["tags"] as? [String] ?? [],
                "ref": "capture",
            ])
        }

        for todo in input["todos"] as? [[String: Any]] ?? [] {
            guard let title = todo["title"] as? String else { continue }
            var action: [String: Any] = ["type": "create_todo", "title": title]
            // Only a date the app can actually read: a shape check would let
            // "2026-13-45" through, and the task would then be invisible.
            let dueAt = (todo["dueAt"] as? String).flatMap { DateKit.date($0) != nil ? $0 : nil }
            let rrule = Recurrence.normalised(todo["rrule"] as? String,
                                              anchoredTo: DateKit.date(dueAt))
            if let dueAt {
                action["dueAt"] = rrule.map { Recurrence.next(after: dueAt, $0) } ?? dueAt
                action["remindAt"] = action["dueAt"]
            }
            if let priority = todo["priority"] as? String { action["priority"] = priority }
            if let rrule { action["rrule"] = rrule }
            if note != nil { action["noteRef"] = "capture" }
            raw.append(action)
        }

        return CaptureResult(kind: kind, reply: reply, actions: AITools.decodeActions(raw))
    }
}
