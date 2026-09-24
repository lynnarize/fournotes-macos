import SwiftUI

// Shared pieces of the Finance tab: the panel/tile look, money typography,
// delta pills, status pills and the category icon map.
// Ported from src/components/finance/Dashboard.tsx.

let MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

private let CATEGORY_ICON: [String: String] = [
    "Food & Drink": "coffee", "Groceries": "cart", "Transport": "car", "Shopping": "bag",
    "Bills & Utilities": "bill", "Health": "heart", "Entertainment": "film",
    "Education": "book", "Income": "download",
]

func categoryIcon(_ c: String) -> String { CATEGORY_ICON[c] ?? "wallet" }

/// Finance cards: a soft panel with white tiles inside.
struct FinanceCard<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 1))
            .entrance()
    }
}

/// A white tile inside a finance card.
struct Tile<Content: View>: View {
    @Environment(\.palette) private var p
    var cornerRadius: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(p.line, lineWidth: 1))
    }
}

/// A money amount with its cents (if any) smaller and dimmed: $12,521.15
struct MoneyText: View {
    @Environment(\.palette) private var p
    let amount: Double
    let currency: String
    var size: CGFloat = 15
    var weight: Font.Weight = .regular

    var body: some View {
        let text = Money.format(amount, currency)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let match = text.firstMatch(of: /^(.*?)([.,]\d{2})(\D*)$/) {
                Text(String(match.1)).font(.system(size: size, weight: weight))
                // The cents, smaller and dimmed: $12,521.15
                Text(String(match.2))
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(p.faint)
                Text(String(match.3)).font(.system(size: size, weight: weight))
            } else {
                Text(text).font(.system(size: size, weight: weight))
            }
        }
        .monospacedDigit()
        .tracking(-0.4)
        .contentTransition(.numericText())
    }
}

/// "↗ 12%" pill. For spending, going up is bad; for income, good.
struct DeltaPill: View {
    @Environment(\.palette) private var p
    let pct: Double?
    var upIsGood = false

    var body: some View {
        if let pct, pct.isFinite {
            let up = pct >= 0
            let good = up == upIsGood
            let tone = good ? p.ok : p.danger
            let magnitude = abs(pct * 100)
            HStack(spacing: 2) {
                Icon("arrowUpRight", size: 12)
                    .rotationEffect(.degrees(up ? 0 : 90))
                Text(magnitude >= 10 ? "\(Int(safe: magnitude.rounded()))%" : String(format: "%.1f%%", magnitude))
            }
            .font(FN.font(12, .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tone.opacity(good ? 0.10 : 0.09),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tone.opacity(0.28), lineWidth: 1))
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .animation(Motion.data, value: pct)
        }
    }
}

/// The small status pill used by upcoming payments and alerts.
struct StatusPill: View {
    enum Tone { case good, warn, bad, muted, accent }
    @Environment(\.palette) private var p
    let text: String
    var tone: Tone = .muted
    var dot = true

    private var colors: (fg: Color, bg: Color, border: Color) {
        switch tone {
        case .good: return (p.ok, p.ok.opacity(0.10), p.ok.opacity(0.30))
        case .warn: return (p.boardAmberInk, p.boardAmber.opacity(0.14), p.boardAmber.opacity(0.35))
        case .bad: return (p.danger, p.danger.opacity(0.09), p.danger.opacity(0.30))
        case .muted: return (p.muted, p.hover, p.line)
        case .accent: return (p.accent, p.accent.opacity(0.14), .clear)
        }
    }

    var body: some View {
        let c = colors
        HStack(spacing: 6) {
            if dot { Circle().fill(c.fg).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(FN.font(12, .medium))
        .foregroundStyle(c.fg)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(c.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.border, lineWidth: 1))
        .animation(Motion.standard, value: text)
        .fixedSize()
    }
}

/// A card header: accent icon, title, optional hint, then controls on the right.
struct FinanceCardTitle<Trailing: View>: View {
    @Environment(\.palette) private var p
    let icon: String
    let title: String
    var hint: String?
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String, title: String, hint: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.title = title; self.hint = hint; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Icon(icon, size: 18).foregroundStyle(p.accent)
            Text(title)
                .font(FN.serif(19))
                .tracking(-0.2)
                .foregroundStyle(p.text)
            if let hint {
                Icon("info", size: 14).foregroundStyle(p.faint).help(hint)
            }
            Spacer()
            trailing()
        }
        .frame(minHeight: 36)
    }
}

/// Small segmented control used in card headers.
struct SegmentedTabs: View {
    @Environment(\.palette) private var p
    let items: [(id: String, label: String)]
    @Binding var selection: String
    var alert: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.id) { item in
                Button { selection = item.id } label: {
                    Text(item.label)
                        .font(FN.font(12, selection == item.id ? .semibold : .regular))
                        .foregroundStyle(selection == item.id ? p.accent : p.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selection == item.id ? p.accent.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                        .scaleEffect(selection == item.id ? 1.02 : 1)
                        .motion(selection == item.id, Motion.quick)
                        .overlay(alignment: .topTrailing) {
                            if alert == item.id, selection != item.id {
                                Circle().fill(p.danger).frame(width: 6, height: 6).offset(x: -2, y: 2)
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .animation(Motion.standard,
                                   value: alert == item.id && selection != item.id)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
            }
        }
        .padding(2)
        .background(p.bg, in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous).stroke(p.line, lineWidth: 1))
    }
}

// MARK: - Shared math

enum FinanceMath {
    static func spend(_ txs: [Transaction], _ cur: String) -> Double {
        txs.filter { $0.amount > 0 }.reduce(0) { $0 + Insights.myShare($1, cur) }
    }

    static func income(_ txs: [Transaction], _ cur: String) -> Double {
        txs.filter { $0.amount < 0 }.reduce(0) { $0 + abs(Insights.baseAmount($1, cur)) }
    }

    static func pct(_ now: Double, _ before: Double) -> Double? {
        before > 0 ? (now - before) / before : nil
    }

    static func shortDate(_ iso: String) -> String {
        DateKit.date(String(iso.prefix(10))).map(Fmt.dayMonth) ?? iso
    }

    static func daysFromToday(_ iso: String) -> Int {
        guard let a = DateKit.date(String(iso.prefix(10))),
              let b = DateKit.date(DateKit.localDate()) else { return 0 }
        return Int((a.timeIntervalSince(b) / 86_400).rounded())
    }

    static func inDays(_ n: Int) -> String {
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "1 day late"
        default: return n > 0 ? "in \(n) days" : "\(-n) days late"
        }
    }

    static func ago(_ date: String) -> String {
        let n = -daysFromToday(date)
        if n <= 0 { return "Today" }
        if n == 1 { return "Yesterday" }
        return n < 7 ? "\(n)d ago" : shortDate(date)
    }

    static func shiftMonth(_ m: String, by: Int) -> String {
        guard let d = DateKit.startOfMonth(m),
              let next = Calendar.current.date(byAdding: .month, value: by, to: d) else { return m }
        return DateKit.localMonth(next)
    }
}
