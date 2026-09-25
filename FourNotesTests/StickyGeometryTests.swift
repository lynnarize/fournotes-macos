import CoreGraphics
import Foundation
import Testing
@testable import FourNotes

@Suite("Sticky notes' bubbles on the dock's handle")
struct StickyGeometryTests {
    let screen = CGRect(x: 0, y: 70, width: 1470, height: 855)
    let handleY: CGFloat = 500

    @Test("the first bubble goes above the handle, the next below, then outwards")
    func order() {
        let ys = StickyGeometry.bubbleSlots(count: 4, handleY: handleY, in: screen)
        #expect(ys.count == 4)
        #expect(ys[0] > handleY && ys[1] < handleY)
        #expect(ys[2] > ys[0] && ys[3] < ys[1])
    }

    @Test("bubbles stand apart: clear of the handle and of each other")
    func apart() {
        let ys = StickyGeometry.bubbleSlots(count: 6, handleY: handleY, in: screen)
        for y in ys {
            #expect(abs(y - handleY) - StickyGeometry.bubble / 2 - DockGeometry.handleHeight / 2 >= StickyGeometry.bubbleGap)
        }
        let sorted = ys.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            #expect(b - a - StickyGeometry.bubble >= StickyGeometry.bubbleGap)
        }
    }

    @Test("with the handle near the top, they all go below it, on screen")
    func nearTop() {
        let top = screen.maxY - 50
        let ys = StickyGeometry.bubbleSlots(count: 3, handleY: top, in: screen)
        #expect(ys.allSatisfy { $0 < top })
        #expect(ys.allSatisfy { $0 - StickyGeometry.bubble / 2 >= screen.minY })
        #expect(Set(ys).count == 3)
    }

    @Test("the window holds the handle, every bubble, and one stretched into a pill, on either edge")
    func window() {
        for edge in DockEdge.allCases {
            let handle = DockGeometry.handle(in: screen, edge: edge, centerY: handleY).frame
            let slots = StickyGeometry.bubbleSlots(count: 5, handleY: handleY, in: screen)
            let window = StickyGeometry.islandWindow(handle: handle, edge: edge, slots: slots)
            #expect(window.contains(handle))
            let bounds = CGRect(origin: .zero, size: window.size)
            for y in slots {
                let local = window.maxY - y
                let bubble = StickyGeometry.bubbleRect(width: window.width, edge: edge, centerY: local)
                let pill = StickyGeometry.pillRect(width: window.width, edge: edge, centerY: local)
                #expect(bounds.contains(bubble) && bounds.contains(pill))
                // The pill grows into the screen from where the bubble sits.
                #expect(edge == .right ? pill.maxX == bubble.maxX : pill.minX == bubble.minX)
                #expect(pill.midY == bubble.midY)
            }
        }
    }

    @Test("resting beside an open note, the island is only as wide as its bubbles, clear of the note")
    func restingIsland() {
        let handle = DockGeometry.handle(in: screen, edge: .right, centerY: screen.midY)
        let slots = StickyGeometry.bubbleSlots(count: 3, handleY: handle.screenCenterY, in: screen)
        let wide = StickyGeometry.islandWindow(handle: handle.frame, edge: .right, slots: slots)
        let narrow = StickyGeometry.islandWindow(handle: handle.frame, edge: .right, slots: slots, wide: false)
        #expect(narrow.maxX == wide.maxX && narrow.height == wide.height && narrow.width < wide.width)
        #expect(narrow.minX >= screen.maxX - StickyGeometry.edgeGap)
        for y in slots {
            let bubble = StickyGeometry.bubbleRect(width: narrow.width, edge: .right, centerY: narrow.maxY - y)
            #expect(CGRect(origin: .zero, size: narrow.size).contains(bubble))
        }
    }

    @Test("an open note sits beside the edge, on screen, clear of one already there")
    func openWindow() {
        let anchor = CGPoint(x: screen.maxX - 20, y: screen.maxY - 10)
        let w = StickyGeometry.window(anchor: anchor, edge: .right, in: screen)
        let paper = w.insetBy(dx: StickyGeometry.windowMargin, dy: StickyGeometry.windowMargin)
        #expect(paper.maxX == screen.maxX - StickyGeometry.edgeGap)
        #expect(paper.maxY <= screen.maxY && paper.minY >= screen.minY)
        let next = StickyGeometry.window(anchor: anchor, edge: .right, in: screen, avoiding: [w])
        #expect(next.origin != w.origin)
        let left = StickyGeometry.window(anchor: anchor, edge: .left, in: screen)
            .insetBy(dx: StickyGeometry.windowMargin, dy: StickyGeometry.windowMargin)
        #expect(left.minX == screen.minX + StickyGeometry.edgeGap)
    }

    @Test("a note let go off screen comes back just far enough to take hold of again")
    func grabbable() {
        let paper = CGRect(x: 400, y: 300, width: StickyGeometry.paperWidth, height: StickyGeometry.paperHeight)
        #expect(StickyGeometry.keepGrabbable(paper, in: screen) == .zero)
        // Its top under the menu bar: down until the strip is on screen.
        let high = paper.offsetBy(dx: 0, dy: screen.maxY - paper.maxY + 50)
        #expect(StickyGeometry.keepGrabbable(high, in: screen).dy == -50)
        // Nearly all of it past the right edge: back until some of it shows.
        let right = paper.offsetBy(dx: screen.maxX - paper.minX - 10, dy: 0)
        let shift = StickyGeometry.keepGrabbable(right, in: screen)
        #expect(right.offsetBy(dx: shift.dx, dy: 0).minX == screen.maxX - 80)
        // Below the bottom with only its strip left: stays.
        let low = paper.offsetBy(dx: 0, dy: screen.minY + 30 - paper.maxY)
        #expect(StickyGeometry.keepGrabbable(low, in: screen) == .zero)
    }

    @Test("placements decode from what was saved, older ones included")
    func codable() throws {
        let p = StickyPlacement(noteId: "n1", color: .blue)
        let data = try JSONEncoder().encode([p])
        #expect(try JSONDecoder().decode([StickyPlacement].self, from: data) == [p])
        let old = Data(#"[{"noteId":"n2","edge":"right","screen":1,"top":0.3,"tucked":true,"color":"pink"}]"#.utf8)
        #expect(try JSONDecoder().decode([StickyPlacement].self, from: old) == [StickyPlacement(noteId: "n2", color: .pink)])
    }
}
