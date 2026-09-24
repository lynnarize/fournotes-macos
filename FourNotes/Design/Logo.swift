import SwiftUI

// Four Notes logo: red "4" over a black "N" with a red dot.
// Vector trace of the brand artwork; the "N" uses the ink token so it stays
// visible in dark mode. Same geometry as src/components/Logo.tsx.

struct Logo: View {
    @Environment(\.palette) private var p
    var size: CGFloat = 32

    private static let viewBox = CGRect(x: 113, y: 140, width: 1000, height: 1000)

    private static let nPath =
        "M535,375 L625,375 L985,898 L988,378 L1073,378 L1075,1012 L950,1012 L601,493 L601,1012 L535,1012 Z"
    private static let fourPath =
        "M460 375H535V795H631V867H535V1012H450V870H145V795Z M452 500L450 795H232Z"

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / Logo.viewBox.width
            let transform = CGAffineTransform(translationX: -Logo.viewBox.minX, y: -Logo.viewBox.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))

            let box = CGRect(origin: .zero, size: CGSize(width: Logo.viewBox.width, height: Logo.viewBox.height))
            var n = SVGPath.path(from: Logo.nPath, in: box, viewBox: box.size)
            n = n.applying(transform)
            context.fill(n, with: .color(p.logoInk))

            var four = SVGPath.path(from: Logo.fourPath, in: box, viewBox: box.size)
            four = four.applying(transform)
            context.fill(four, with: .color(p.logoRed), style: FillStyle(eoFill: true))

            // The dot on the "N".
            let dot = Path(ellipseIn: CGRect(x: 1031 - 50, y: 318 - 50, width: 100, height: 100).applying(transform))
            context.fill(dot, with: .color(p.logoRed))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The wordmark used in the sidebar header.
struct LogoWordmark: View {
    @Environment(\.palette) private var p
    var logoSize: CGFloat = 40
    var fontSize: CGFloat = 21

    var body: some View {
        HStack(spacing: 9) {
            Logo(size: logoSize)
            Text("Four Notes")
                .font(FN.font(fontSize, .bold))
                .tracking(-0.4)
                .foregroundStyle(p.text)
                .fixedSize()
        }
    }
}
