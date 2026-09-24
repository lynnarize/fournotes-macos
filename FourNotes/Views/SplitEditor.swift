import SwiftUI

// Split a bill: equal split in one step, then fine-tune amounts and mark
// people as paid. Ported from src/components/SplitEditor.tsx.

struct SplitEditor: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store

    let txId: String
    @State private var names = ""
    @State private var includeMe = true

    private var tx: Transaction? { store.transactions.first { $0.id == txId } }

    var body: some View {
        if let tx {
            let splits = tx.splits ?? []
            let others = splits.reduce(0) { $0 + $1.amount }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tx.merchant).font(FN.bodyMedium).foregroundStyle(p.text)
                    Spacer()
                    Text(Money.format(tx.amount, tx.currency))
                        .font(FN.body).monospacedDigit().foregroundStyle(p.text)
                        .contentTransition(.numericText())
                }

                if !splits.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(Array(splits.enumerated()), id: \.element.name) { index, split in
                            splitRow(tx: tx, splits: splits, index: index, split: split)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.list, value: splits.map(\.name))
                }

                HStack(spacing: 8) {
                    BoxedField(placeholder: "Split with… (Andi, Budi)", text: $names) {
                        addPeople(tx: tx, splits: splits)
                    }
                    Toggle("incl. me", isOn: $includeMe)
                        .toggleStyle(.checkbox)
                        .font(FN.small)
                        .foregroundStyle(p.muted)
                    SecondaryButton(title: "Split equally") { addPeople(tx: tx, splits: splits) }
                }

                Divider().overlay(p.line)

                HStack {
                    Text("Others owe \(Money.format(splits.filter { !$0.settled }.reduce(0) { $0 + $1.amount }, tx.currency))")
                        .contentTransition(.numericText())
                    Spacer()
                    Text("Your share \(Money.format(Insights.myShare(tx, store.settings.currency), store.settings.currency))"
                         + (others > tx.amount ? " ⚠️ more than total" : ""))
                        .contentTransition(.numericText())
                }
                .font(FN.small)
                .foregroundStyle(p.muted)
            }
            .font(FN.body)
        } else {
            Text("Transaction not found.").font(FN.body).foregroundStyle(p.muted)
        }
    }

    private func splitRow(tx: Transaction, splits: [Split], index: Int, split: Split) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { split.settled },
                set: { settled in
                    var next = splits
                    next[index].settled = settled
                    store.updateTransaction(tx.id) { $0.splits = next }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(split.name) paid")

            CommittedField(placeholder: "Name", value: split.name) { name in
                guard !name.isEmpty else { return }
                var next = splits
                next[index].name = name
                store.updateTransaction(tx.id) { $0.splits = next }
            }
            .foregroundStyle(split.settled ? p.faint : p.text)
            .strikethrough(split.settled)
            .motion(split.settled, Motion.quick)

            AmountField(value: split.amount, currency: tx.currency) { amount in
                var next = splits
                next[index].amount = amount
                store.updateTransaction(tx.id) { $0.splits = next }
            }
            .frame(width: 110)

            IconButton("x", size: 12, box: 24, help: "Remove \(split.name)") {
                var next = splits
                next.remove(at: index)
                store.updateTransaction(tx.id) { $0.splits = next }
            }
        }
    }

    private func addPeople(tx: Transaction, splits: [Split]) {
        let people = names
            .components(separatedBy: CharacterSet(charactersIn: ",&"))
            .flatMap { $0.components(separatedBy: " and ") }
            .flatMap { $0.components(separatedBy: " dan ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !people.isEmpty else { return }

        let added = people.filter { person in
            !splits.contains { $0.name.lowercased() == person.lowercased() }
        }
        guard !added.isEmpty else { names = ""; return }

        // An equal share of the whole bill, counting everyone now involved.
        let headcount = splits.count + added.count + (includeMe ? 1 : 0)
        let share = headcount > 0 ? (tx.amount / Double(headcount) * 100).rounded() / 100 : 0

        // Amounts already on the sheet are left alone: they may have been
        // adjusted by hand, and recomputing them threw that away silently.
        let next = splits + added.map { Split(name: $0, amount: share, settled: false) }
        store.updateTransaction(tx.id) { $0.splits = next }
        names = ""
    }
}

/// A right-aligned money field that parses "150k" / "1,5jt" on commit.
struct AmountField: View {
    @Environment(\.palette) private var p
    let value: Double
    let currency: String
    var placeholder = "0"
    var alignment: TextAlignment = .trailing
    /// Emptying the field commits zero — for an optional amount, like a
    /// task's bill, where clearing it is how you remove it.
    var emptyIsZero = false
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .monospacedDigit()
            .foregroundStyle(p.text)
            .focused($focused)
            .onAppear { text = display }
            .onChange(of: value) { _, _ in if !focused { text = display } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    text = value == 0 ? "" : trimmed(value)
                } else {
                    commit()
                }
            }
            .onSubmit(commit)
    }

    private var display: String { value == 0 ? "" : trimmed(value) }

    private func trimmed(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        // A rate like 0.000065 must not render as "6.5e-05": the user has to be
        // able to read it back in.
        if v != v.rounded(), abs(v) < 0.001 { return String(format: "%.8f", v) }
        return v == v.rounded() ? String(Int(safe: v)) : String(v)
    }

    private func commit() {
        if emptyIsZero, text.trimmingCharacters(in: .whitespaces).isEmpty {
            if value != 0 { onCommit(0) }
        } else if let parsed = Money.parse(text) {
            onCommit(parsed)
        }
        text = display
    }
}

/// The split editor as a sheet, used from the chat dock and Finance.
struct SplitEditorSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let txId: String

    var body: some View {
        SheetFrame(title: "Split bill") {
            SplitEditor(txId: txId)
        }
    }
}

/// The app's modal chrome: a title bar that stays put while the content scrolls.
struct SheetFrame<Content: View>: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    let title: String
    var width: CGFloat = 520
    var maxHeight: CGFloat = 640
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(FN.serif(19)).foregroundStyle(p.text)
                Spacer()
                IconButton("x", size: 18, box: 30, help: "Close") { dismiss() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().overlay(p.line)

            ScrollView {
                content()
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .background(p.bg)
        .entrance()
    }
}
