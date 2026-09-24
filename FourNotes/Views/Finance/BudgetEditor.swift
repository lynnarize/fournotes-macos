import SwiftUI

// Monthly budget per category, with this month's spending for context.
// Used in Finance -> Budgets and in Settings.
// Ported from src/components/BudgetEditor.tsx.

struct BudgetEditor: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store

    private var cur: String { store.settings.currency }
    private var budgetable: [String] { store.categories.filter { $0 != "Income" } }

    private var spent: [String: Double] {
        let month = DateKit.localMonth()
        return Insights.spendByCategory(store.liveTransactions.filter { $0.date.hasPrefix(month) }, cur)
    }

    private var total: Double {
        budgetable.reduce(0) { $0 + (store.settings.budgets[$1] ?? 0) }
    }

    var body: some View {
        let spent = spent
        VStack(alignment: .leading, spacing: 12) {
            Text("Set a monthly limit for each category in \(cur). Type amounts like **1.5M** or **600k**. Leave a field empty for no budget.")
                .font(FN.small)
                .foregroundStyle(p.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(budgetable, id: \.self) { category in
                    row(category, used: spent[category] ?? 0)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    if category != budgetable.last {
                        Divider().overlay(p.line)
                    }
                }
            }
            .animation(Motion.list, value: budgetable)

            Divider().overlay(p.line)
            HStack {
                Text("Total monthly budget").font(FN.body).foregroundStyle(p.muted)
                Spacer()
                Text(Money.format(total, cur))
                    .font(FN.font(14, .semibold)).monospacedDigit().foregroundStyle(p.text)
                    .contentTransition(.numericText())
                    .motion(total, Motion.data)
            }
        }
    }

    private func row(_ category: String, used: Double) -> some View {
        let limit = store.settings.budgets[category] ?? 0
        let ratio = limit > 0 ? used / limit : 0
        let tone: Color = ratio >= 1 ? p.danger : (ratio >= 0.8 ? .hex(0xD9730D) : p.ok)

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category).font(FN.bodyMedium).foregroundStyle(p.text)
                Text(Money.format(used, cur, compact: true) + " spent this month"
                     + (limit > 0 ? " · \(Int((ratio * 100).rounded()))% of budget" : ""))
                    .font(FN.small).foregroundStyle(p.muted)
                if limit > 0 {
                    ProgressBar(ratio: ratio, tone: tone, height: 4).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AmountField(value: limit, currency: cur) { amount in
                store.setBudget(category, amount > 0 ? amount : nil)
            }
            .padding(.horizontal, 10)
            .frame(width: 124, height: 34)
            .background(p.hover, in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
            .motion(limit, Motion.quick)
        }
        .padding(.vertical, 10)
    }
}
