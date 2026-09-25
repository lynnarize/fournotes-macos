import AppKit
import Foundation
import Testing
@testable import FourNotes

// Opening a note written in the web app. AppKit's HTML reader writes list
// markers into the text as well as marking the line as a list, so every item
// showed two bullets — and saving the note sent the extra "•" back to the web.

@Suite("Notes from the web app")
@MainActor
struct WebNoteImportTests {
    /// What the web editor (TipTap) writes, and the `content` it writes with it.
    private let html = """
    <h2>Tips</h2><ul><li><p><strong>Transport:</strong> Rent a scooter</p></li>\
    <li><p>Budget <em>matters</em></p><ul><li><p>nested</p></li></ul></li></ul>\
    <ol><li><p>one</p></li><li><p>two</p></li></ol>\
    <ul data-type="taskList"><li data-checked="true" data-type="taskItem"><label><input type="checkbox" checked="checked"><span></span></label><div><p>done task</p></div></li>\
    <li data-checked="false" data-type="taskItem"><label><input type="checkbox"><span></span></label><div><p>open task</p></div></li></ul>\
    <hr><blockquote><p>quote</p></blockquote>
    """
    private let plain = """
    ## Tips
    • Transport: Rent a scooter
    • Budget matters
      • nested
    1. one
    2. two
    ☑ done task
    ☐ open task
    ---
    > quote
    """

    @Test("each list item has one bullet, and the structure round-trips")
    func structure() {
        let document = NoteDocument.attributed(fromHTML: html, plain: plain)
        #expect(!document.string.contains("\t•\t"))
        #expect(!document.string.contains("\t1\t"))
        #expect(NoteDocument.plainText(from: document) == plain)
    }

    @Test("bold and italic come over from the HTML")
    func inlineStyles() throws {
        let document = NoteDocument.attributed(fromHTML: html, plain: plain)
        let text = document.string as NSString
        let bold = try #require(document.attribute(.font, at: text.range(of: "Transport:").location,
                                                   effectiveRange: nil) as? NSFont)
        let regular = try #require(document.attribute(.font, at: text.range(of: "Rent").location,
                                                      effectiveRange: nil) as? NSFont)
        let italic = try #require(document.attribute(.font, at: text.range(of: "matters").location,
                                                     effectiveRange: nil) as? NSFont)
        let manager = NSFontManager.shared
        #expect(manager.traits(of: bold).contains(.boldFontMask))
        #expect(!manager.traits(of: regular).contains(.boldFontMask))
        #expect(manager.traits(of: italic).contains(.italicFontMask))
        #expect(bold.pointSize == NoteDocument.bodySize)
    }

    @Test("a note saved with the doubled marker is repaired")
    func repair() {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let broken = NSMutableAttributedString(string: "\t•\tTransport\n", attributes: [
            .paragraphStyle: NoteDocument.listParagraphStyle(list), .font: NoteDocument.bodyFont,
        ])
        #expect(NoteDocument.plainText(from: broken) == "• Transport")
        let repaired = NoteDocument.removingLiteralListMarkers(broken)
        #expect(repaired.string == "Transport\n")
    }
}

// The editor reads like the web app's: Open Sans, lines 1.75× the text size,
// a gap between paragraphs and a smaller one between list items.
@Suite("Note typography")
@MainActor
struct NoteTypographyTests {
    @Test("notes use the bundled Open Sans, in every weight")
    func openSans() {
        let manager = NSFontManager.shared
        #expect(NoteDocument.bodyFont.familyName == "Open Sans")
        #expect(NoteDocument.headingFont(2).familyName == "Open Sans")
        #expect(manager.traits(of: NoteDocument.headingFont(2)).contains(.boldFontMask))
        let italic = manager.convert(NoteDocument.bodyFont, toHaveTrait: .italicFontMask)
        #expect(italic.familyName == "Open Sans")
        #expect(manager.traits(of: italic).contains(.italicFontMask))
    }

    @Test("a note saved in the system font opens in Open Sans, bold kept, and isn't counted as formatted")
    func olderNotes() {
        let manager = NSFontManager.shared
        let old = NSMutableAttributedString(string: "Plain ", attributes: [.font: NSFont.systemFont(ofSize: 16)])
        old.append(NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)]))
        let converted = NoteDocument.usingBodyFont(old)
        let plain = converted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bold = converted.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(plain?.familyName == "Open Sans")
        #expect(bold?.familyName == "Open Sans")
        #expect(bold.map { manager.traits(of: $0).contains(.boldFontMask) } == true)
        #expect(!NoteDocument.hasInlineFormatting(NoteDocument.attributed(fromPlainText: "Just text\n• item")))
    }

    @Test("paragraphs get the web's spacing; list items sit closer, except the last")
    func spacing() {
        let document = NoteDocument.spaced(NoteDocument.attributed(fromPlainText: "Intro\n• one\n• two\nAfter"))
        let text = document.string as NSString
        func style(_ word: String) -> NSParagraphStyle? {
            document.attribute(.paragraphStyle, at: text.range(of: word).location, effectiveRange: nil) as? NSParagraphStyle
        }
        #expect(style("Intro")?.paragraphSpacing == NoteDocument.paragraphGap)
        #expect(style("one")?.paragraphSpacing == NoteDocument.itemGap)
        #expect(style("two")?.paragraphSpacing == NoteDocument.paragraphGap)
        #expect(style("After")?.lineHeightMultiple == NoteDocument.lineHeightMultiple)
        #expect(NoteDocument.plainText(from: document) == "Intro\n• one\n• two\nAfter")
    }
}
