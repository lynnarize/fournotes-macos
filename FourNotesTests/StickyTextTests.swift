import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// The edge sticky shows a note's headings and quotes without their "# " and
// "> ", but edits the note's plain text: what it reads back must be exactly
// what it was given, except where it was typed in.

@Suite("Sticky text")
@MainActor
struct StickyTextTests {
    private let palette = StickyText.Palette(StickyPaper.of(.yellow, dark: false))

    private func shown(_ content: String) -> NSAttributedString {
        StickyText.attributed(content, palette: palette)
    }

    private func font(_ text: NSAttributedString, at index: Int) -> NSFont? {
        text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    @Test("headings and quotes show without their markers")
    func stripsMarkers() {
        let text = shown("# Goals\n• Ship the Mac beta\n\n## Open questions\n☐ Which features stay free?\n> Said once")
        #expect(text.string == "Goals\n• Ship the Mac beta\n\nOpen questions\n☐ Which features stay free?\nSaid once")
        #expect(font(text, at: 0)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font(text, at: 0)!.pointSize > StickyText.bodySize)
        // The bullet line stays ordinary text.
        #expect(font(text, at: 6)?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        let quote = (text.string as NSString).range(of: "Said once").location
        let style = text.attribute(.paragraphStyle, at: quote, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? 0) > 0)
    }

    @Test("reads back exactly what it was given", arguments: [
        "",
        "Hello",
        "# Goals\n• Ship the Mac beta…\n\n# Open questions\n☐ Which features stay free?",
        "## Two\n### Three\n#### Four is not a heading\n#NoSpace",
        "  # Indented heading\n>quote without a space\n>  two spaces\n> ",
        "# \n>\n#   \n---\n1. First\n☑ Done",
        "# Trailing space   \nwindows\r\nline\n",
        "# 🎉 Party\n> 👋 hi",
        "\n\n# After blank lines\n\n",
    ])
    func roundTrip(_ content: String) {
        #expect(StickyText.plainText(from: shown(content)) == content)
    }

    @Test("the editor and the sticky agree on what a heading is")
    func sameRules() {
        for line in ["# One", "## Two", "### Three", "#### Four", "#x", "> q", ">q", "  # in", "-- x"] {
            let editor = NoteDocument.attributed(fromPlainText: line)
            let editorHeading = (editor.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                .flatMap(NoteDocument.headingLevel(of:)) != nil
            let editorQuote = ((editor.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
                .headIndent ?? 0) > 0
            let sticky = shown(line)
            #expect(editor.string == sticky.string, "\(line)")
            let prefix = sticky.attribute(StickyText.marker, at: 0, effectiveRange: nil) as? String
            #expect((prefix?.contains("#") == true) == editorHeading, "\(line)")
            #expect((prefix?.contains(">") == true) == editorQuote, "\(line)")
        }
    }

    // MARK: - Typing

    /// Where the binding writes: the page's `text`, in the app.
    private final class Content: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private final class Harness {
        private let content: Content
        let coordinator: StickyTextView.Coordinator
        let textView: StickyNSTextView

        var text: String { content.value }

        @MainActor init(_ text: String, palette: StickyText.Palette) {
            let content = Content(text)
            self.content = content
            let view = StickyTextView(text: Binding(get: { content.value }, set: { content.value = $0 }),
                                      editing: .constant(false), editable: true, palette: palette)
            coordinator = view.makeCoordinator()
            textView = StickyTextView.makeTextView(coordinator)
        }

        @MainActor func caret(_ location: Int) { textView.setSelectedRange(NSRange(location: location, length: 0)) }
        @MainActor func type(_ string: String) { textView.insertText(string, replacementRange: textView.selectedRange()) }
        @MainActor var shown: String { textView.string }
    }

    @Test("typing in a heading keeps its marker and changes only that line")
    func typingInHeading() {
        let h = Harness("# Goals\n• Ship it", palette: palette)
        h.caret(5)
        h.type("!")
        #expect(h.shown == "Goals!\n• Ship it")
        #expect(h.text == "# Goals!\n• Ship it")
        // At the very start of the heading, too.
        h.caret(0)
        h.type("My ")
        #expect(h.text == "# My Goals!\n• Ship it")
    }

    @Test("a new line after a heading is ordinary text")
    func newLineAfterHeading() {
        let h = Harness("# Goals", palette: palette)
        h.caret(5)
        h.textView.insertNewline(nil)
        h.type("Plain")
        #expect(h.text == "# Goals\nPlain")
    }

    @Test("typing a marker makes a heading or a quote")
    func typedMarker() {
        let h = Harness("", palette: palette)
        h.type("# ")
        #expect(h.shown == "# ")
        h.type("T")
        #expect(h.shown == "T")
        #expect(h.text == "# T")
        h.type("itle")
        h.textView.insertNewline(nil)
        h.type("> q")
        #expect(h.shown == "Title\nq")
        #expect(h.text == "# Title\n> q")
    }

    @Test("backspace at the start of a heading makes it ordinary text")
    func backspaceUnmarks() {
        let h = Harness("Intro\n## Goals", palette: palette)
        h.caret(6)
        h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(h.shown == "Intro\nGoals")
        #expect(h.text == "Intro\nGoals")
        // Once it's ordinary, backspace joins it to the line above as usual.
        h.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(h.text == "IntroGoals")
    }

    @Test("undo and redo are saved too, and undo a typed marker cleanly")
    func undoIsSaved() throws {
        let h = Harness("", palette: palette)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = h.textView
        window.makeFirstResponder(h.textView)
        let undo = try #require(h.textView.undoManager)
        undo.groupsByEvent = false
        // One keystroke per undo step, as when typed.
        for key in ["#", " ", "T", "o"] {
            undo.beginUndoGrouping()
            h.type(key)
            undo.endUndoGrouping()
        }
        #expect(h.text == "# To")
        undo.undo()
        #expect(h.text == "# T")
        // The keystroke that made the heading, and the heading, go together.
        undo.undo()
        #expect(h.shown == "# ")
        #expect(h.text == "# ")
        undo.redo()
        undo.redo()
        #expect(h.shown == "To")
        #expect(h.text == "# To")
    }

    @Test("text changed elsewhere is shown, with its structure")
    func externalChange() {
        let h = Harness("Old", palette: palette)
        h.coordinator.load("# New\n> quoted", into: h.textView)
        #expect(h.shown == "New\nquoted")
        #expect(StickyText.plainText(from: h.textView.textStorage!) == "# New\n> quoted")
    }

    @Test("the same paper compares equal, so updates don't restyle")
    func paletteEquality() {
        #expect(StickyText.Palette(StickyPaper.of(.blue, dark: true)) == StickyText.Palette(StickyPaper.of(.blue, dark: true)))
        #expect(StickyText.Palette(StickyPaper.of(.blue, dark: true)) != StickyText.Palette(StickyPaper.of(.blue, dark: false)))
    }
}
