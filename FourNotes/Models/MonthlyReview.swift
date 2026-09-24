import Foundation

// The monthly review, with its figures from the app rather than the model.
// Small models add badly: the on-device one reported a month's total as
// Rp 350,000 when it was Rp 3,591,500, and listed every category as a line.
// The app writes the total and the top categories; the model keeps what
// needs judgement — what looks unusual, and a tip.

enum MonthlyReview {
    static func compose(_ written: String, total: Double, byCategory: [String: Double],
                        currency: String) -> String {
        var lines = ["- Total: \(Money.format(total, currency))"]
        let top = byCategory.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(3)
        if !top.isEmpty {
            lines.append("- Top categories: "
                + top.map { "\($0.key) \(Money.format($0.value, currency, compact: true))" }.joined(separator: ", "))
        }
        lines += judgement(in: written, categories: Array(byCategory.keys))
        return lines.joined(separator: "\n")
    }

    /// The model's lines that are judgement — "Unusual: …", "Tip: …" — or a
    /// plain sentence with no figures in it. A labelled line with an amount
    /// ("Internet: Rp 350,000 (twice)") is the model redoing the maths.
    static func judgement(in written: String, categories: [String]) -> [String] {
        let judgementLabels = ["unusual", "notable", "watch", "note", "tip", "saving", "suggest", "advice",
                               "insight", "trend", "alert", "idea"]
        return ModelText.clean(written).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^([-•*]|\\d+[.)])\\s+", with: "", options: .regularExpression) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let hasFigure = line.range(of: "\\d", options: .regularExpression) != nil
                guard let colon = line.firstIndex(of: ":") else { return !hasFigure }
                let label = line[..<colon].lowercased().replacingOccurrences(of: "*", with: "")
                return judgementLabels.contains { label.contains($0) }
            }
            .prefix(3)
            .map { "- " + $0 }
    }
}
