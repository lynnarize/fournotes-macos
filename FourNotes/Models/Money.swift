import Foundation

// Ported from src/lib/money.ts. The app UI is English, so amounts are always
// formatted with en-US conventions.

enum Money {
    private static let zeroDecimal: Set<String> = ["IDR", "JPY", "KRW"]

    /// The largest amount the app will accept. Well below the point where a
    /// Double stops representing whole numbers exactly (2^53), and far below
    /// where Int conversion would trap. Anything larger is a typo or a bad
    /// model answer, and letting it in breaks saving permanently.
    static let maxAmount: Double = 1e15

    /// Whether a number is safe to store as an amount.
    static func isValidAmount(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= maxAmount
    }

    static func format(_ amount: Double, _ currency: String, compact: Bool = false) -> String {
        if compact { return formatCompact(amount, currency) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = zeroDecimal.contains(currency) ? 0 : 2
        f.minimumFractionDigits = 0
        // currencyDisplay: "narrowSymbol"
        if let narrow = narrowSymbol(currency) { f.currencySymbol = narrow }
        return f.string(from: NSNumber(value: amount)) ?? "\(currency) \(amount)"
    }

    /// Intl `notation: "compact"` with one fraction digit: 1.2K, 3.4M, 1.1B.
    private static func formatCompact(_ amount: Double, _ currency: String) -> String {
        guard amount.isFinite else { return "\(narrowSymbol(currency) ?? currency + " ")—" }
        let sign = amount < 0 ? "-" : ""
        let v = abs(amount)
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        var body = trimmed(v)
        for (scale, suffix) in units where v >= scale {
            body = trimmed((v / scale * 10).rounded() / 10) + suffix
            break
        }
        return "\(sign)\(narrowSymbol(currency) ?? currency + " ")\(body)"
    }

    private static func trimmed(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(safe: r)) : String(format: "%.1f", r)
    }

    private static func narrowSymbol(_ code: String) -> String? {
        switch code {
        case "IDR": return "Rp"
        case "USD": return "$"
        case "SGD": return "$"
        case "MYR": return "RM"
        case "EUR": return "€"
        case "JPY": return "¥"
        case "AUD": return "$"
        case "GBP": return "£"
        case "THB": return "฿"
        case "KRW": return "₩"
        case "CNY": return "¥"
        case "SAR": return "﷼"
        default: return nil
        }
    }

    /// Parse "150k", "1.5M", "Rp 25,000", "IDR 1,250,000.00" into a number
    /// (Indonesian "25rb", "1,5jt", "Rp 25.000" also work).
    ///
    /// Returns nil rather than a number the rest of the app cannot survive: a
    /// value that overflowed to infinity, or one large enough to break saving.
    static func parse(_ s: String) -> Double? {
        let ns = s as NSString
        // A currency before the number, the number (a sign only when glued to
        // it), and a unit that ends its word: the "m" of "makan" is not a
        // million.
        let pattern = "(?:(rp|idr|usd|sgd|eur|\\$|€|£)\\.?\\s*)?([+-]?\\d[\\d.,]*(?:[eE][+-]?\\d+)?)"
            + "(?:\\s*(rb|ribu|k|jt|juta|m)\\b)?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        // Every number is a candidate. "Grab 2 orang 50rb" holds a count and
        // a price; the price is the one marked as money — a currency or a
        // unit — or failing that the largest: a count, a quantity or a day of
        // the month is smaller.
        var best: (value: Double, marked: Bool)?
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let hasCurrency = m.range(at: 1).location != NSNotFound
            let numberRange = m.range(at: 2)
            var raw = ns.substring(with: numberRange)
            var unit = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            // Only a capital M is a million; "5m kabel" is five metres.
            if unit == "m" { continue }
            unit = unit.lowercased()

            // What comes before. A number glued to letters is a code
            // ("INV2026", "ABC-99999"), not an amount. A sign counts only at
            // the start, after a space or after a currency: "Rp -25.000" is
            // income, "25000-30000" is a range.
            let before = numberRange.location > 0 ? ns.substring(with: NSRange(location: numberRange.location - 1, length: 1)) : ""
            let signed = raw.hasPrefix("-") || raw.hasPrefix("+")
            if !hasCurrency {
                if let c = before.first, c.isLetter { continue }
                if signed, let c = before.first, !c.isWhitespace {
                    if c.isLetter || c == "_" { continue }
                    raw.removeFirst()
                }
                if signed, numberRange.location >= 2 {
                    let twoBack = ns.substring(with: NSRange(location: numberRange.location - 1, length: 1))
                    if twoBack.first?.isWhitespace == false, twoBack.first?.isLetter == true { continue }
                }
            }

            // What follows the number (or its unit): a letter straight after
            // it ("25kg") or a measure ("3 liter", "2 orang") means it isn't money.
            let end = unit.isEmpty ? NSMaxRange(numberRange) : NSMaxRange(m.range(at: 3))
            let after = ns.substring(from: end)
            if let first = after.first, first.isLetter { continue }
            if after.range(of: "^\\s*(kg|g|gr|gram|l|lt|liter|litre|ml|km|cm|mm|pcs|pc|pax|orang|x|buah|porsi|"
                              + "kali|times|jam|menit|hari|minggu|bulan|tahun|hours?|minutes?|days?|weeks?|"
                              + "months?|years?)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            guard let value = amount(raw, unit: unit) else { continue }
            let marked = hasCurrency || !unit.isEmpty
            if let current = best {
                if current.marked && !marked { continue }
                if current.marked == marked && abs(value) <= abs(current.value) { continue }
            }
            best = (value, marked)
        }
        return best?.value
    }

    /// One number and its unit, as an amount; nil when it isn't one the
    /// rest of the app can survive.
    private static func amount(_ number: String, unit: String) -> Double? {
        var raw = number
        while raw.hasSuffix(".") || raw.hasSuffix(",") { raw.removeLast() }

        var sign = 1.0
        if raw.hasPrefix("-") { sign = -1; raw.removeFirst() }
        else if raw.hasPrefix("+") { raw.removeFirst() }

        if raw.range(of: "[eE]", options: .regularExpression) != nil {
            // Scientific notation, as produced for small FX rates: leave it be.
        } else if !unit.isEmpty {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        } else if matches(raw, "^\\d{1,3}(\\.\\d{3})+(,\\d{1,2})?$") {      // 25.000,00
            raw = raw.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if matches(raw, "^\\d{1,3}(,\\d{3})+(\\.\\d{1,2})?$") {      // 25,000.00
            raw = raw.replacingOccurrences(of: ",", with: "")
        } else {
            raw = raw.replacingOccurrences(of: ",", with: ".")
        }

        guard var n = Double(raw), n.isFinite else { return nil }
        if ["rb", "ribu", "k"].contains(unit) { n *= 1_000 }
        if ["jt", "juta", "m"].contains(unit) { n *= 1_000_000 }
        n *= sign

        let rounded = (n * 100).rounded() / 100
        return isValidAmount(rounded) ? rounded : nil
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}
