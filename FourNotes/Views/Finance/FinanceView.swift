import SwiftUI

// The Finance tab: month picker and quick actions, the dashboard, and the
// transaction list with its inline editor.
// Ported from src/components/FinanceView.tsx.

struct FinanceView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var engine: AIEngine

    @State private var month = DateKit.localMonth()
    @State private var summarizing = false
    /// The data the review was last asked to cover, so a failure isn't retried in a loop.
    @State private var reviewRequested: String?
    @State private var openId: String?
    @State private var showReport = false
    @State private var showBudgets = false
    @State private var showPaste = false
    @State private var pasteText = ""
    /// Narrows the transaction table.
    @State private var query = ""

    // The "add a transaction" row.
    @State private var newMerchant = ""
    @State private var newAmount = ""
    @State private var newCurrency = ""
    @State private var newCategory = "Food & Drink"

    private var cur: String { store.settings.currency }

    private var txs: [Transaction] {
        store.liveTransactions
            .filter { $0.date.hasPrefix(month) }
            .sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }

    private var summary: MonthlySummary? { store.summaries.first { $0.month == month } }

    var body: some View {
        ScrollViewReader { proxy in
            page(scrollToTransactions: {
                withAnimation(Motion.screen) { proxy.scrollTo("transactions", anchor: .top) }
            })
        }
    }

    private func page(scrollToTransactions: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar

            FinanceDashboard(
                month: month, summary: summary, summarizing: summarizing,
                onSummarize: { Task { await summarize() } },
                onReport: { showReport = true },
                onBudgets: { showBudgets = true },
                onOpenTransactions: scrollToTransactions,
                onOpenTransaction: { openId = $0 })

            transactionsSection
                .id("transactions")
        }
        .onAppear { if newCurrency.isEmpty { newCurrency = cur } }
        // The review is rewritten each time Finance opens after the month's
        // spending changed, or on a new day.
        .task(id: reviewBasis) { await autoSummarize(reviewBasis) }
        .task(id: nav.focus) {
            guard let link = nav.consumeFocus([.transactions, .budget]) else { return }
            if link.kind == .budget {
                // Budgets live in a window (and in Settings); the dashboard doesn't show them.
                showBudgets = true
            } else if let t = store.liveTransactions.first(where: { $0.id == link.id }) {
                // Only move months for a date the app can actually read.
                if let day = DateKit.date(t.date) { month = DateKit.localMonth(day) }
                openId = t.id
            }
        }
        .sheet(isPresented: $showBudgets) {
            SheetFrame(title: "Monthly budgets") {
                VStack(spacing: 16) {
                    BudgetEditor()
                    PrimaryButton(title: "Done") { showBudgets = false }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(isPresented: $showPaste) { pasteSheet }
        .sheet(isPresented: $showReport) { ReportView() }
    }

    // MARK: - Toolbar

    /// Search on the left; the month and one menu of actions on the right.
    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Icon("search", size: 17).foregroundStyle(p.faint)
                TextField("Search transactions, categories or items", text: $query)
                    .textFieldStyle(.plain)
                    .font(FN.body)
                if !query.isEmpty {
                    IconButton("x", size: 13, box: 22, help: "Clear") { query = "" }
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: 420, minHeight: 44)
            .background(p.bg, in: Capsule())
            .overlay(Capsule().stroke(p.line, lineWidth: 1))

            Spacer()

            HStack(spacing: 2) {
                IconButton("chevronLeft", size: 16, box: 30, help: "Previous month") {
                    month = FinanceMath.shiftMonth(month, by: -1)
                }
                Text(Fmt.monthYear(month))
                    .font(FN.bodyMedium)
                    .foregroundStyle(p.text)
                    .frame(minWidth: 118)
                    .contentTransition(.numericText())
                    .motion(month, Motion.screen)
                IconButton("chevron", size: 16, box: 30, help: "Next month") {
                    month = FinanceMath.shiftMonth(month, by: 1)
                }
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 44)
            .background(p.bg, in: Capsule())
            .overlay(Capsule().stroke(p.line, lineWidth: 1))

            TextMenu(title: "Actions", help: "Report, paste a notification, budgets") {
                [
                    .item("Monthly report…") { showReport = true },
                    .item("Paste a payment notification…") { showPaste = true },
                    .item("Budgets…") { showBudgets = true },
                ]
            }
            .font(FN.bodyMedium)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(p.bg, in: Capsule())
            .overlay(Capsule().stroke(p.line, lineWidth: 1))
        }
    }

    // MARK: - Transactions

    /// The table, narrowed by the search box.
    private var shown: [Transaction] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return txs }
        return txs.filter { t in
            t.merchant.localizedCaseInsensitiveContains(q) || t.category.localizedCaseInsensitiveContains(q)
                || t.items.contains { $0.name.localizedCaseInsensitiveContains(q) }
        }
    }

    private var monthSpent: Double {
        txs.filter { $0.amount > 0 }.reduce(0) { $0 + Insights.myShare($1, cur) }
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            addBar

            HStack {
                Text("Transactions").font(FN.serif(23)).foregroundStyle(p.text)
                Spacer()
                Text("\(Fmt.monthYear(month)): \(Money.format(monthSpent, cur))")
                    .font(FN.body).monospacedDigit()
                    .foregroundStyle(p.muted)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .overlay(Capsule().stroke(p.line, lineWidth: 1))
            }
            .padding(.top, 8)

            if txs.isEmpty {
                EmptyStart(
                    title: "No spending logged yet",
                    hint: "Add one above, scan a receipt, paste a payment notification — or just say what you spent.",
                    prompts: ["Spent 25k on coffee at Starbucks", "Set my food budget to 1.5M a month"],
                    extra: { SecondaryButton(title: "Paste a notification") { showPaste = true } })
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                VStack(spacing: 0) {
                    TransactionHeader()
                    Divider().overlay(p.line)
                    if shown.isEmpty {
                        Text("Nothing matches “\(query)”.")
                            .font(FN.body).foregroundStyle(p.faint)
                            .padding(.vertical, 20)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { t in
                            TransactionRow(tx: t, month: month,
                                           open: openId == t.id,
                                           onToggle: { openId = openId == t.id ? nil : t.id })
                                .transition(.opacity)
                        }
                    }
                    .animation(Motion.list, value: shown.map(\.id))
                }
            }
        }
    }

    /// One line to add a transaction, as the reference's "New Project" bar.
    private var addBar: some View {
        HStack(spacing: 10) {
            Icon("plus", size: 16).foregroundStyle(p.accent)
            TextField("Add a transaction — merchant", text: $newMerchant)
                .textFieldStyle(.plain)
                .font(FN.bodyMedium)
                .onSubmit(addTransaction)
            TextField("Amount (25k)", text: $newAmount)
                .textFieldStyle(.plain)
                .font(FN.body).monospacedDigit()
                .frame(width: 110)
                .onSubmit(addTransaction)
            TextMenu(title: newCategory, help: "Category") {
                store.categories.map { c in .item(c, checked: c == newCategory) { newCategory = c } }
            }
            .font(FN.body)
            TextMenu(title: newCurrency.isEmpty ? cur : newCurrency, help: "Currency") {
                currencyOptions.map { c in .item(c, checked: c == newCurrency) { newCurrency = c } }
            }
            .font(FN.body)
            Button(action: addTransaction) {
                Icon("arrowRight", size: 15)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(p.accent, in: Circle())
            }
            .buttonStyle(.fn)
            .help("Add")
            .accessibilityLabel("Add transaction")
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .background(p.bg, in: Capsule())
        .overlay(Capsule().stroke(p.line, lineWidth: 1))
    }

    private var currencyOptions: [String] {
        var seen = Set<String>()
        return ([cur] + CURRENCIES).filter { seen.insert($0).inserted }
    }

    private func addTransaction() {
        guard !newMerchant.trimmingCharacters(in: .whitespaces).isEmpty,
              let amount = Money.parse(newAmount) else { return }
        store.addTransaction {
            $0.merchant = newMerchant
            $0.amount = amount
            $0.currency = newCurrency.isEmpty ? cur : newCurrency
            $0.fxRate = nil
            $0.category = newCategory
            $0.date = month == DateKit.localMonth() ? DateKit.localDate() : "\(month)-01"
        }
        newMerchant = ""
        newAmount = ""
    }

    // MARK: - Paste a notification

    private var pasteSheet: some View {
        SheetFrame(title: "App / receipt notification") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a payment notification from any app — GoPay, OVO, DANA, ShopeePay, QRIS, a bank app — or the text of a receipt. For screenshots and photos, use the scan button instead.")
                    .font(FN.body)
                    .foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $pasteText)
                    .font(FN.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 96)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                        .stroke(p.line, lineWidth: 1))

                HStack {
                    Spacer()
                    GhostButton(action: { showPaste = false }) { Text("Cancel") }
                    PrimaryButton(title: "Add",
                                  disabled: pasteText.trimmingCharacters(in: .whitespaces).isEmpty,
                                  action: submitPaste)
                }
            }
        }
    }

    private func submitPaste() {
        let text = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let parsed = Wallet.parseNotification(text) {
            store.addTransaction {
                $0.merchant = parsed.merchant
                $0.amount = parsed.amount
                $0.category = parsed.category
                $0.date = DateKit.localDate()
            }
            toasts.push("💸 \(parsed.wallet ?? "Payment"): \(parsed.merchant) "
                        + Money.format(abs(parsed.amount), cur))
        } else if engine.canChat {
            Task { await assistant.send(text) }
            toasts.push("Sent to the assistant to read.")
        } else {
            toasts.push("Couldn't read that, and no server is set for the assistant.", tone: .error)
            return
        }
        pasteText = ""
        showPaste = false
    }

    // MARK: - Monthly review

    private var monthTotal: Double {
        txs.filter { $0.amount > 0 }.reduce(0) { $0 + Insights.myShare($1, cur) }
    }

    /// What this month's review covers: its transactions, and the day.
    private var reviewBasis: String {
        let rows = txs.map { "\($0.id)|\($0.amount)|\($0.category)" }.joined(separator: ";")
        return Fingerprint.of("\(month)#\(DateKit.localDate())#\(rows)")
    }

    private func autoSummarize(_ basis: String) async {
        guard month == DateKit.localMonth(), !txs.isEmpty, engine.canSummarize,
              reviewRequested != basis else { return }
        // Up to date: written today, over the same total.
        // (A review from before the figures were the app's own is rewritten.)
        if let summary, DateKit.date(summary.createdAt).map(DateKit.localDate) == DateKit.localDate(),
           abs(summary.total - monthTotal) < 1,
           summary.text.hasPrefix("- Total: \(Money.format(summary.total, cur))") {
            return
        }
        // Let a burst of edits settle; a newer change cancels this one.
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        reviewRequested = basis
        await summarize()
    }

    private func summarize() async {
        guard !summarizing else { return }
        summarizing = true
        defer { summarizing = false }
        do {
            let written = try await engine.monthlySummary(month: month, currency: cur, transactions: txs)
            let total = monthTotal
            let text = MonthlyReview.compose(written, total: total,
                                             byCategory: Insights.spendByCategory(txs, cur), currency: cur)
            store.saveSummary(MonthlySummary(
                month: month, total: total, currency: cur,
                byCategory: Insights.spendByCategory(txs, cur),
                text: text, createdAt: DateKit.nowIso()))
        } catch {
            toasts.push((error as? APIError)?.errorDescription ?? "Failed", tone: .error)
        }
    }
}

