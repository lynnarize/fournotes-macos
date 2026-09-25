import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// Text still being composed — an inline prediction, characters half-typed
// with an input method — is in the text view as marked text, and AppKit does
// not report it as a change. The editor used to push its binding back over the
// text view whenever the two differed, so the next SwiftUI update replaced the
// prediction; AppKit then cleared it at a range that no longer existed and
// threw an NSRangeException up through SwiftUI, freezing the window. Marked
// text is set here as an input method sets it. With the old behaviour these
// tests do not fail: the exception takes the test process down.

@MainActor
@Suite("Editor with text being composed", .serialized)
struct EditorMarkedTextTests {

    @MainActor
    private final class Editor {
        final class Bound { var value: NSAttributedString; init(_ value: NSAttributedString) { self.value = value } }

        let bound: Bound
        let controller = RichTextController()
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let window: NSWindow

        init(_ text: String) {
            let start = NoteDocument.attributed(fromPlainText: text)
            let bound = Bound(start)
            self.bound = bound
            let editor = RichTextEditor(
                attributed: Binding(get: { bound.value }, set: { bound.value = $0 }),
                controller: controller, onTextChange: { _ in }, header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator,
                                                              text: start)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = textView
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: start.length, length: 0))
            controller.refreshState()
        }

        /// Text composed after the caret, as an input method or a prediction puts it.
        func compose(_ text: String) {
            textView.setMarkedText(text, selectedRange: NSRange(location: 0, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// What SwiftUI does on its next update of the editor.
        func swiftUIUpdates() { coordinator.adopt(bound.value, into: textView) }

        var plain: String { NoteDocument.plainText(from: textView.textStorage!) }
    }

    @Test("marked text is not reported as a change — the binding never hears of it")
    func markedTextIsSilent() {
        let e = Editor("Hello")
        e.compose(" world")
        #expect(e.textView.hasMarkedText())
        #expect(NoteDocument.plainText(from: e.bound.value) == "Hello")
    }

    @Test("a SwiftUI update leaves text being composed alone")
    func updateLeavesMarkedText() {
        let e = Editor("Hello")
        e.textView.insertText("!", replacementRange: e.textView.selectedRange())
        e.compose(" world")
        e.swiftUIUpdates()
        #expect(e.textView.hasMarkedText(), "the prediction should still be showing")
        #expect(e.textView.string == "Hello! world")
    }

    @Test("a SwiftUI update long after the edit still leaves it alone")
    func lateUpdate() {
        let e = Editor("Hello")
        let early = e.bound.value
        e.textView.insertText("!", replacementRange: e.textView.selectedRange())
        e.compose(" world")
        // An update carrying the text as it was before the last keystroke.
        e.coordinator.adopt(early, into: e.textView)
        e.swiftUIUpdates()
        #expect(e.textView.string == "Hello! world")
    }

    @Test("a note opened while text is being composed replaces it cleanly")
    func externalTextOverMarkedText() {
        let e = Editor("Hello")
        e.compose(" world")
        e.coordinator.adopt(NoteDocument.attributed(fromPlainText: "Another note"), into: e.textView)
        #expect(!e.textView.hasMarkedText())
        #expect(e.plain == "Another note")
    }

    @Test("toolbar tools work while text is being composed")
    func toolbarWithMarkedText() {
        let tools: [(String, (RichTextController) -> Void)] = [
            ("bulleted list", { $0.toggleBulletList() }),
            ("numbered list", { $0.toggleNumberedList() }),
            ("checklist", { $0.toggleChecklist() }),
            ("heading", { $0.setHeading(1) }),
            ("quote", { $0.toggleQuote() }),
            ("alignment", { $0.setAlignment(.center) }),
            ("bold", { $0.toggleBold() }),
            ("underline", { $0.toggleUnderline() }),
            ("colour", { $0.setColor("#d4351c") }),
            ("clear formatting", { $0.clearFormatting() }),
            ("link", { $0.insertLink("example.com", title: "site") }),
            ("date", { $0.insertText(" today") }),
            ("divider", { $0.insertDivider() }),
        ]
        for (name, use) in tools {
            let e = Editor("Hello")
            e.compose(" world")
            use(e.controller)
            #expect(!e.textView.hasMarkedText(), "\(name) left text half-composed")
            e.swiftUIUpdates()
        }
    }

    @Test("Return in a checklist item while text is being composed starts the next item")
    func checklistReturnWithMarkedText() {
        let e = Editor("☐ Milk")
        e.compose(" and eggs")
        e.textView.insertNewline(nil)
        e.textView.insertText("Bread", replacementRange: e.textView.selectedRange())
        #expect(e.plain == "☐ Milk and eggs\n☐ Bread")
    }

    @Test("Backspace while text is being composed")
    func backspaceWithMarkedText() {
        let e = Editor("• Milk")
        e.compose("s")
        e.textView.deleteBackward(nil)
        e.swiftUIUpdates()
        #expect(!e.textView.string.isEmpty)
    }
}
