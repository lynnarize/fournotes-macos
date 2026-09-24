import SwiftUI

// Finance overview, laid out like an operations dashboard:
//   row 1  three stat cards: spent · income · transactions (each vs last month)
//   left   spending chart (month by day · year by month · categories), upcoming payments
//   right  budget progress, monthly review (AI), heads-up alerts with actions
// Everything but the review is computed on the device.
// Ported from src/components/finance/Dashboard.tsx.

struct FinanceDashboard: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var toasts: ToastCenter

    let month: String
    let summary: MonthlySummary?
    let summarizing: Bool
    let onSummarize: () -> Void
    let onReport: () -> Void
    let onBudgets: () -> Void
    let onOpenTransactions: () -> Void
    let onOpenTransaction: (String) -> Void

    @AppStorage("fournotes.financeView") private var chartView = "month"
    @AppStorage("fournotes.financePanel") private var panel = "upcoming"
    @AppStorage("fournotes.financeDismissed") private var dismissedRaw = ""
    /// The spending chart, opened from the Spent card.
    @AppStorage("fournotes.financeChartOpen") private var chartOpen = false
    @State private var openTx: String?

    private var cur: String { store.settings.currency }
    private var live: [Transaction] { store.liveTransactions }
    private var today: String { DateKit.localDate() }
    private var isCurrent: Bool { month == DateKit.localMonth() }

    private var year: Int { Int(month.prefix(4)) ?? 2026 }
    private var monthNumber: Int { Int(month.suffix(2)) ?? 1 }

    private var daysInMonth: Int {
        guard let start = DateKit.startOfMonth(month),
              let range = Calendar.current.range(of: .day, in: .month, for: start) else { return 30 }
        return range.count
    }

    private var dayOfMonth: Int {
        isCurrent ? Calendar.current.component(.day, from: Date()) : daysInMonth
    }

    private var lastMonth: String { FinanceMath.shiftMonth(month, by: -1) }

    private var monthTxs: [Transaction] { live.filter { $0.date.hasPrefix(month) } }

    /// Compare like with like: this month so far against the same days of last month.
    private var prevTxs: [Transaction] {
        live.filter { t in
            t.date.hasPrefix(lastMonth) && (Int(t.date.suffix(2)) ?? 99) <= dayOfMonth
        }
    }

    private var spent: Double { FinanceMath.spend(monthTxs, cur) }
    private var prevSpent: Double { FinanceMath.spend(prevTxs, cur) }
    private var income: Double { FinanceMath.income(monthTxs, cur) }
    private var prevIncome: Double { FinanceMath.income(prevTxs, cur) }

    /// Laid out as the reference: three soft stat cards, one banner with the
    /// month's review, then what's coming up. The chart opens from Spent.
    var body: some View {
        VStack(spacing: 16) {
            statRow
            if chartOpen {
                spendingCard
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
            heroCard
            panelCard
        }
        .animation(Motion.screen, value: chartOpen)
    }

    // MARK: - Stats

    private struct Stat {
        var label: String
        var icon: String
        var pct: Double?
        var upIsGood: Bool
        var diff: String
        var openLabel: String
        var value: AnyView
        /// A shorter form ("Rp2.9M") for when the full value doesn't fit.
        var compact: AnyView? = nil
        var open: () -> Void
    }

    private var stats: [Stat] {
        [
            Stat(label: isCurrent ? "Spent so far" : "Spent", icon: "wallet",
                 pct: FinanceMath.pct(spent, prevSpent), upIsGood: false,
                 diff: "\(spent >= prevSpent ? "+" : "−")\(Money.format(abs(spent - prevSpent), cur, compact: true))",
                 openLabel: "Show or hide the spending chart",
                 value: AnyView(MoneyText(amount: spent, currency: cur, size: 28, weight: .semibold)),
                 compact: compactValue(spent),
                 open: { chartOpen.toggle() }),
            Stat(label: "Income", icon: "download",
                 pct: FinanceMath.pct(income, prevIncome), upIsGood: true,
                 diff: "\(income >= prevIncome ? "+" : "−")\(Money.format(abs(income - prevIncome), cur, compact: true))",
                 openLabel: "Show transactions",
                 value: AnyView(MoneyText(amount: income, currency: cur, size: 28, weight: .semibold)),
                 compact: compactValue(income),
                 open: onOpenTransactions),
            Stat(label: "Transactions", icon: "bill",
                 pct: FinanceMath.pct(Double(monthTxs.count), Double(prevTxs.count)), upIsGood: true,
                 diff: "\(monthTxs.count >= prevTxs.count ? "+" : "−")\(abs(monthTxs.count - prevTxs.count))",
                 openLabel: "Show transactions",
                 value: AnyView(Text("\(monthTxs.count)")
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()),
                 open: onOpenTransactions),
        ]
    }

    private func compactValue(_ amount: Double) -> AnyView {
        AnyView(Text(Money.format(amount, cur, compact: true))
            .font(.system(size: 28, weight: .semibold)).monospacedDigit().tracking(-0.4))
    }

    /// Three cards of one height. The value never wraps: the change pill
    /// drops below it when the card is narrow, and a value too long even
    /// for a line of its own is shortened ("Rp2.9M"). It used to break
    /// "Rp 2,891,500" over three lines and push that card taller than the rest.
    /// The three numbers, each on its own soft colour with its icon.
    private var statRow: some View {
        let tints = [p.boardRed, p.finA, p.finB]
        return HStack(alignment: .top, spacing: 16) {
            ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                pastelCard(stat, tint: tints[index % tints.count],
                           selected: index == 0 && chartOpen)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pastelCard(_ stat: Stat, tint: Color, selected: Bool) -> some View {
        Button(action: stat.open) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    statValue(stat)
                    Text(stat.label).font(FN.body).foregroundStyle(p.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Icon(stat.icon, size: 24)
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
                    .background(p.bg.opacity(0.75), in: Circle())
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(p.mix(tint, 0.16), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(selected ? tint.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.fn)
        .help(stat.openLabel)
        .entrance()
    }

    private func statValue(_ stat: Stat) -> some View {
        let value = stat.value.foregroundStyle(p.text).lineLimit(1).fixedSize()
        let pill = DeltaPill(pct: stat.pct, upIsGood: stat.upIsGood).fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { value; pill }
            VStack(alignment: .leading, spacing: 6) { value; pill }
            if let compact = stat.compact {
                VStack(alignment: .leading, spacing: 6) {
                    compact.foregroundStyle(p.text).lineLimit(1).fixedSize()
                    pill
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                (stat.compact ?? stat.value).foregroundStyle(p.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                pill
            }
        }
    }

    // MARK: - Spending card

    private var daily: [Double] {
        var out = [Double](repeating: 0, count: daysInMonth)
        for t in monthTxs where t.amount > 0 {
            let day = (Int(t.date.suffix(2)) ?? 1) - 1
            if out.indices.contains(day) { out[day] += Insights.myShare(t, cur) }
        }
        return Array(out.prefix(dayOfMonth))
    }

    private var yearly: [Double] {
        var out = [Double](repeating: 0, count: 12)
        for t in live where t.amount > 0 && t.date.hasPrefix(String(year)) {
            let m = (Int(t.date.dropFirst(5).prefix(2)) ?? 1) - 1
            if out.indices.contains(m) { out[m] += Insights.myShare(t, cur) }
        }
        return out
    }

    private var yearToDate: Double { yearly.prefix(monthNumber).reduce(0, +) }

    private var lastYearToDate: Double {
        let cutoff = String(format: "%02d", monthNumber)
        return FinanceMath.spend(live.filter {
            $0.date.hasPrefix(String(year - 1)) && $0.date.dropFirst(5).prefix(2) <= cutoff
        }, cur)
    }

    private var byCategory: [(String, Double)] {
        Insights.spendByCategory(monthTxs, cur).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private var spendingCard: some View {
        FinanceCard {
            VStack(alignment: .leading, spacing: 0) {
                FinanceCardTitle(icon: "chart", title: "Spending",
                                 hint: "Your share of each expense, in your main currency") {
                    SegmentedTabs(items: [("month", "Month"), ("year", "Year"), ("category", "Categories")],
                                  selection: $chartView)
                }

                HStack(spacing: 8) {
                    MoneyText(amount: chartView == "year" ? yearToDate : spent, currency: cur,
                              size: 29, weight: .semibold)
                        .foregroundStyle(p.text)
                    if chartView == "year" {
                        DeltaPill(pct: FinanceMath.pct(yearToDate, lastYearToDate))
                    } else {
                        DeltaPill(pct: FinanceMath.pct(spent, prevSpent))
                    }
                    Text(chartView == "year" ? "vs \(year - 1)" : "vs last month")
                        .font(FN.small).foregroundStyle(p.muted)
                }
                .padding(.top, 4)

                Group {
                    switch chartView {
                    case "year":
                        let shown = year == Calendar.current.component(.year, from: Date())
                            ? Calendar.current.component(.month, from: Date()) : 12
                        SpendingChart(values: Array(yearly.prefix(shown)), total: 12, currency: cur,
                                      label: { "\(MONTH_NAMES[$0]) \(year)" },
                                      ticks: MONTH_NAMES.enumerated().map { (at: $0.offset, text: $0.element) },
                                      pill: monthNumber - 1)
                    case "category":
                        categoryList
                    default:
                        SpendingChart(values: daily, total: daysInMonth, currency: cur,
                                      label: { "\($0 + 1) \(MONTH_NAMES[monthNumber - 1])" },
                                      ticks: monthTicks)
                    }
                }
                .padding(.top, 12)
                .id(chartView)
                .transition(.opacity.combined(with: .offset(y: 8)))
                .animation(Motion.screen, value: chartView)
            }
        }
    }

    private var monthTicks: [(at: Int, text: String)] {
        var days = [1, 5, 10, 15, 20, 25, daysInMonth]
        days = Array(NSOrderedSet(array: days).array as? [Int] ?? days)
        return days.map { (at: $0 - 1, text: String($0)) }
    }

    private var categoryList: some View {
        ScrollView {
            VStack(spacing: 6) {
                if byCategory.isEmpty {
                    Text("No spending this month.")
                        .font(FN.body).foregroundStyle(p.faint)
                        .padding(.vertical, 40)
                }
                ForEach(byCategory, id: \.0) { category, value in
                    Tile {
                        HStack(spacing: 12) {
                            Icon(categoryIcon(category), size: 16)
                                .foregroundStyle(p.accent)
                                .frame(width: 32, height: 32)
                                .background(p.accent.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                            Text(category)
                                .font(FN.bodyMedium).foregroundStyle(p.text)
                                .lineLimit(1).frame(width: 128, alignment: .leading)
                            ProgressBar(ratio: value / (byCategory.first?.1 ?? 1), tone: p.accent, height: 8)
                            Text(Money.format(value, cur, compact: true))
                                .font(FN.body).monospacedDigit().foregroundStyle(p.text)
                                .frame(width: 80, alignment: .trailing)
                            Text("\(spent > 0 ? Int((value / spent * 100).rounded()) : 0)%")
                                .font(FN.small).monospacedDigit().foregroundStyle(p.faint)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                .animation(Motion.list, value: byCategory.map(\.0))
            }
        }
        .frame(height: 196)
    }

    // MARK: - Upcoming payments / heads-up

    /// "Monthly", not "Every month": short enough to leave room for the amount.
    private var upcoming: [Glance.Payment] {
        Glance.upcoming(todos: store.liveTodos, transactions: live, currency: cur)
    }

    private struct Alert: Identifiable {
        var id: String
        var critical = false
        var title: String
        var place: String
        var detail: String
        var when: String
        var actionLabel: String?
        var action: (() -> Void)?
    }

    private var dismissed: [String] {
        dismissedRaw.components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
    }

    private var budgets: [BudgetStatus] { Insights.budgetStatus(monthTxs, store.settings) }

    private var alerts: [Alert] {
        var out: [Alert] = []
        for b in budgets where b.ratio >= 0.8 {
            out.append(Alert(
                id: "budget:\(b.category)", critical: b.ratio >= 1,
                title: b.ratio >= 1 ? "\(b.category) budget exceeded" : "\(b.category) budget almost used",
                place: "\(Int((b.ratio * 100).rounded()))% used",
                detail: "\(Money.format(b.spent, cur, compact: true)) of \(Money.format(b.limit, cur, compact: true))",
                when: "this month", actionLabel: "Adjust budget", action: onBudgets))
        }
        if isCurrent {
            let spentToday = FinanceMath.spend(live.filter { $0.date == today }, cur)
            let avg = FinanceMath.spend(monthTxs.filter { $0.date < today }, cur) / Double(max(1, dayOfMonth - 1))
            if avg > 0, spentToday > avg * 2 {
                out.append(Alert(
                    id: "spike:\(today)", title: "Spending spike today",
                    place: Money.format(spentToday, cur, compact: true),
                    detail: "usual day \(Money.format(avg, cur, compact: true))",
                    when: "today", actionLabel: "See transactions", action: onOpenTransactions))
            }
        }
        for owed in Insights.owedToMe(live, cur).prefix(3) {
            let tx = live.first { t in (t.splits ?? []).contains { $0.name == owed.name && !$0.settled } }
            out.append(Alert(
                id: "owed:\(owed.name)", title: "\(owed.name) still owes you",
                place: Money.format(owed.amount, cur, compact: true),
                detail: tx?.merchant ?? "Split bill",
                when: tx.map { FinanceMath.shortDate($0.date) } ?? "",
                actionLabel: tx != nil ? "Open bill" : nil,
                action: tx.map { t in { onOpenTransaction(t.id) } }))
        }
        return out.filter { !dismissed.contains("\(month):\($0.id)") }
    }

    private func dismiss(_ id: String) {
        var next = dismissed + ["\(month):\(id)"]
        if next.count > 100 { next = Array(next.suffix(100)) }
        dismissedRaw = next.joined(separator: "\u{1F}")
    }

    private var panelCard: some View {
        let alerts = alerts
        let critical = alerts.filter(\.critical).count
        return FinanceCard {
            VStack(alignment: .leading, spacing: 0) {
                FinanceCardTitle(icon: panel == "upcoming" ? "calendar" : "warning",
                                 title: panel == "upcoming" ? "Upcoming payments" : "Heads-up") {
                    SegmentedTabs(
                        items: [("upcoming", "Payments"),
                                ("alerts", alerts.isEmpty ? "Heads-up" : "Heads-up · \(alerts.count)")],
                        selection: $panel,
                        alert: critical > 0 ? "alerts" : nil)
                }

                Group {
                    if panel == "upcoming" {
                        upcomingList
                    } else {
                        alertList(alerts)
                    }
                }
                .id(panel)
                .transition(.opacity.combined(with: .offset(y: 7)))
                .animation(Motion.screen, value: panel)
            }
        }
    }

    private var upcomingList: some View {
        VStack(spacing: 0) {
            if upcoming.isEmpty {
                Text("No bills due soon. Repeating bills you add to To-Do show up here.")
                    .font(FN.body).foregroundStyle(p.faint)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(upcoming) { item in
                let n = FinanceMath.daysFromToday(item.date)
                HStack(spacing: 12) {
                    if let todoId = item.todoId {
                        // A button, not a Toggle bound to a constant: SwiftUI
                        // set that Toggle by itself when the list redrew, and
                        // paid a bill — logged it, scheduled the next — with
                        // no click at all.
                        Button {
                            let extra = store.toggleTodo(todoId, done: true)
                            toasts.push((["☑️ Paid: \(item.title)"] + extra).joined(separator: "\n"))
                        } label: {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(p.faint, lineWidth: 1.2)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.fn)
                        .help("Mark as paid")
                        .accessibilityLabel("Mark \(item.title) as paid")
                    } else {
                        // Sized both ways: with only a width it took all the
                        // height it was offered, and the card stretched to the
                        // column beside it with its rows spread out.
                        Color.clear.frame(width: 16, height: 16)
                    }

                    Text(FinanceMath.shortDate(item.date))
                        .font(FN.small).monospacedDigit().foregroundStyle(p.muted)
                        .frame(width: 48, alignment: .leading)

                    Rectangle().fill(p.line).frame(width: 1, height: 40)

                    Tile {
                        Icon(categoryIcon(item.category), size: 19)
                            .foregroundStyle(p.accent)
                            .frame(width: 44, height: 44)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(p.text).lineLimit(1)
                        HStack(spacing: 0) {
                            Text("\(item.sub) · ")
                            // The amount is the point; the label gives way first.
                            MoneyText(amount: item.amount, currency: item.currency, size: 12)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        .font(FN.small).foregroundStyle(p.muted).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(FinanceMath.inDays(n))
                        .font(FN.small).foregroundStyle(p.muted)

                    if let sub = item.subscription {
                        Button { trackSubscription(sub) } label: { StatusPill(text: "Track", tone: .muted, dot: false) }
                            .buttonStyle(.fn)
                    } else {
                        StatusPill(text: n < 0 ? "Overdue" : n <= 3 ? "Due soon" : "Scheduled",
                                   tone: n < 0 ? .bad : n <= 3 ? .warn : .good)
                    }
                }
                .padding(.vertical, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.list, value: upcoming.map(\.id))
        .padding(.top, 12)
    }

    private func alertList(_ alerts: [Alert]) -> some View {
        VStack(spacing: 0) {
            if alerts.isEmpty {
                HStack(spacing: 12) {
                    Icon("check", size: 18)
                        .foregroundStyle(p.ok)
                        .frame(width: 40, height: 40)
                        .background(p.ok.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                    Text("All clear: budgets on track, nobody owes you.")
                        .font(FN.body).foregroundStyle(p.text)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            ForEach(alerts) { alert in
                HStack(spacing: 12) {
                    Icon("warning", size: 19)
                        .foregroundStyle(alert.critical ? p.danger : p.boardAmberInk)
                        .frame(width: 44, height: 44)
                        .background((alert.critical ? p.danger : p.boardAmber).opacity(alert.critical ? 0.09 : 0.14),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(alert.title)
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(p.text).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(alert.place).foregroundStyle(p.accent)
                            Circle().fill(p.faint).frame(width: 4, height: 4)
                            Text(alert.detail).foregroundStyle(p.muted).lineLimit(1)
                        }
                        .font(FN.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(alert.when).font(FN.small).foregroundStyle(p.muted)

                    if let label = alert.actionLabel, let action = alert.action {
                        Button(action: action) { StatusPill(text: label, tone: .accent, dot: false) }
                            .buttonStyle(.fn)
                    }

                    IconButton("x", size: 15, box: 30, help: "Dismiss for this month") {
                        dismiss(alert.id)
                    }
                }
                .padding(.vertical, 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.list, value: alerts.map(\.id))
        .padding(.top, 12)
    }

    private func trackSubscription(_ s: Subscription) {
        guard let day = DateKit.date(s.nextDate),
              let at9 = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { return }
        let due = DateKit.iso(at9)
        store.addTodo {
            $0.title = "Pay \(s.merchant)"
            $0.dueAt = due
            $0.remindAt = due
            // Anchored to its day, so a bill on the 31st comes back on the
            // 31st (or the month's last day), not the 28th forever after February.
            $0.rrule = Recurrence.normalised("FREQ=MONTHLY;INTERVAL=1", anchoredTo: at9) ?? "FREQ=MONTHLY;INTERVAL=1"
            $0.bill = Bill(amount: s.amount, currency: s.currency, category: s.category)
        }
        toasts.push("🔁 Monthly bill added: \(s.merchant)")
    }

    // MARK: - The month's review

    /// The banner: what the month comes to, today's pace, the review beside it.
    private var heroCard: some View {
        let budgetTotal = store.settings.budgets.values.reduce(0, +)
        let spentToday = FinanceMath.spend(live.filter { $0.date == today && $0.amount > 0 }, cur)
        let before = FinanceMath.spend(monthTxs.filter { $0.date < today }, cur)
        let daysLeft = daysInMonth - dayOfMonth + 1
        let allowance = budgetTotal > 0
            ? max(0, (budgetTotal - before) / Double(daysLeft))
            : before / Double(max(1, dayOfMonth - 1))
        let left = allowance - spentToday
        let monthName = Fmt.monthYear(month).components(separatedBy: " ").first ?? ""

        return HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 14) {
                Text(isCurrent ? "\(Money.format(spent, cur, compact: true)) spent so far this \(monthName)"
                               : "\(Money.format(spent, cur, compact: true)) spent in \(Fmt.monthYear(month))")
                    .font(FN.serif(30))
                    .tracking(-0.5)
                    .foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                if isCurrent {
                    Group {
                        if allowance > 0 || budgetTotal > 0 {
                            let pace = Text("\(Money.format(abs(left), cur, compact: true)) \(left >= 0 ? "left" : "over") for today")
                                .foregroundColor(left < 0 ? p.danger : p.text)
                            Text("\(Money.format(spentToday, cur, compact: true)) today · \(pace)")
                        } else {
                            Text("\(Money.format(spentToday, cur, compact: true)) spent today")
                        }
                    }
                    .font(FN.body)
                    .foregroundStyle(p.muted)
                }
                HStack(spacing: 10) {
                    PrimaryButton(title: "Monthly report", icon: "download", action: onReport)
                    if !monthTxs.isEmpty {
                        GhostButton(action: onSummarize) {
                            Text(summarizing ? "Writing…" : (summary != nil ? "Refresh review" : "Write review"))
                        }
                        .disabled(summarizing)
                    }
                    if budgetTotal == 0 {
                        GhostButton(action: onBudgets) { Text("Set a budget") }
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The review, without the total the headline already says.
            Group {
                if summarizing {
                    Text("Reading this month's spending…").foregroundStyle(p.muted)
                } else if let text = summary?.text {
                    BriefText(text: text.components(separatedBy: "\n")
                        .filter { !$0.hasPrefix("- Total:") }.joined(separator: "\n"), currency: cur)
                } else {
                    Text(monthTxs.isEmpty
                         ? "Log some spending first; the review is written from it."
                         : "A short review of the month, with a tip, is written here as you spend.")
                        .foregroundStyle(p.muted)
                }
            }
            .font(FN.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.list, value: summary?.text ?? (summarizing ? "loading" : ""))
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(p.line, lineWidth: 1))
        .entrance()
    }
}
