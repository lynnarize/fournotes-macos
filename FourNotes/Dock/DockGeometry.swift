import CoreGraphics

// Where the edge dock sits, as plain numbers so it can be tested.
//
// The dock is one borderless window hugging the screen edge. Closed, it is
// just big enough for the handle; open, big enough for the drawer. The shape
// inside grows from one to the other, so both layouts are worked out here in
// the same terms: a window frame in screen coordinates, and the body's
// vertical centre measured from the window's top, which is what SwiftUI uses.

enum DockEdge: String, CaseIterable, Sendable {
    case right, left
}

struct DockGeometry: Equatable, Sendable {
    // Handle
    static let handleWidth: CGFloat = 26
    static let handlePeekWidth: CGFloat = 38
    static let handleHeight: CGFloat = 64
    static let handleCorner: CGFloat = 13
    static let handleFillet: CGFloat = 14
    // Drawer
    static let drawerWidth: CGFloat = 724
    static let drawerMaxHeight: CGFloat = 660
    static let drawerCorner: CGFloat = 26
    static let drawerFillet: CGFloat = 30
    /// Room around the drawer for its shadow.
    static let margin: CGFloat = 26
    /// Around the handle: small, because the window's empty corners still
    /// catch clicks meant for whatever is under them.
    static let handleMargin: CGFloat = 8

    /// Screen coordinates (origin bottom-left).
    var frame: CGRect
    /// The body's vertical centre, from the window's top.
    var centerFromTop: CGFloat
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var corner: CGFloat
    var fillet: CGFloat

    /// The handle, centred at `centerY` (screen coordinates), kept on screen.
    static func handle(in visible: CGRect, edge: DockEdge, centerY: CGFloat) -> DockGeometry {
        let reach = handleHeight / 2 + handleFillet
        let cy = clamp(centerY, visible.minY + reach, visible.maxY - reach)
        let width = handlePeekWidth + handleMargin
        let height = handleHeight + 2 * (handleFillet + handleMargin)
        let x = edge == .right ? visible.maxX - width : visible.minX
        let frame = CGRect(x: x, y: cy - height / 2, width: width, height: height)
        return DockGeometry(frame: frame, centerFromTop: height / 2, bodyWidth: handleWidth,
                            bodyHeight: handleHeight, corner: handleCorner, fillet: handleFillet)
    }

    /// The drawer, centred on the handle as far as the screen allows.
    static func drawer(in visible: CGRect, edge: DockEdge, centerY: CGFloat) -> DockGeometry {
        let bodyHeight = max(handleHeight, min(drawerMaxHeight, visible.height - 2 * drawerFillet - 16))
        let reach = bodyHeight / 2 + drawerFillet
        let cy = clamp(centerY, visible.minY + reach, visible.maxY - reach)
        let width = drawerWidth + margin
        let height = bodyHeight + 2 * (drawerFillet + margin)
        let x = edge == .right ? visible.maxX - width : visible.minX
        let frame = CGRect(x: x, y: cy - height / 2, width: width, height: height)
        return DockGeometry(frame: frame, centerFromTop: height / 2, bodyWidth: drawerWidth,
                            bodyHeight: bodyHeight, corner: drawerCorner, fillet: drawerFillet)
    }

    /// The handle's shape, placed inside the drawer's (larger) window so it
    /// stays exactly where it was on screen — the first frame of opening and
    /// the last of closing.
    func handle(placedIn window: CGRect) -> DockGeometry {
        var out = self
        let screenCenter = frame.midY
        out.frame = window
        out.centerFromTop = window.maxY - screenCenter
        return out
    }

    /// Where the handle's centre sits on screen, for saving its position.
    var screenCenterY: CGFloat { frame.maxY - centerFromTop }

    /// The handle's position along the edge as 0 (bottom) … 1 (top).
    static func fraction(of centerY: CGFloat, in visible: CGRect) -> CGFloat {
        guard visible.height > 0 else { return 0.5 }
        return clamp((centerY - visible.minY) / visible.height, 0, 1)
    }

    static func centerY(fraction: CGFloat, in visible: CGRect) -> CGFloat {
        visible.minY + clamp(fraction, 0, 1) * visible.height
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo > hi ? (lo + hi) / 2 : min(hi, max(lo, v))
    }
}
