import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// Under TextKit 2 an undo changes the text without posting didChange, so the
// editor never heard of it: the undone text showed, and the typed one was
// what got saved. These drive the editor's own text view and check what
// reaches the save.

@MainActor
@Suite("Editor undo is saved", .serialized)
struct EditorUndoTests {

    /// What the binding and the save see, in the app the note's text.
    private final class Saved {
        var bound: NSAttributedString
        var saves: [String] = []
        init(_ text: NSAttributedString) { bound = text }
        var last: String? { saves.last }
    }

    @MainActor
    private final class Harness {
        let saved: Saved
        let controller: RichTextController
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let window: NSWindow
        let undo: UndoManager

        init(_ text: String) throws {
            let controller = RichTextController()
            self.controller = controller
            let start = NoteDocument.attributed(fromPlainText: text)
            let saved = Saved(start)
            self.saved = saved
            let editor = RichTextEditor(
                attributed: Binding(get: { saved.bound }, set: { saved.bound = $0 }),
                controller: controller,
                onTextChange: { saved.saves.append(NoteDocument.plainText(from: $0)) },
                header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator,
                                                              text: start)
            textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = textView
            window.makeFirstResponder(textView)
            undo = try #require(textView.undoManager)
            // One keystroke per undo step, as when typed.
            undo.groupsByEvent = false
        }

        func type(_ keys: [String]) {
            for key in keys {
                undo.beginUndoGrouping()
                textView.insertText(key, replacementRange: textView.selectedRange())
                undo.endUndoGrouping()
            }
        }

        /// What Cmd-Z and the Edit menu send: `undo:` up the responder chain.
        func menu(_ action: String) {
            #expect(textView.tryToPerform(Selector((action)), with: nil), "\(action) found no responder")
        }

        var shown: String { NoteDocument.plainText(from: textView.textStorage!) }
        var bound: String { NoteDocument.plainText(from: saved.bound) }

        /// The next SwiftUI update must take the editor's own text as current,
        /// not push the binding back in over it.
        var inStep: Bool { coordinator.appliedRevision == controller.revision }
    }

    @Test("typing is saved")
    func typingSaved() throws {
        let h = try Harness("")
        h.type(["a", "b"])
        #expect(h.saved.last == "ab")
        #expect(h.bound == "ab")
        #expect(h.inStep)
    }

    @Test("Cmd-Z and Cmd-Shift-Z are saved")
    func menuUndoSaved() throws {
        let h = try Harness("Hi")
        h.textView.setSelectedRange(NSRange(location: 2, length: 0))
        h.type(["!", "?"])
        #expect(h.saved.last == "Hi!?")

        let before = h.controller.revision
        h.menu("undo:")
        #expect(h.shown == "Hi!")
        #expect(h.saved.last == "Hi!")
        #expect(h.bound == "Hi!")
        #expect(h.controller.revision > before)
        #expect(h.inStep)

        h.menu("undo:")
        #expect(h.saved.last == "Hi")
        h.menu("redo:")
        #expect(h.shown == "Hi!")
        #expect(h.saved.last == "Hi!")
        #expect(h.bound == "Hi!")
        #expect(h.inStep)
    }

    @Test("the toolbar's undo and redo are saved")
    func toolbarUndoSaved() throws {
        let h = try Harness("")
        h.type(["x", "y"])
        h.controller.undo()
        #expect(h.shown == "x")
        #expect(h.saved.last == "x")
        #expect(h.bound == "x")
        #expect(h.inStep)
        #expect(h.controller.state.canRedo)

        h.controller.redo()
        #expect(h.saved.last == "xy")
        #expect(h.bound == "xy")
        #expect(h.inStep)
    }

    @Test("making and unmaking a checklist undoes cleanly, and is saved")
    func checklistUndo() throws {
        let h = try Harness("Milk\nEggs")
        // The caret in "Milk", after the "M"; the selection runs into "Eggs".
        h.textView.setSelectedRange(NSRange(location: 1, length: 6))
        h.undo.beginUndoGrouping()
        h.controller.toggleChecklist()
        h.undo.endUndoGrouping()
        #expect(h.saved.last == "☐ Milk\n☐ Eggs")
        // Still on the same letters, now each two further along per box.
        #expect(h.textView.selectedRange() == NSRange(location: 3, length: 8))

        h.controller.undo()
        #expect(h.shown == "Milk\nEggs", "\(h.shown.debugDescription)")
        #expect(h.saved.last == "Milk\nEggs")
        #expect(h.inStep)
        h.controller.redo()
        #expect(h.shown == "☐ Milk\n☐ Eggs")
        #expect(h.saved.last == "☐ Milk\n☐ Eggs")

        h.textView.setSelectedRange(NSRange(location: 0, length: h.textView.textStorage!.length))
        h.controller.refreshState()
        h.undo.beginUndoGrouping()
        h.controller.toggleChecklist()
        h.undo.endUndoGrouping()
        #expect(h.saved.last == "Milk\nEggs")
        h.menu("undo:")
        #expect(h.shown == "☐ Milk\n☐ Eggs")
        #expect(h.saved.last == "☐ Milk\n☐ Eggs")
        #expect(h.inStep)
    }

    @Test("each undo saves once")
    func savesOnce() throws {
        let h = try Harness("")
        h.type(["a", "b"])
        let count = h.saved.saves.count
        h.controller.undo()
        // A late didChange, if AppKit ever sends one, would land here.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(h.saved.saves.count == count + 1)
    }
}
