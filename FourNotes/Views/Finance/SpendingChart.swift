import SwiftUI

// Line chart with a soft fill, a dotted average line and a hover tooltip.
// `values` may be shorter than `total` (the rest of the month hasn't happened yet).
// Ported from the LineChart in src/components/finance/Dashboard.tsx.

struct SpendingChart: View {
    @Environment(\.palette) private var p

    let values: [Double]
    let total: Int
    let currency: String
    /// The tooltip's caption for a point, e.g. "14 Mar".
    let label: (Int) -> String
    let ticks: [(at: Int, text: String)]
    var pill: Int?

    @State private var hover: Int?

    private var maxValue: Double { max(1, values.max() ?? 1) * 1.15 }
    private var average: Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
    private var active: Int? { hover ?? (values.isEmpty ? nil : values.count - 1) }

    private func xFraction(_ i: Int) -> Double {
        total > 1 ? Double(i) / Double(total - 1) : 0.5
    }

    private func yFraction(_ v: Double) -> Double {
        1 - (v / maxValue)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            yAxis
            VStack(spacing: 0) {
                plot
                xAxis
            }
        }
        .entrance()
    }

    private var yAxis: some View {
        VStack(alignment: .trailing) {
            ForEach([1.0, 0.75, 0.5, 0.25, 0.0], id: \.self) { f in
                Text(Money.format(maxValue * f, currency, compact: true))
                if f > 0 { Spacer(minLength: 0) }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(p.faint)
        .frame(height: 168)
    }

    private func point(_ i: Int, _ size: CGSize) -> CGPoint {
        CGPoint(x: xFraction(i) * size.width, y: yFraction(values[i]) * size.height)
    }

    private func linePath(_ size: CGSize) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        path.move(to: point(0, size))
        for i in 1..<values.count { path.addLine(to: point(i, size)) }
        return path
    }

    private func areaPath(_ size: CGSize) -> Path {
        var path = linePath(size)
        guard values.count > 1 else { return path }
        path.addLine(to: CGPoint(x: point(values.count - 1, size).x, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private var plot: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Soft fill under the line.
                areaPath(size)
                    .fill(LinearGradient(
                        colors: [p.accent.opacity(0.22), p.accent.opacity(0)],
                        startPoint: .top, endPoint: .bottom))

                // The line itself.
                linePath(size)
                    .stroke(p.accent, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                // Dotted average line, with its tag.
                if !values.isEmpty {
                    let y = yFraction(average) * size.height
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    .stroke(p.text.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 6]))

                    averageTag.offset(y: y - 9)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }

                // Hover point and tooltip.
                if let active, values.indices.contains(active) {
                    let pt = point(active, size)
                    Circle()
                        .fill(p.accent)
                        .overlay(Circle().stroke(p.bg, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .position(pt)

                    tooltip(active)
                        .fixedSize()
                        .offset(x: tooltipX(pt.x, width: size.width), y: max(0, pt.y - 56))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard !values.isEmpty, total > 1, size.width > 0 else { return }
                    let i = Int(((location.x / size.width) * Double(total - 1)).rounded())
                    hover = min(max(0, i), values.count - 1)
                case .ended:
                    hover = nil
                }
            }
            .animation(Motion.standard, value: hover)
            .animation(Motion.data, value: values)
        }
        .frame(height: 168)
    }

    /// Keeps the tooltip inside the plot, matching the web version's flip points.
    private func tooltipX(_ x: Double, width: Double) -> Double {
        let fraction = width > 0 ? x / width : 0
        if fraction > 0.7 { return x - 140 }
        if fraction > 0.3 { return x - 70 }
        return x
    }

    private var averageTag: some View {
        Text("Avg \(Money.format(average, currency, compact: true))")
            .font(FN.font(11, .medium))
            .foregroundStyle(p.bg)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 2)
            .background(p.text, in: ChartTagShape())
    }

    private func tooltip(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label(index)).font(FN.small).foregroundStyle(p.muted)
            MoneyText(amount: values[index], currency: currency, size: 16, weight: .semibold)
                .foregroundStyle(p.text)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(p.bg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.line, lineWidth: 1))
        .shadow(color: p.shadow, radius: 8, y: 2)
        .allowsHitTesting(false)
    }

    private var xAxis: some View {
        GeometryReader { geo in
            ForEach(ticks, id: \.at) { tick in
                Text(tick.text)
                    .font(FN.small)
                    .fontWeight(tick.at == (hover ?? pill) ? .medium : .regular)
                    .foregroundStyle(tick.at == (hover ?? pill) ? p.accent : p.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tick.at == (hover ?? pill) ? p.accent.opacity(0.14) : .clear,
                                in: Capsule())
                    .position(x: xFraction(tick.at) * geo.size.width, y: 14)
            }
        }
        .frame(height: 28)
        .padding(.top, 8)
    }
}

/// The dark "Avg …" tag on the chart's average line, with its arrow point.
private struct ChartTagShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let notch: CGFloat = 7
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - notch, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
