import SwiftUI

// A body that grows out of the screen edge: rounded on the side facing the
// screen, flush against the edge, and joined to it above and below by small
// inward curves, so it reads as part of the edge rather than a card laid on
// top. Drawn for the right edge; the left edge mirrors it.
//
// Every measurement is animatable, so the handle and the drawer are one
// shape at two sizes and opening is a single spring between them.

struct EdgeTabShape: Shape {
    /// The body's vertical centre, from the top of the rect.
    var centerY: CGFloat
    var width: CGFloat
    var height: CGFloat
    var corner: CGFloat
    var fillet: CGFloat
    /// Drawn against the left edge instead.
    var mirrored = false

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(AnimatablePair(centerY, width), AnimatablePair(height, AnimatablePair(corner, fillet))) }
        set {
            centerY = newValue.first.first
            width = newValue.first.second
            height = newValue.second.first
            corner = newValue.second.second.first
            fillet = newValue.second.second.second
        }
    }

    init(_ g: DockGeometry, mirrored: Bool = false) {
        self.mirrored = mirrored
        centerY = g.centerFromTop
        width = g.bodyWidth
        height = g.bodyHeight
        corner = g.corner
        fillet = g.fillet
    }

    func path(in rect: CGRect) -> Path {
        let edge = rect.maxX
        let left = edge - width
        let top = centerY - height / 2
        let bottom = centerY + height / 2
        let r = max(0, min(corner, width, height / 2))
        let f = max(0, min(fillet, height / 2))

        var p = Path()
        p.move(to: CGPoint(x: edge, y: top - f))
        // Inward curve from the edge into the top side.
        p.addArc(tangent1End: CGPoint(x: edge, y: top), tangent2End: CGPoint(x: left, y: top), radius: f)
        p.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: edge, y: bottom), radius: r)
        p.addArc(tangent1End: CGPoint(x: edge, y: bottom), tangent2End: CGPoint(x: edge, y: bottom + f), radius: f)
        p.addLine(to: CGPoint(x: edge, y: bottom + f))
        p.closeSubpath()
        guard mirrored else { return p }
        return p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
}
