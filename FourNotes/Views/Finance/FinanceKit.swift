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
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            .entrance()
    }
}

/// A tile inside a finance card: a shade darker than the card, no border.
struct Tile<Content: View>: View {
    @Environment(\.palette) private var p
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(p.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        // Large amounts are display type, as on the web: regular weight, tight.
        let font = size >= 24 ? FN.display(size) : FN.font(size, weight)
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let match = text.firstMatch(of: /^(.*?)([.,]\d{2})(\D*)$/) {
                Text(String(match.1)).font(font)
                // The cents, smaller and dimmed: $12,521.15
                Text(String(match.2))
                    .font(FN.font(size * 0.55, .medium))
                    .foregroundStyle(p.textMuted)
                Text(String(match.3)).font(font)
            } else {
                Text(text).font(font)
            }
        }
        .monospacedDigit()
        .tracking(size >= 24 ? FN.displayTracking(size) : -0.2)
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
            let magnitude = abs(pct * 100)
            let label = (magnitude >= 10 ? "\(Int(safe: magnitude.rounded()))%" : String(format: "%.1f%%", magnitude))
            // Said plainly, in grey: colour stays for status.
            HStack(spacing: 3) {
                Icon("arrowUpRight", size: 12)
                    .rotationEffect(.degrees(up ? 0 : 90))
                Text("\(label) \(up ? "up" : "down")")
            }
            .font(FN.small)
            .foregroundStyle(p.textMuted)
            .help("\(label) \(up ? "more" : "less") than the period before")
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

    /// The kit's badges: neutral for labels, the tones only for status.
    private var colors: (fg: Color, bg: Color) {
        switch tone {
        case .good: return (p.success, p.successSubtle)
        case .warn: return (p.warning, p.warningSubtle)
        case .bad: return (p.danger, p.dangerSubtle)
        case .muted: return (p.textSecondary, p.surfaceMuted)
        case .accent: return (p.accent, p.accentSubtle)
        }
    }

    var body: some View {
        let c = colors
        HStack(spacing: 5) {
            if dot { Circle().fill(c.fg).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(FN.font(12, tone == .muted ? .regular : .medium))
        .foregroundStyle(c.fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(c.bg, in: Capsule())
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
            Icon(icon, size: 16).foregroundStyle(p.textSecondary)
            Text(title)
                .font(FN.font(16, .medium))
                .foregroundStyle(p.foreground)
            if let hint {
                Icon("info", size: 14).foregroundStyle(p.faint).help(hint)
            }
            Spacer()
            trailing()
        }
        .frame(minHeight: 36)
    }
}

/// The kit's segmented control (`.seg`): a track with the chosen segment raised on it.
/// The raised segment slides from one choice to the next.
struct SegmentedTabs: View {
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme
    @Namespace private var raised
    let items: [(id: String, label: String)]
    @Binding var selection: String
    var alert: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let on = selection == item.id
                Button { withAnimation(Motion.standard) { selection = item.id } } label: {
                    Text(item.label)
                        .font(FN.font(12, on ? .medium : .regular))
                        .foregroundStyle(on ? p.foreground : p.textSecondary)
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .background {
                            if on {
                                Capsule()
                                    .fill(scheme == .dark ? p.surfaceRaised : p.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: raised)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if alert == item.id, !on {
                                Circle().fill(p.danger).frame(width: 6, height: 6).offset(x: -2, y: 2)
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .animation(Motion.standard, value: alert == item.id && !on)
                        .contentShape(Capsule())
                }
                .buttonStyle(.fn)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(p.surfaceMuted, in: Capsule())
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
