import CoreGraphics

// Where the sticky notes show, as plain numbers so it can be tested.
//
// Each stuck note is its own bubble that splits off the dock's handle, the
// way the Dynamic Island splits in two: when the pointer reaches the handle
// the bubbles pull out of its top and bottom and snap free along the edge —
// the first above, the next below, then further out. Pointing at a bubble
// stretches it into a pill with the note's title; a click grows the handle
// into the note. Moving away draws them all back into the handle.

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
    /// hold them and wider to hold one stretched into a pill.
    static func islandWindow(handle: CGRect, edge: DockEdge, slots: [CGFloat]) -> CGRect {
        guard let top = slots.max(), let bottom = slots.min() else { return handle }
        let reach = bubbleInset + pillWidth + islandMargin
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

    // Open
    static let noteWidth: CGFloat = 300
    static let noteHeight: CGFloat = 280
    static let noteCorner: CGFloat = 24
    static let noteFillet: CGFloat = 26
    /// Room around the open note for its shadow.
    static let margin: CGFloat = 20

    /// The open note, grown out of the handle and centred on it as far as the
    /// screen allows.
    static func note(in visible: CGRect, edge: DockEdge, centerY: CGFloat) -> DockGeometry {
        let reach = noteHeight / 2 + noteFillet
        let cy = clamp(centerY, visible.minY + reach, visible.maxY - reach)
        let width = noteWidth + margin
        let height = noteHeight + 2 * (noteFillet + margin)
        let x = edge == .right ? visible.maxX - width : visible.minX
        let frame = CGRect(x: x, y: cy - height / 2, width: width, height: height)
        return DockGeometry(frame: frame, centerFromTop: height / 2, bodyWidth: noteWidth,
                            bodyHeight: noteHeight, corner: noteCorner, fillet: noteFillet)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo > hi ? (lo + hi) / 2 : min(hi, max(lo, v))
    }
}
