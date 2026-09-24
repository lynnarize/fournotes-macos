import AppKit
import SwiftUI

// Sticking a note sends it to the edge: a little paper note lifts off where
// the pointer is, tilts, and flies in an arc to the island beside the
// handle, shrinking into a drop that falls into the bubble. Drawn in a
// see-through window over the whole screen that ignores the mouse, and gone
// once it lands.

final class StickyFlightPanel: NSPanel {
    /// `from` and `to` in screen coordinates: the pointer, and the middle of
    /// the island's bubble the note drops into.
    init(from: CGPoint, to end: CGPoint, tint: StickyTint, title: String,
         landed: @escaping @MainActor () -> Void) {
        let screen = NSScreen.screens.first { $0.frame.contains(end) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        // Into the window's own top-left coordinates.
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
        let view = StickyFlightView(start: local(from), end: local(end), tint: tint, title: title) { [weak self] in
            landed()
            self?.orderOut(nil)
        }
        contentView = NSHostingView(rootView: view)
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct Flight {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat = 132
    var height: CGFloat = 96
    var radius: CGFloat = 10
    var rotation: Double = 0
    var scale: CGFloat = 0.4
    var opacity: Double = 0
    var text: Double = 1
}

struct StickyFlightView: View {
    let start: CGPoint
    let end: CGPoint
    let tint: StickyTint
    let title: String
    let landed: @MainActor () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var go = false

    /// Lift, then fly; the landing is the last few frames.
    private static let lift = 0.2
    private static let fly = 0.5

    var body: some View {
        let paper = StickyPaper.of(tint, dark: scheme == .dark)
        KeyframeAnimator(initialValue: Flight(x: start.x, y: start.y), trigger: go) { f in
            VStack(alignment: .leading, spacing: 6) {
                Text(title.isEmpty ? "Sticky note" : title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                ForEach(0..<3, id: \.self) { i in
                    Capsule().frame(width: [86, 100, 62][i], height: 3).opacity(0.35)
                }
            }
            .foregroundStyle(paper.text)
            .padding(12)
            .opacity(f.text)
            .frame(width: f.width, height: f.height, alignment: .topLeading)
            .background(paper.fill)
            .overlay(alignment: .top) {
                // A strip of tape across the top.
                Rectangle().fill(.white.opacity(0.45)).frame(width: 34, height: 10)
                    .rotationEffect(.degrees(-4)).offset(y: -4).opacity(f.text)
            }
            .clipShape(RoundedRectangle(cornerRadius: f.radius, style: .continuous))
            .shadow(color: .black.opacity(0.28 * f.text), radius: 14, y: 8)
            .scaleEffect(f.scale)
            .rotationEffect(.degrees(f.rotation))
            .opacity(f.opacity)
            .position(x: f.x, y: f.y)
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                LinearKeyframe(start.x, duration: Self.lift)
                // Slow to leave, fast to arrive: with y the other way round,
                // the path bends into an arc.
                LinearKeyframe(end.x, duration: Self.fly, timingCurve: .easeIn)
            }
            KeyframeTrack(\.y) {
                LinearKeyframe(start.y - 16, duration: Self.lift, timingCurve: .easeOut)
                LinearKeyframe(end.y, duration: Self.fly, timingCurve: .easeOut)
            }
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.04, duration: Self.lift, spring: .snappy)
                LinearKeyframe(1, duration: Self.fly)
            }
            KeyframeTrack(\.rotation) {
                SpringKeyframe(-8, duration: Self.lift, spring: .snappy)
                LinearKeyframe(0, duration: Self.fly, timingCurve: .easeIn)
            }
            KeyframeTrack(\.opacity) {
                LinearKeyframe(1, duration: 0.1)
                LinearKeyframe(1, duration: Self.lift + Self.fly - 0.1)
                LinearKeyframe(0, duration: 0.08)
            }
            KeyframeTrack(\.width) {
                LinearKeyframe(132, duration: Self.lift)
                LinearKeyframe(14, duration: Self.fly, timingCurve: .easeIn)
            }
            KeyframeTrack(\.height) {
                LinearKeyframe(96, duration: Self.lift)
                LinearKeyframe(14, duration: Self.fly, timingCurve: .easeIn)
            }
            KeyframeTrack(\.radius) {
                LinearKeyframe(10, duration: Self.lift)
                LinearKeyframe(7, duration: Self.fly)
            }
            KeyframeTrack(\.text) {
                LinearKeyframe(1, duration: Self.lift + Self.fly * 0.3)
                LinearKeyframe(0, duration: Self.fly * 0.4)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            go = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lift + Self.fly - 0.02) { landed() }
        }
    }
}
