import SwiftUI

/// One motion vocabulary for the whole app. Durations stay short so the UI
/// feels responsive, while springs keep state changes from snapping.
enum Motion {
    static let instant = Animation.linear(duration: 0)
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// Reduce Motion is on: move nothing that doesn't have to.
    static var reduce: Bool { reduceMotion }

    static var quick: Animation {
        reduceMotion ? instant : .easeOut(duration: 0.14)
    }
    static var standard: Animation {
        reduceMotion ? instant : .spring(response: 0.30, dampingFraction: 0.86)
    }
    static var screen: Animation {
        reduceMotion ? instant : .spring(response: 0.38, dampingFraction: 0.90)
    }
    static var list: Animation {
        reduceMotion ? instant : .spring(response: 0.34, dampingFraction: 0.84)
    }
    static var data: Animation {
        reduceMotion ? instant : .spring(response: 0.48, dampingFraction: 0.92)
    }
    static var flash: Animation {
        reduceMotion ? instant : .easeInOut(duration: 0.42)
    }
    static var pulse: Animation {
        reduceMotion ? instant
            : .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value
    let animation: Animation

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? Motion.instant : animation, value: value)
    }
}

extension View {
    /// Animates only changes tied to `value`, keeping unrelated store updates quiet.
    func motion<Value: Equatable>(_ value: Value,
                                  _ animation: Animation = Motion.standard) -> some View {
        modifier(MotionModifier(value: value, animation: animation))
    }

    /// A restrained entrance for cards, sheets and major content regions.
    func entrance(delay: Double = 0) -> some View {
        modifier(EntranceModifier(delay: delay))
    }

    /// Background highlight used by assistant-created rows and active states.
    func flash(_ on: Bool, palette: Palette) -> some View {
        modifier(FlashModifier(on: on, palette: palette))
    }
}

private struct EntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Motion.screen.delay(delay)) { shown = true }
                }
            }
            .onChange(of: reduceMotion) { _, reduce in
                if reduce { shown = true }
            }
    }
}

private struct FlashModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let on: Bool
    let palette: Palette

    func body(content: Content) -> some View {
        content
            .background(on ? palette.accent.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
            .animation(reduceMotion ? Motion.instant : Motion.flash, value: on)
    }
}

extension OpenURLAction {
    /// Opens http and https links; anything else a model wrote — file://,
    /// x-apple.systempreferences:, an app's own scheme — is ignored.
    static let webOnly = OpenURLAction { url in
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
    }
}

/// Replaces `.plain` so custom buttons get the same tactile press response.
struct FNPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(reduceMotion ? Motion.instant : Motion.quick,
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == FNPressButtonStyle {
    static var fn: FNPressButtonStyle { FNPressButtonStyle() }
}
