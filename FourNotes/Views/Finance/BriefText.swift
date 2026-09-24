import SwiftUI

// A model's review, laid out rather than shown raw. It writes lines like
// "- Total: 3,975,000 IDR" and "- Saving tip: …"; each becomes a row with an
// icon, a small label and the text, with amounts in the app's money format.

struct BriefText: View {
    @Environment(\.palette) private var p
    let text: String
    let currency: String

    struct Line: Identifiable, Sendable {
        var id: Int
        var label: String?
        var body: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.lines(text, currency: currency)) { line in
                HStack(alignment: .top, spacing: 10) {
                    Icon(Self.icon(for: line.label ?? line.body), size: 13)
                        .foregroundStyle(p.accent)
                        .frame(width: 26, height: 26)
                        .background(p.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        if let label = line.label {
                            Text(label)
                                .font(FN.font(12, .medium))
                                .foregroundStyle(p.muted)
                        }
                        Text(Self.inline(line.body))
                            .font(.system(size: 14))
                            .foregroundStyle(p.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// The text's lines, bullets stripped, "Label: text" split, amounts formatted.
    nonisolated static func lines(_ text: String, currency: String) -> [Line] {
        let raw = ModelText.clean(text).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^([-•*]|\\d+[.)])\\s+", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        return raw.enumerated().map { index, line in
            let money = amounts(in: line, currency: currency)
            if let match = money.firstMatch(of: /^\**([A-Za-z][\w &\/'’-]{1,28}?)\**\s*:\s*\**\s*(.+)$/) {
                return Line(id: index, label: String(match.1).trimmingCharacters(in: .whitespaces),
                            body: String(match.2))
            }
            return Line(id: index, label: nil, body: money)
        }
    }

    /// "3,975,000 IDR" and "(2,500,000)" in the app's money format.
    nonisolated static func amounts(in line: String, currency: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?:(?:Rp|IDR|\(currency))\\s?)?(\\d{1,3}(?:[,.]\\d{3})+)(?:\\s?(?:IDR|\(currency)))?",
            options: .caseInsensitive) else { return line }
        // Replaced from the end, in an NSMutableString: its ranges stay valid
        // as the text before them changes. (String indices don't.)
        let source = line as NSString
        let out = NSMutableString(string: line)
        for match in regex.matches(in: line, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let amount = Money.parse(source.substring(with: match.range(at: 1))) else { continue }
            out.replaceCharacters(in: match.range, with: Money.format(amount, currency))
        }
        return out as String
    }

    private static func icon(for label: String) -> String {
        let l = label.lowercased()
        if l.contains("total") || l.contains("spent") { return "wallet" }
        if l.contains("top") || l.contains("categor") { return "chart" }
        if l.contains("unusual") || l.contains("watch") || l.contains("notable") || l.contains("alert") { return "warning" }
        if l.contains("tip") || l.contains("saving") || l.contains("suggest") || l.contains("advice") { return "sparkle" }
        return "check"
    }

    /// Bold and italic from the model's Markdown, kept; the rest plain.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
