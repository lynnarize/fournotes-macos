import SwiftUI

// A soft wash of warm and cool light over the page colour: the first-run
// setup's background, and Today's. Radial glows, not a mesh — cheap to draw,
// so it can sit behind a scrolling page.

struct CalmBackground: View {
    var base: Color
    var warm: Color
    var cool: Color
    /// How strong the glows are, 0…1.
    var glow: Double = 0.55
    var dark = false
    /// Drift slowly. Off behind pages that scroll.
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                    wash(t: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                wash(t: 0)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: glow)
    }

    private func wash(t: Double) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                base
                blob(warm, size: size, x: 0.42 + 0.05 * sin(t / 7), y: 0.28 + 0.04 * cos(t / 9), scale: 0.95)
                blob(cool, size: size, x: 0.82 + 0.04 * cos(t / 8), y: 0.82 + 0.05 * sin(t / 6), scale: 0.85)
                blob(warm.opacity(0.7), size: size, x: 0.1, y: 0.95, scale: 0.6)
            }
        }
    }

    private func blob(_ color: Color, size: CGSize, x: Double, y: Double, scale: Double) -> some View {
        let d = max(size.width, size.height) * scale
        return Circle()
            .fill(RadialGradient(colors: [color.opacity(glow), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: d / 2))
            .frame(width: d, height: d)
            .position(x: size.width * x, y: size.height * y)
            .blendMode(dark ? .plusLighter : .normal)
    }
}

extension CalmBackground {
    /// Today's: the page colour, with the setup's light kept quieter.
    static func page(_ p: Palette, theme: ThemeChoice, scheme: ColorScheme) -> CalmBackground {
        if scheme == .dark {
            return CalmBackground(base: p.bg, warm: .hex(0x5A2E26), cool: .hex(0x1F3550), glow: 0.42, dark: true)
        }
        if theme == .paper {
            return CalmBackground(base: p.bg, warm: .hex(0xF2C9A8), cool: .hex(0xD3E1D6), glow: 0.5)
        }
        return CalmBackground(base: p.bg, warm: .hex(0xF6C7B6), cool: .hex(0xC9DDF3), glow: 0.45)
    }
}
