import SwiftUI

// Empty state that teaches: click an example and the assistant does it, so the
// first item in the app is the user's own rather than seeded demo data.
// Ported from src/components/EmptyStart.tsx.

struct EmptyStart<Extra: View>: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var store: Store

    let title: String
    let hint: String
    let prompts: [String]
    var showSample = true
    @ViewBuilder var extra: () -> Extra

    init(title: String, hint: String, prompts: [String], showSample: Bool = true,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.title = title; self.hint = hint; self.prompts = prompts
        self.showSample = showSample; self.extra = extra
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(FN.serif(18)).foregroundStyle(p.text)
            Text(hint)
                .font(FN.body)
                .foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            FlowLayout(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    PromptChip(prompt: prompt, disabled: assistant.busy != nil) {
                        Task { await assistant.send(prompt) }
                    }
                }
            }
            .padding(.top, 12)

            HStack(spacing: 8) {
                extra()
                if showSample && !store.hasSamples {
                    GhostButton(action: { store.loadSamples() }) {
                        Text("Explore with sample data")
                    }
                }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(p.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .entrance()
    }
}

private struct PromptChip: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let prompt: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("“\(prompt)”")
                .font(FN.body)
                .foregroundStyle(hovering ? p.text : p.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(hovering ? p.hover : .clear, in: Capsule())
                .overlay(Capsule().stroke(p.line, lineWidth: 1))
                .scaleEffect(hovering ? 1.02 : 1)
                .motion(hovering, Motion.quick)
                .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 && !disabled }
    }
}

/// Wraps its children onto as many lines as it needs, like `flex-wrap`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .center

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews, in: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x: CGFloat
            switch alignment {
            case .leading: x = bounds.minX
            case .trailing: x = bounds.maxX - row.width
            default: x = bounds.minX + (bounds.width - row.width) / 2
            }
            for index in row.indices {
                let size = Self.measure(subviews[index], within: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// An item's natural size — or, when that is wider than the whole row,
    /// the size it takes at the row's width. Placing it at its natural width
    /// let a long date chip run out of its card and across the next column.
    private static func measure(_ subview: LayoutSubview, within maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, natural.width > maxWidth else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(_ subviews: Subviews, in maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = Self.measure(subviews[index], within: maxWidth)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
