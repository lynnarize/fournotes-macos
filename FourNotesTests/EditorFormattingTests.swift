import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// The toolbar's paragraph tools with only a caret — which is how they are
// mostly used. With nothing selected the editor changed the text but not what
// would be typed next, and the toolbar reads the latter: a second click on
// Bulleted list put the list on again rather than taking it off. An empty line
// could not take a list at all. These drive the editor's own text view.

@MainActor
@Suite("Editor formatting", .serialized)
struct EditorFormattingTests {

    @MainActor
    private final class Editor {
        let controller = RichTextController()
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let window: NSWindow

        /// The editor holding `text`, with the caret at `caret` (the end by default).
        init(_ text: String, caret: Int? = nil) {
            let start = NoteDocument.attributed(fromPlainText: text)
            var bound = start
            let editor = RichTextEditor(
                attributed: Binding(get: { bound }, set: { bound = $0 }),
                controller: controller, onTextChange: { _ in }, header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator,
                                                              text: start)
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = textView
            window.makeFirstResponder(textView)
            select(caret ?? start.length)
        }

        func select(_ location: Int, _ length: Int = 0) {
            textView.setSelectedRange(NSRange(location: location, length: length))
            controller.refreshState()
        }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: textView.selectedRange())
        }

        var state: RichTextState { controller.state }
        var plain: String { NoteDocument.plainText(from: textView.textStorage!) }

        /// Whether a list marker is drawn at the start of line `line` — the
        /// strip left of where list text begins.
        func markerDrawn(onLine line: Int) throws -> Bool {
            textView.layOutEverything()
            let bitmap = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
            textView.cacheDisplay(in: textView.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / textView.bounds.width
            let lineHeight = NoteDocument.bodyFont.boundingRectForFont.height
            let top = textView.textContainerOrigin.y + lineHeight * CGFloat(line)
            for y in Int(top * scale)..<Int((top + lineHeight) * scale) {
                for x in 0..<Int((NoteDocument.indentStep - 4) * scale) {
                    if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.3 { return true }
                }
            }
            return false
        }
    }

    // MARK: - Lists

    @Test("the list buttons take a list off again with only a caret",
          arguments: [true, false])
    func listTogglesOff(_ bulleted: Bool) {
        let e = Editor("Milk")
        let toggle = bulleted ? e.controller.toggleBulletList : e.controller.toggleNumberedList
        toggle()
        #expect(e.plain == (bulleted ? "• Milk" : "1. Milk"))
        #expect(bulleted ? e.state.isBulletList : e.state.isNumberedList, "the button should light up")
        toggle()
        #expect(e.plain == "Milk")
        #expect(!e.state.inList)
    }

    @Test("an empty note takes a bullet, drawn before anything is typed")
    func emptyNoteTakesAList() throws {
        let e = Editor("")
        e.controller.toggleBulletList()
        #expect(e.state.isBulletList)
        #expect(try e.markerDrawn(onLine: 0), "the bullet should show straight away")
        e.type("Milk")
        #expect(e.plain == "• Milk")

        e.controller.toggleBulletList()
        #expect(!e.state.inList)
        #expect(e.plain == "Milk")
    }

    @Test("an empty line between paragraphs takes a list")
    func emptyLineTakesAList() {
        let e = Editor("Above\n\nBelow", caret: 6)
        e.controller.toggleNumberedList()
        #expect(e.state.isNumberedList)
        e.type("Middle")
        #expect(e.plain == "Above\n1. Middle\nBelow")
    }

    @Test("the empty item Return makes can be taken out of the list")
    func emptyItemLeavesList() {
        let e = Editor("• Milk")
        e.textView.insertNewline(nil)
        #expect(e.state.isBulletList)
        e.controller.toggleBulletList()
        #expect(!e.state.inList)
        e.type("Eggs")
        #expect(e.plain == "• Milk\nEggs")
    }

    @Test("Return on an empty item ends the list, and the toolbar says so")
    func returnEndsList() {
        let e = Editor("• Milk")
        e.textView.insertNewline(nil)
        e.textView.insertNewline(nil)
        #expect(!e.state.inList)
    }

    @Test("a bulleted item turns numbered, and back")
    func listChangesKind() {
        let e = Editor("• Milk\n• Eggs")
        e.select(0, e.textView.textStorage!.length)
        e.controller.toggleNumberedList()
        #expect(e.plain == "1. Milk\n2. Eggs")
        e.controller.toggleBulletList()
        #expect(e.plain == "• Milk\n• Eggs")
    }

    @Test("a nested item changes kind at its own level")
    func nestedItemChangesKind() {
        let e = Editor("• Trip\n  • Bandung")
        #expect(e.state.isBulletList)
        e.controller.toggleNumberedList()
        #expect(e.plain == "• Trip\n  1. Bandung")
        #expect(e.state.isNumberedList, "the item's own list is numbered")
        #expect(!e.state.isBulletList)
    }

    @Test("a new numbered item joins the list above it")
    func joinsListAbove() {
        let e = Editor("1. One\n2. Two\nThree")
        e.controller.toggleNumberedList()
        #expect(e.plain == "1. One\n2. Two\n3. Three")
    }

    @Test("a bullet on an empty note undoes in one step")
    func emptyListUndoes() {
        let e = Editor("")
        let undo = e.textView.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        e.controller.toggleBulletList()
        undo.endUndoGrouping()
        e.controller.undo()
        #expect(e.textView.string.isEmpty)
    }

    // MARK: - Backspace

    @Test("Backspace at the start of a list item takes its bullet off")
    func backspaceTakesBulletOff() {
        let e = Editor("• Milk\n• Eggs", caret: 5)
        e.textView.deleteBackward(nil)
        #expect(e.plain == "• Milk\nEggs")
        #expect(!e.state.inList)
        // Again, and it joins the line above as usual.
        e.textView.deleteBackward(nil)
        #expect(e.plain == "• MilkEggs")
    }

    @Test("Backspace at the start of a nested item brings it out a level")
    func backspaceOutdents() {
        let e = Editor("• Trip\n  • Bandung", caret: 5)
        e.textView.deleteBackward(nil)
        #expect(e.plain == "• Trip\n• Bandung")
    }

    @Test("Backspace after a checklist box takes the box off")
    func backspaceTakesBoxOff() {
        let e = Editor("☐ Milk", caret: 2)
        e.textView.deleteBackward(nil)
        #expect(e.plain == "Milk")
        #expect(!e.state.isChecklist)
    }

    @Test("Backspace inside text is an ordinary backspace")
    func backspaceInText() {
        let e = Editor("• Milk")
        e.textView.deleteBackward(nil)
        #expect(e.plain == "• Mil")
    }

    // MARK: - Checklists

    @Test("Return in a checklist item starts the next one")
    func returnContinuesChecklist() {
        let e = Editor("☐ Milk")
        e.textView.insertNewline(nil)
        #expect(e.state.isChecklist)
        e.type("Eggs")
        #expect(e.plain == "☐ Milk\n☐ Eggs")
    }

    @Test("Return in the middle of an item moves the rest into the next")
    func returnSplitsChecklistItem() {
        let e = Editor("☐ Milk Eggs", caret: 6)
        e.textView.insertNewline(nil)
        #expect(e.plain == "☐ Milk\n☐ Eggs")
    }

    @Test("Return on an empty checklist item ends the checklist")
    func returnEndsChecklist() {
        let e = Editor("☐ Milk")
        e.textView.insertNewline(nil)
        e.textView.insertNewline(nil)
        #expect(!e.state.isChecklist)
        e.type("Done")
        #expect(e.plain == "☐ Milk\nDone")
    }

    @Test("a new checklist item undoes in one step")
    func checklistReturnUndoes() {
        let e = Editor("☐ Milk")
        let undo = e.textView.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        e.textView.insertNewline(nil)
        undo.endUndoGrouping()
        e.controller.undo()
        #expect(e.plain == "☐ Milk")
    }

    // MARK: - Other paragraph styles

    @Test("a quote comes off again with only a caret")
    func quoteTogglesOff() {
        let e = Editor("Remember this")
        e.controller.toggleQuote()
        #expect(e.state.isQuote)
        #expect(e.plain == "> Remember this")
        e.controller.toggleQuote()
        #expect(!e.state.isQuote)
        #expect(e.plain == "Remember this")
    }

    @Test("a code block comes off again with only a caret")
    func codeTogglesOff() {
        let e = Editor("let x = 1")
        e.controller.toggleCode()
        #expect(e.state.isCode)
        e.controller.toggleCode()
        #expect(!e.state.isCode)
    }

    @Test("a heading shows in the toolbar, and carries on as it is typed")
    func headingWithCaret() {
        let e = Editor("Trip")
        e.controller.setHeading(1)
        #expect(e.state.headingLevel == 1)
        e.type(" plan")
        #expect(e.plain == "# Trip plan")
        e.controller.setHeading(nil)
        #expect(e.state.headingLevel == nil)
        #expect(e.plain == "Trip plan")
    }

    @Test("Return after a heading is back to body text", arguments: [1, 2, 3])
    func returnAfterHeading(_ level: Int) {
        let e = Editor("Trip\nBody", caret: 4)
        e.controller.setHeading(level)
        e.textView.insertNewline(nil)
        #expect(e.state.headingLevel == nil)
        e.type("x")
        #expect(e.plain == "\(String(repeating: "#", count: level)) Trip\nx\nBody")
    }

    @Test("Return inside a heading splits it into two headings")
    func returnInsideHeading() {
        let e = Editor("# Trip plan", caret: 5)
        e.textView.insertNewline(nil)
        #expect(e.plain == "# Trip \n# plan")
    }

    @Test("Normal text takes a paragraph out of a quote")
    func normalTextLeavesQuote() {
        let e = Editor("> Remember")
        e.controller.setHeading(nil)
        #expect(!e.state.isQuote)
        #expect(e.plain == "Remember")
    }

    @Test("alignment lights up with only a caret")
    func alignmentWithCaret() {
        let e = Editor("Centre me")
        e.controller.setAlignment(.center)
        #expect(e.state.alignment == .center)
    }

    // MARK: - Inline tools

    @Test("⌘B, ⌘I and ⌘U format the text")
    func keyboardShortcuts() throws {
        let e = Editor("Hello")
        e.select(0, 5)
        for (key, code) in [("b", 11), ("i", 34), ("u", 32)] as [(String, UInt16)] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: e.window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(e.textView.performKeyEquivalent(with: event), "⌘\(key.uppercased()) went unhandled")
        }
        #expect(e.state.bold)
        #expect(e.state.italic)
        #expect(e.state.underline)
    }

    @Test("Rounded is the system's rounded face")
    func roundedFont() throws {
        let e = Editor("Hello")
        e.select(0, 5)
        e.controller.setFontFamily(RichTextController.roundedFamily)
        let font = try #require(e.textView.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName != NSFont.systemFont(ofSize: font.pointSize).familyName, "the font did not change")
        #expect(e.state.fontFamily == RichTextController.roundedFamily)
        e.controller.setFontFamily("")
        #expect(e.state.fontFamily == "")
    }

    @Test("the Default colour is the theme's text colour, not none")
    func defaultColour() {
        let e = Editor("Hello")
        e.select(0, 5)
        e.controller.setColor("#d4351c")
        e.controller.setColor("")
        let color = e.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.labelColor)
    }

    @Test("Clear formatting keeps checklist boxes and list markers")
    func clearKeepsStructure() {
        let e = Editor("☐ Buy milk\n• Bandung")
        e.select(0, e.textView.textStorage!.length)
        e.controller.toggleBold()
        e.controller.clearFormatting()
        #expect(e.plain == "☐ Buy milk\n• Bandung")
        #expect(!NoteDocument.hasInlineFormatting(e.textView.textStorage!))
    }

    @Test("Clear formatting with only a caret stops bold typing")
    func clearTypingAttributes() {
        let e = Editor("Hello")
        e.controller.toggleBold()
        #expect(e.state.bold)
        e.controller.clearFormatting()
        #expect(!e.state.bold)
    }

    @Test("what the link field says becomes a link", arguments: [
        ("example.com", "https://example.com"),
        ("https://example.com/a", "https://example.com/a"),
        ("mailto:a@b.co", "mailto:a@b.co"),
        ("a@b.co", "mailto:a@b.co"),
    ])
    func linkAddresses(_ typed: String, _ expected: String) {
        #expect(RichTextController.linkURL(typed)?.absoluteString == expected)
    }

    @Test("an empty link field makes no link")
    func emptyLink() {
        #expect(RichTextController.linkURL("  ") == nil)
    }

    @Test("linking selected text keeps it and its formatting")
    func linkSelection() throws {
        let e = Editor("Read this")
        e.select(5, 4)
        e.controller.toggleBold()
        e.controller.insertLink("example.com", title: "example.com")
        let storage = e.textView.textStorage!
        #expect(storage.string == "Read this")
        #expect((storage.attribute(.link, at: 5, effectiveRange: nil) as? URL)?.absoluteString == "https://example.com")
        #expect(e.state.bold)
    }

    @Test("typing after an inserted link is not more of the link")
    func typingAfterLink() {
        let e = Editor("See ")
        e.controller.insertLink("example.com", title: "site")
        e.type("!")
        let storage = e.textView.textStorage!
        #expect(storage.attribute(.link, at: storage.length - 1, effectiveRange: nil) == nil)
    }

    @Test("an inserted date takes the style being typed")
    func insertedTextStyle() throws {
        let e = Editor("Trip")
        e.controller.setHeading(1)
        e.controller.insertText(" today")
        let font = try #require(e.textView.textStorage!.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        #expect(NoteDocument.headingLevel(of: font) == 1)
    }
}

