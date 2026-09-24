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

    @Test("the open note grows from the edge and stays on screen")
    func note() {
        let n = StickyGeometry.note(in: screen, edge: .right, centerY: screen.maxY - 10)
        #expect(n.frame.maxX == screen.maxX)
        #expect(n.screenCenterY + StickyGeometry.noteHeight / 2 + StickyGeometry.noteFillet <= screen.maxY)
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
