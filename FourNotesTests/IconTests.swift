import SwiftUI
import Testing
@testable import FourNotes

// The icons are hand-written SVG path data. The parser used to read ".8.8" as
// one number and stop there, so "more" — the button behind every "…" menu —
// drew nothing, and nobody could see it to report it.

@Suite("Icons")
struct IconTests {
    @Test("every icon's path parses to the end", arguments: Icon.paths.keys.sorted())
    func parses(_ name: String) throws {
        let d = try #require(Icon.paths[name])
        #expect(SVGPath.isComplete(d), "\(name) stops part-way through its path")
    }

    @Test("compact numbers split where a second point starts one")
    func compactNumbers() {
        let dots = SVGPath.path(from: "M5 11.2a.8.8 0 110 1.6.8.8 0 010-1.6z",
                                in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(dots.boundingRect.height > 1.4, "the dot should be drawn, not collapse to a point")
    }

    @Test("the mark's stroke and spark parse to the end, where the artwork has them")
    func mark() {
        #expect(SVGPath.isComplete(Logo.strokePath), "the pen stroke stops part-way through its path")
        #expect(SVGPath.isComplete(Logo.sparkPath), "the spark stops part-way through its path")
        let box = CGRect(x: 0, y: 0, width: Logo.viewBox, height: Logo.viewBox)
        let stroke = SVGPath.path(from: Logo.strokePath, in: box, viewBox: box.size).boundingRect
        let spark = SVGPath.path(from: Logo.sparkPath, in: box, viewBox: box.size).boundingRect
        // The traced mark spans x 23…776, y 217…583 of its 800 box.
        let mark = stroke.union(spark)
        #expect(abs(mark.minX - 23) <= 2 && abs(mark.maxX - 776) <= 2)
        #expect(abs(mark.minY - 217) <= 2 && abs(mark.maxY - 583) <= 2)
        // The spark is up at the stroke's right end, clear of it.
        #expect(spark.minX > stroke.midX && spark.maxY < stroke.midY + 20)
    }
}