// MARK: - The toolbar's one line

@Suite("Formatting toolbar layout")
struct ToolbarLayoutTests {
    /// Five 100-wide groups and a 30-wide button, 10 apart.
    private let sizes = Array(repeating: CGSize(width: 100, height: 30), count: 5) + [CGSize(width: 30, height: 30)]

    private func arrange(width: CGFloat, expanded: Bool) -> ToolbarLayout.Arrangement {
        ToolbarLayout.arrange(sizes, width: width, expanded: expanded, spacing: 10, lineSpacing: 6)
    }

    @Test("everything on one line when it fits, with no button")
    func allFit() {
        let a = arrange(width: 600, expanded: false)
        #expect(a.shown == Set(0..<5))
        #expect(a.size.height == 30)
        #expect(a.frames[5].minX >= 600, "the button should be out of sight")
    }

    @Test("collapsed is one line: what fits, and the button at its end")
    func collapsed() {
        let a = arrange(width: 400, expanded: false)
        // 400 less the button and its gap leaves room for three.
        #expect(a.shown == [0, 1, 2, 5])
        #expect(a.size.height == 30)
        #expect(a.frames[5].maxX == 400)
        for hidden in [3, 4] { #expect(a.frames[hidden].minX >= 400) }
    }

    @Test("expanded shows everything, the first line as it was")
    func expanded() {
        let collapsed = arrange(width: 400, expanded: false)
        let a = arrange(width: 400, expanded: true)
        #expect(a.shown == Set(0..<6))
        #expect(a.size.height == 66)
        for index in [0, 1, 2, 5] { #expect(a.frames[index] == collapsed.frames[index]) }
        #expect(a.frames[3].minY == 36)
        #expect(a.frames[3].maxX <= 400)
    }

    @Test("expanded or not makes no difference when everything fits")
    func expandedButFits() {
        #expect(arrange(width: 600, expanded: true) == arrange(width: 600, expanded: false))
    }
}
