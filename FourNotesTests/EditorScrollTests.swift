import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// Pressing Return, or typing on, at the end of a note longer than the pane
// left the new line below the bottom edge: the page only grew at the next
// layout pass, after AppKit had already tried to scroll the caret into view,
// so there was nowhere to scroll to and the user had to scroll by hand. These
// drive the editor's own scroll view in a window, a layout pass after each key
// as the app gets one.

@MainActor
@Suite("Editor scrolling", .serialized)
struct EditorScrollTests {

    @MainActor
    private final class Pane {
        let controller = RichTextController()
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let scroll: NSScrollView
        let window: NSWindow

        init(_ text: String) {
            let start = NoteDocument.attributed(fromPlainText: text)
            let editor = RichTextEditor(attributed: .constant(start), controller: controller,
                                        onTextChange: { _ in }, header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator,
                                                              text: start)
            scroll = RichTextEditor<EmptyView>.makeScrollView(around: textView, column: TextColumn())
            // A header the height of the note's title and properties.
            (scroll.documentView as? NoteDocumentView)?.header.rootView = AnyView(Color.clear.frame(height: 160))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = scroll
            window.makeFirstResponder(textView)
            settle()
            textView.setSelectedRange(NSRange(location: start.length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
            settle()
        }

        /// The layout pass the app gets after each key.
        func settle() {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        /// The caret's line, in the scroll view's visible area. Measured the
        /// way TextKit 2 places the insertion point.
        var caretInView: Bool {
            guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
                  let location = content.location(content.documentRange.location,
                                                  offsetBy: textView.selectedRange().location) else { return false }
            var caret: NSRect?
            manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard,
                                          options: [.rangeNotRequired]) { _, frame, _, _ in
                caret = frame
                return false
            }
            guard let caret else { return false }
            let origin = textView.textContainerOrigin
            let line = scroll.contentView.convert(caret.offsetBy(dx: origin.x, dy: origin.y), from: textView)
            let visible = scroll.contentView.bounds
            return line.minY >= visible.minY - 1 && line.maxY <= visible.maxY + 1
        }

        var scrolledTo: CGFloat { scroll.contentView.bounds.minY }

        /// Between the caret's line and the bottom of the visible area.
        var roomBelowCaret: CGFloat {
            guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
                  let location = content.location(content.documentRange.location,
                                                  offsetBy: textView.selectedRange().location) else { return 0 }
            var caret = NSRect.zero
            manager.enumerateTextSegments(in: NSTextRange(location: location), type: .standard,
                                          options: [.rangeNotRequired]) { _, frame, _, _ in
                caret = frame
                return false
            }
            let origin = textView.textContainerOrigin
            let line = scroll.contentView.convert(caret.offsetBy(dx: origin.x, dy: origin.y), from: textView)
            return scroll.contentView.bounds.maxY - line.maxY
        }
    }

    @Test("Return at the end of a note keeps the new line in view")
    func returnKeepsCaretInView() {
        let p = Pane("First line")
        for press in 1...30 {
            p.textView.insertNewline(nil)
            p.settle()
            #expect(p.caretInView, "the caret went out of view after Return \(press)")
        }
        #expect(p.scrolledTo > 0, "the note should have scrolled")
        #expect(p.roomBelowCaret >= NoteTextView.typingRoom - 1, "the new line should have room beneath it")
    }

    @Test("typing a long paragraph at the end keeps the caret in view")
    func typingKeepsCaretInView() {
        let p = Pane("Start")
        for word in 1...300 {
            p.textView.insertText(" word\(word)", replacementRange: p.textView.selectedRange())
            p.settle()
            #expect(p.caretInView, "the caret went out of view at word \(word)")
        }
    }

    @Test("Return in a list or checklist at the end keeps the new item in view",
          arguments: ["• Item", "1. Item", "☐ Item"])
    func listReturnKeepsCaretInView(_ start: String) {
        let p = Pane(start)
        for press in 1...30 {
            p.textView.insertText("x", replacementRange: p.textView.selectedRange())
            p.textView.insertNewline(nil)
            p.settle()
            #expect(p.caretInView, "the caret went out of view after Return \(press)")
        }
    }

    @Test("pasting a long text at the end keeps the caret, after it, in view",
          arguments: [NSPasteboard.PasteboardType.rtf, NoteTextView.noteTextType])
    func pasteKeepsCaretInView(_ type: NSPasteboard.PasteboardType) throws {
        let p = Pane("Start")
        let long = NoteDocument.attributed(fromPlainText: (1...60).map { "Pasted line \($0)" }.joined(separator: "\n"))
        let data = try #require(type == .rtf
            ? long.rtf(from: NSRange(location: 0, length: long.length), documentAttributes: [:])
            : NoteDocument.archive(long))
        let board = NSPasteboard(name: NSPasteboard.Name("fournotes.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(data, forType: type)
        #expect(p.textView.readSelection(from: board, type: type))
        p.settle()
        #expect(p.textView.string.hasSuffix("Pasted line 60"))
        #expect(p.textView.selectedRange().location == (p.textView.string as NSString).length)
        #expect(p.caretInView, "the caret went out of view")
    }

    @Test("ticking a box far from the caret does not jump back to it")
    func tickingFarAwayDoesNotJump() throws {
        let p = Pane("Top\n" + (1...40).map { "☐ Task \($0)" }.joined(separator: "\n"))
        p.textView.setSelectedRange(NSRange(location: 1, length: 0))
        p.settle()
        // Scrolled down to the last box, the caret left at the top.
        let bottom = (p.scroll.documentView?.frame.height ?? 0) - p.scroll.contentView.bounds.height
        p.scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        p.scroll.reflectScrolledClipView(p.scroll.contentView)
        p.settle()
        let before = p.scrolledTo
        let lastBox = (p.textView.string as NSString).range(of: "\u{FFFC}", options: .backwards).location
        p.controller.toggleCheckbox(at: lastBox)
        p.settle()
        #expect(NoteDocument.plainText(from: p.textView.textStorage!).hasSuffix("☑ Task 40"))
        #expect(p.scrolledTo == before)
    }

    @Test("typing near the top of a long note does not move the page")
    func editingAboveDoesNotJump() {
        let p = Pane((1...60).map { "Line \($0)" }.joined(separator: "\n"))
        p.textView.setSelectedRange(NSRange(location: 3, length: 0))
        p.textView.scrollRangeToVisible(p.textView.selectedRange())
        p.settle()
        let before = p.scrolledTo
        p.textView.insertText("x", replacementRange: p.textView.selectedRange())
        p.settle()
        #expect(p.scrolledTo == before)
    }
}
