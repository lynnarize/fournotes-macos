import CoreGraphics

// Where the sticky notes show, as plain numbers so it can be tested.
//
// Each stuck note is its own bubble that splits off the dock's handle, the
// way the Dynamic Island splits in two: when the pointer reaches the handle
// the bubbles pull out of its top and bottom and snap free along the edge —
// the first above, the next below, then further out. Pointing at a bubble
// stretches it into a pill with the note's title; a click pops the note out
// into its own window beside the edge. Moving away draws them all back into the handle.

enum StickyTint: String, CaseIterable, Codable, Sendable {
    case yellow, pink, blue, green, violet
}

struct StickyPlacement: Codable, Equatable, Sendable {
    var noteId: String
    var color = StickyTint.yellow
}

enum StickyGeometry {
    // The bubbles
    static let bubble: CGFloat = 36
    /// Between the handle and the first bubble on a side, and between bubbles.
    static let bubbleGap: CGFloat = 12
    /// From the screen edge to a bubble.
    static let bubbleInset: CGFloat = 3
    /// A bubble stretched out under the pointer, into the screen.
    static let pillWidth: CGFloat = 232
    /// Bubbles shown at most; the rest are in the handle's menu.
    static let maxBubbles = 8
    /// Room round the bubbles for their shadow.
    static let islandMargin: CGFloat = 16

    /// Centres on screen for `count` bubbles beside a handle centred at
    /// `handleY`: above it, below it, above again, … — skipping places off
    /// the screen, and sharing the last place when the edge is full.
    static func bubbleSlots(count: Int, handleY: CGFloat, in visible: CGRect) -> [CGFloat] {
        guard count > 0 else { return [] }
        let first = DockGeometry.handleHeight / 2 + bubbleGap + bubble / 2
        let step = bubble + bubbleGap
        let reach = bubble / 2 + 4
        var above: [CGFloat] = []
        var y = handleY + first
        while y + reach <= visible.maxY { above.append(y); y += step }
        var below: [CGFloat] = []
        y = handleY - first
        while y - reach >= visible.minY { below.append(y); y -= step }

        // Alternate while both sides have room, then carry on with whichever does.
        var out: [CGFloat] = []
        var a = above[...], b = below[...]
        var takeAbove = true
        while out.count < count {
            if takeAbove, let next = a.popFirst() ?? b.popFirst() {
                out.append(next)
            } else if !takeAbove, let next = b.popFirst() ?? a.popFirst() {
                out.append(next)
            } else {
                out.append(out.last ?? clamp(handleY, visible.minY + reach, visible.maxY - reach))
            }
            takeAbove.toggle()
        }
        return out
    }

    /// The dock's window while the bubbles are out: the handle's, taller to
    /// hold them and wider to hold one stretched into a pill — or, not
    /// `wide`, only as wide as the bubbles, resting beside an open note.
    static func islandWindow(handle: CGRect, edge: DockEdge, slots: [CGFloat], wide: Bool = true) -> CGRect {
        guard let top = slots.max(), let bottom = slots.min() else { return handle }
        let reach = bubbleInset + (wide ? pillWidth : bubble) + islandMargin
        let x = edge == .right ? handle.maxX - reach : handle.minX
        let minY = bottom - bubble / 2 - islandMargin
        let maxY = top + bubble / 2 + islandMargin
        return CGRect(x: x, y: minY, width: reach, height: maxY - minY).union(handle)
    }

    /// A bubble centred `centerY` from the top of a window `width` wide
    /// (top-left coordinates, like SwiftUI's).
    static func bubbleRect(width: CGFloat, edge: DockEdge, centerY: CGFloat) -> CGRect {
        let x = edge == .right ? width - bubbleInset - bubble : bubbleInset
        return CGRect(x: x, y: centerY - bubble / 2, width: bubble, height: bubble)
    }

    /// The same bubble stretched into a pill, into the screen from where it sits.
    static func pillRect(width: CGFloat, edge: DockEdge, centerY: CGFloat) -> CGRect {
        let x = edge == .right ? width - bubbleInset - pillWidth : bubbleInset
        return CGRect(x: x, y: centerY - bubble / 2, width: pillWidth, height: bubble)
    }

    // Open: the note's own window beside the edge
    static let paperWidth: CGFloat = 300
    static let paperHeight: CGFloat = 340
    /// Room round the paper for its shadow, and for it to pop out.
    static let windowMargin: CGFloat = 36
    /// From the screen edge to the paper: clear of the bubbles, and of the
    /// dock's window while they rest beside it.
    static let edgeGap: CGFloat = 60
    /// The strip along the paper's top it's dragged by.
    static let stripHeight: CGFloat = 30
    /// Each note opened onto the same place moves along by this much.
    static let cascade: CGFloat = 28

    static var windowSize: CGSize {
        CGSize(width: paperWidth + 2 * windowMargin, height: paperHeight + 2 * windowMargin)
    }

    /// Where a note opens: beside the edge, level with `anchor` (the bubble
    /// it came out of), its paper kept on screen — and moved along from any
    /// note already open in the same place.
    static func window(anchor: CGPoint, edge: DockEdge, in visible: CGRect,
                       avoiding taken: [CGRect] = []) -> CGRect {
        let size = windowSize
        let x = edge == .right
            ? visible.maxX - edgeGap - paperWidth - windowMargin
            : visible.minX + edgeGap - windowMargin
        func onScreen(_ f: CGRect) -> CGRect {
            let m = windowMargin
            return CGRect(x: clamp(f.minX, visible.minX - m, visible.maxX - size.width + m),
                          y: clamp(f.minY, visible.minY - m, visible.maxY - size.height + m),
                          width: size.width, height: size.height)
        }
        var frame = onScreen(CGRect(x: x, y: anchor.y - size.height / 2, width: size.width, height: size.height))
        for _ in 0..<12 {
            guard taken.contains(where: { abs($0.minX - frame.minX) < 8 && abs($0.minY - frame.minY) < 8 })
            else { break }
            frame.origin.x += edge == .right ? -cascade : cascade
            frame.origin.y -= cascade
            frame = onScreen(frame)
        }
        return frame
    }

    /// How far to move a note's `paper` that was let go partly off screen,
    /// so its top strip — what it's dragged by — is still on the screen, and
    /// enough of it across to take hold of.
    static func keepGrabbable(_ paper: CGRect, in visible: CGRect) -> CGVector {
        let strip = stripHeight, across: CGFloat = 80
        var dx: CGFloat = 0, dy: CGFloat = 0
        if paper.maxY > visible.maxY {
            dy = visible.maxY - paper.maxY
        } else if paper.maxY - strip < visible.minY {
            dy = visible.minY + strip - paper.maxY
        }
        if paper.maxX < visible.minX + across {
            dx = visible.minX + across - paper.maxX
        } else if paper.minX > visible.maxX - across {
            dx = visible.maxX - across - paper.minX
        }
        return CGVector(dx: dx, dy: dy)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo > hi ? (lo + hi) / 2 : min(hi, max(lo, v))
    }
}
