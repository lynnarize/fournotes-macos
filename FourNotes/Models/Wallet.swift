import Foundation

// Rule-based parser for e-wallet and bank notifications (GoPay, OVO, DANA,
// ShopeePay, LinkAja, QRIS, BCA/Mandiri/BRI/BNI/Jago). Used offline and in demo
// mode; with an API key the AI handles any wording, including screenshots.
// Ported from src/lib/wallet.ts.

struct ParsedNotification {
    var merchant: String
    /// Positive = spend, negative = income.
    var amount: Double
    var category: String
    var wallet: String?
}

enum Wallet {
    private static let wallets = ["GoPay", "OVO", "DANA", "ShopeePay", "LinkAja", "QRIS", "BCA",
                                  "Mandiri", "BRI", "BNI", "Jago", "SeaBank", "Blu", "Jenius"]

    private static let categoryHints: [(String, String)] = [
        ("gofood|grabfood|shopeefood|kopi|coffee|starbucks|mcd|kfc|resto|restaurant|warung|warteg|bakso|makan|cafe|lunch|dinner|breakfast|food|meal", "Food & Drink"),
        ("indomaret|alfamart|superindo|hypermart|lotte|grocer|grocery|groceries|supermarket|sayur|pasar", "Groceries"),
        ("gojek|goride|gocar|grab|bluebird|kai|krl|mrt|transjakarta|pertamina|shell|bensin|parkir|tol|e-toll|gas|fuel|parking|taxi|uber|train|bus|toll", "Transport"),
        ("pln|listrik|token|pdam|indihome|biznet|telkomsel|xl|pulsa|paket data|bpjs|internet|electricity|water bill|phone bill|rent|mobile data", "Bills & Utilities"),
        ("tokopedia|shopee|lazada|blibli|zalora|uniqlo", "Shopping"),
        ("netflix|spotify|youtube|disney|vidio|steam|playstation|cinema|xxi|cgv", "Entertainment"),
        ("apotek|kimia farma|halodoc|klinik|hospital|rumah sakit|guardian", "Health"),
    ]

    static func guessCategory(_ text: String) -> String {
        for (pattern, category) in categoryHints
        where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return category
        }
        return "Other"
    }

    static func parseNotification(_ text: String) -> ParsedNotification? {
        let t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard t.range(of: "(rp|idr)\\s?\\.?\\s?\\d", options: [.regularExpression, .caseInsensitive]) != nil,
              let amountRange = t.range(of: "(rp|idr)\\.?\\s?[\\d.,]+",
                                        options: [.regularExpression, .caseInsensitive]),
              let amount = Money.parse(String(t[amountRange])), amount != 0
        else { return nil }

        let income = t.range(
            of: "(diterima|menerima|terima|masuk|received|top ?up berhasil|dana masuk|transfer masuk|kredit|incoming|refund|cashback)",
            options: [.regularExpression, .caseInsensitive]) != nil

        let wallet = wallets.first {
            t.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }

        // "... ke MERCHANT", "to MERCHANT", "di MERCHANT", "at MERCHANT", "dari NAME"
        let who = capture(t, "\\b(?:ke|kepada|to|di|at|merchant:?|dari|from)\\s+([A-Z0-9][\\w&'.-]*(?:\\s+[A-Z0-9][\\w&'.-]*){0,3})", caseSensitive: true)
            ?? capture(t, "\\b(?:ke|kepada|to|di|at|dari|from)\\s+([\\w&'.-]+(?:\\s+[\\w&'.-]+){0,2})", caseSensitive: false)

        var merchant = (who ?? wallet ?? "E-wallet payment")
            .replacingOccurrences(
                of: "\\b(sebesar|senilai|sejumlah|rp|idr|berhasil|successful|was|of|for|on|pada)\\b.*$",
                with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        merchant = String(merchant.prefix(40))
        if merchant.isEmpty { merchant = "E-wallet payment" }

        return ParsedNotification(
            merchant: merchant,
            amount: income ? -amount : amount,
            category: income ? "Income" : guessCategory(t),
            wallet: wallet)
    }

    private static func capture(_ s: String, _ pattern: String, caseSensitive: Bool) -> String? {
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
