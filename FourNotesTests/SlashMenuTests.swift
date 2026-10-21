import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// The "/" menu: it opens at the start of a line or after a space, narrows as you
// type, moves with the arrows, picks with Return, closes with Escape, and the
// "/word" is gone from the note once a command runs.

@MainActor
@Suite("The / menu", .serialized)
struct SlashMenuTests {

    @MainActor
    private final class Harness {
        let controller = RichTextController()
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let window: NSWindow
        var picked: [SlashCommand] = []

        init(_ text: String) {
            let start = NoteDocument.attributed(fromPlainText: text)
            var bound = start
            let editor = RichTextEditor(
                attributed: Binding(get: { bound }, set: { bound = $0 }),
                controller: controller, onTextChange: { _ in }, header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator, text: start)
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = textView
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            controller.onSlash = { [unowned self] in picked.append($0) }
        }

        func type(_ text: String) {
            for character in text { textView.insertText(String(character), replacementRange: textView.selectedRange()) }
        }

        func key(_ selector: Selector) { textView.doCommand(by: selector) }
    }

    @Test("Opens at the start of a line and after a space, not inside a word")
    func opens() {
        let h = Harness("")
        h.type("/")
        #expect(h.controller.slash != nil)
        #expect(h.controller.slash?.commands.count == SlashCommand.allCases.count)

        let mid = Harness("and/or")
        mid.type("/")
        #expect(mid.controller.slash == nil)

        let spaced = Harness("Lunch 45k ")
        spaced.type("/exp")
        #expect(spaced.controller.slash?.commands == [.expense])
    }

    @Test("Return runs the highlighted command and removes what was typed")
    func runs() {
        let h = Harness("Call Budi ")
        h.type("/to")
        #expect(h.controller.slash?.commands.first == .todo)
        h.key(#selector(NSResponder.insertNewline(_:)))
        #expect(h.picked == [.todo])
        #expect(h.controller.slash == nil)
        #expect(h.textView.string == "Call Budi ")
        #expect(h.controller.currentLineText == "Call Budi")
    }

    @Test("Arrows move, Escape closes and keeps the slash")
    func moves() {
        let h = Harness("")
        h.type("/")
        h.key(#selector(NSResponder.moveDown(_:)))
        h.key(#selector(NSResponder.moveDown(_:)))
        #expect(h.controller.slash?.active == 2)
        h.key(#selector(NSResponder.moveUp(_:)))
        #expect(h.controller.slash?.active == 1)
        h.key(#selector(NSResponder.cancelOperation(_:)))
        #expect(h.controller.slash == nil)
        #expect(h.textView.string == "/")
        #expect(h.picked.isEmpty)
        // Typing on doesn't bring it back for the same slash.
        h.type("x")
        #expect(h.controller.slash == nil)
    }

    @Test("Nothing matching closes it, and Return then makes a new line")
    func noMatch() {
        let h = Harness("")
        h.type("/zzz")
        #expect(h.controller.slash == nil)
        h.key(#selector(NSResponder.insertNewline(_:)))
        #expect(h.picked.isEmpty)
        #expect(h.textView.string.hasSuffix("\n"))
    }
}