// MARK: - One transaction

private struct TransactionRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @State private var hovering = false

    let tx: Transaction
    let month: String
    let open: Bool
    let onToggle: () -> Void

    private var cur: String { store.settings.currency }
    private var foreign: Bool { tx.currency != cur }
    private var unsettled: Int { (tx.splits ?? []).filter { !$0.settled }.count }

    var body: some View {
        VStack(spacing: 0) {
            summaryRow
            if open {
                editor
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .background(open ? p.hover : (hovering ? p.hover.opacity(0.5) : .clear),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .flashes(nav.isFlashing(tx.id), palette: p)
        .motion(open || hovering, Motion.quick)
        .onHover { hovering = $0 }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let splits = tx.splits, !splits.isEmpty {
            parts.append("Split \(splits.count + 1) ways" + (unsettled > 0 ? " · \(unsettled) unpaid" : ""))
        }
        if !tx.items.isEmpty {
            parts.append(String(tx.items.map(\.name).joined(separator: ", ").prefix(60)))
        }
        if foreign {
            parts.append(tx.fxRate != nil ? "≈ " + Money.format(abs(Insights.baseAmount(tx, cur)), cur) : "fetching rate…")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Icon and name, amount, date, category, and a menu — the table's columns.
    private var summaryRow: some View {
        HStack(spacing: 16) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Group {
                        if let image = Attachments.image(file: tx.imageFile, dataUrl: tx.imageDataUrl) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Icon(categoryIcon(tx.category), size: 18)
                                .foregroundStyle(p.accent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(p.mix(p.accent, 0.14))
                        }
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(tx.merchant).font(FN.bodyMedium).foregroundStyle(p.text).lineLimit(1)
                            if tx.noteId != nil {
                                Icon("link", size: 11).foregroundStyle(p.faint)
                            }
                        }
                        if let subtitle {
                            Text(subtitle).font(FN.small).foregroundStyle(p.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .frame(maxWidth: .infinity)

            Text((tx.amount < 0 ? "+" : "") + Money.format(abs(tx.amount), tx.currency))
                .font(FN.body).monospacedDigit()
                .foregroundStyle(tx.amount < 0 ? p.ok : p.text)
                .contentTransition(.numericText())
                .frame(width: TransactionHeader.amountWidth, alignment: .leading)

            Text(FinanceMath.shortDate(tx.date))
                .font(FN.body).monospacedDigit()
                .foregroundStyle(p.muted)
                .frame(width: TransactionHeader.dateWidth, alignment: .leading)

            MenuButton(help: "Change the category") {
                store.categories.map { c in
                    .item(c, checked: c == tx.category) { store.updateTransaction(tx.id) { $0.category = c } }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(p.accent).frame(width: 6, height: 6)
                    Text(tx.category).font(FN.small).foregroundStyle(p.text).lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(p.mix(p.accent, 0.10), in: Capsule())
            }
            .frame(width: TransactionHeader.categoryWidth, alignment: .leading)

            IconMenu("more", size: 16, box: 28, help: "More") {
                [
                    .item(open ? "Close" : "Edit / split") { onToggle() },
                    .divider,
                    .item("Delete", destructive: true) { store.remove(.transactions, tx.id) },
                ]
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 12)
    }

    private var editor: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                field("Merchant") {
                    CommittedField(placeholder: "Merchant", value: tx.merchant, boxed: true) { v in
                        store.updateTransaction(tx.id) { $0.merchant = v }
                    }
                }
                field("Date") {
                    DatePicker("", selection: Binding(
                        get: { DateKit.date(tx.date) ?? Date() },
                        set: { d in store.updateTransaction(tx.id) { $0.date = DateKit.localDate(d) } }),
                        displayedComponents: .date)
                        .labelsHidden()
                }
                field("Amount") {
                    AmountField(value: tx.amount, currency: tx.currency) { amount in
                        store.updateTransaction(tx.id) { $0.amount = amount }
                    }
                    .frame(width: 140)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                        .stroke(p.line, lineWidth: 1))
                }
                field("Currency") {
                    Picker("", selection: Binding(
                        get: { tx.currency },
                        set: { c in store.updateTransaction(tx.id) { $0.currency = c; $0.fxRate = nil } })) {
                            ForEach(currencyOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                }
                if foreign {
                    field("Rate: 1 \(tx.currency) = ? \(cur)") {
                        AmountField(value: tx.fxRate ?? 0, currency: cur) { rate in
                            if rate > 0 { store.updateTransaction(tx.id) { $0.fxRate = rate } }
                        }
                        .frame(width: 140)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                            .stroke(p.line, lineWidth: 1))
                    }
                }
                field("Linked note") {
                    Picker("", selection: Binding(
                        get: { tx.noteId ?? "" },
                        set: { id in store.updateTransaction(tx.id) { $0.noteId = id.isEmpty ? nil : id } })) {
                            Text("None").tag("")
                            ForEach(store.liveNotes) { n in
                                Text(n.title.isEmpty ? "Untitled" : n.title).tag(n.id)
                            }
                        }
                        .labelsHidden()
                }
                Button("Delete transaction", role: .destructive) {
                    store.remove(.transactions, tx.id)
                }
                .buttonStyle(.fn)
                .font(FN.body)
                .foregroundStyle(p.danger)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Split bill")
                SplitEditor(txId: tx.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }

    private var currencyOptions: [String] {
        var seen = Set<String>()
        return ([cur, tx.currency] + CURRENCIES).filter { seen.insert($0).inserted }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(FN.small).foregroundStyle(p.muted)
            content()
        }
    }
}

/// The table's column titles.
private struct TransactionHeader: View {
    @Environment(\.palette) private var p
    static let amountWidth: CGFloat = 130
    static let dateWidth: CGFloat = 70
    static let categoryWidth: CGFloat = 170

    var body: some View {
        HStack(spacing: 16) {
            title("Transaction").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 54)
            title("Amount").frame(width: Self.amountWidth, alignment: .leading)
            title("Date").frame(width: Self.dateWidth, alignment: .leading)
            title("Category").frame(width: Self.categoryWidth, alignment: .leading)
            Color.clear.frame(width: 28, height: 1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 10)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(FN.small).foregroundStyle(p.muted)
    }
}
