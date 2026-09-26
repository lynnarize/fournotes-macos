import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// Rich text pasted from a web page came in as the page looked: its grey
// background behind every line, its fonts and colours — and every list item
// with two bullets, because AppKit's HTML reader writes the marker into the
// text as well as making the paragraph a list item. The shape of a Reddit
// post: paragraphs, a bold line as a heading, inline code in a list.

@MainActor
@Suite("Pasting into a note", .serialized)
struct EditorPasteTests {

    private static let post = """
    <div style="background-color: rgb(246,247,248); color: rgb(26,26,27); font-family: Arial; font-size: 14px">
    <p>Hi everyone! I'm the dev.</p>
    <p><strong>The problem</strong></p>
    <p>Every app wants a subscription.</p>
    <ul><li><p><code>i spent $4 on lunch</code>: logs the expense</p></li><li><p><code>Remind me</code>: a task</p></li></ul>
    <ol><li>First</li><li>Second</li></ol>
    <p><em>It shows what it filed.</em> <a href="https://example.com">Site</a></p>
    <h2>One More Thing</h2>
    </div>
    """

    private static var imported: NSAttributedString {
        try! NSAttributedString(data: Data(post.utf8),
                                options: [.documentType: NSAttributedString.DocumentType.html,
                                          .characterEncoding: String.Encoding.utf8.rawValue],
                                documentAttributes: nil)
    }

    @Test("a web page's text comes in as a note would write it")
    func webPageAsNote() {
        let pasted = NoteDocument.pasted(Self.imported)
        #expect(NoteDocument.plainText(from: pasted) == """
        Hi everyone! I'm the dev.

        The problem

        Every app wants a subscription.

        • i spent $4 on lunch: logs the expense
        • Remind me: a task

        1. First
        2. Second

        It shows what it filed. Site

        ## One More Thing
        """)
    }

    @Test("list items have one bullet: the marker is not left in the text")
    func oneBullet() {
        let pasted = NoteDocument.pasted(Self.imported).string
        #expect(!pasted.contains("\t"))
        #expect(!pasted.contains("•"))
    }

    @Test("pasted text takes the note's line spacing")
    func noteSpacing() {
        // It had AppKit's line height, cramped beside the note's, until the
        // note was opened again.
        let pasted = NoteDocument.pasted(Self.imported)
        let text = pasted.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let style = pasted.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle
            #expect(style?.lineHeightMultiple == NoteDocument.lineHeightMultiple,
                    "\(text.substring(with: paragraph).debugDescription)")
        }
    }

    @Test("the page's look is left behind; bold, italic, code and links stay")
    func lookDropped() throws {
        let pasted = NoteDocument.pasted(Self.imported)
        let full = NSRange(location: 0, length: pasted.length)
        pasted.enumerateAttributes(in: full, options: []) { attributes, _, _ in
            #expect(attributes[.backgroundColor] == nil)
            if let color = attributes[.foregroundColor] as? NSColor { #expect(color == NSColor.labelColor) }
            if let font = attributes[.font] as? NSFont {
                #expect(font.familyName == NoteDocument.bodyFont.familyName
                        || font.familyName == NoteDocument.codeFont.familyName)
            }
        }
        func font(of text: String) throws -> NSFont {
            let at = (pasted.string as NSString).range(of: text).location
            return try #require(pasted.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        }
        #expect(NSFontManager.shared.traits(of: try font(of: "The problem")).contains(.boldFontMask))
        #expect(NSFontManager.shared.traits(of: try font(of: "It shows")).contains(.italicFontMask))
        #expect(try font(of: "Remind me").familyName == NoteDocument.codeFont.familyName)
        let site = (pasted.string as NSString).range(of: "Site").location
        #expect((pasted.attribute(.link, at: site, effectiveRange: nil) as? URL)?.host == "example.com")
    }

    // MARK: - Through the editor

    @MainActor
    private final class Editor {
        let controller = RichTextController()
        let coordinator: RichTextEditor<EmptyView>.Coordinator
        let textView: NoteTextView
        let window: NSWindow

        init(_ text: String) {
            let start = NoteDocument.attributed(fromPlainText: text)
            let editor = RichTextEditor(attributed: .constant(start), controller: controller,
                                        onTextChange: { _ in }, header: EmptyView())
            coordinator = editor.makeCoordinator()
            textView = RichTextEditor<EmptyView>.makeTextView(controller: controller, coordinator: coordinator,
                                                              text: start)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = textView
            window.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: start.length, length: 0))
        }

        var plain: String { NoteDocument.plainText(from: textView.textStorage!) }
    }

    private func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name(UUID().uuidString)) }

    @Test("pasting HTML into a note cleans it", arguments: [NSPasteboard.PasteboardType.html, .rtf])
    func pasteRich(_ type: NSPasteboard.PasteboardType) throws {
        let board = pasteboard()
        board.clearContents()
        if type == .html {
            board.setString(Self.post, forType: .html)
        } else {
            let rtf = try #require(Self.imported.rtf(from: NSRange(location: 0, length: Self.imported.length)))
            board.setData(rtf, forType: .rtf)
        }
        let e = Editor("")
        #expect(e.textView.readSelection(from: board, type: type))
        #expect(e.plain.hasPrefix("Hi everyone! I'm the dev.\n\nThe problem"))
        #expect(e.plain.contains("• Remind me: a task\n\n1. First"))
        #expect(!e.textView.string.contains("\t"))
    }

    @Test("text copied from one note to another keeps its checkboxes and colours")
    func noteToNote() throws {
        let source = Editor("☐ Milk\n☑ Eggs")
        source.textView.setSelectedRange(NSRange(location: 0, length: source.textView.textStorage!.length))
        source.controller.setColor("#d4351c")
        let board = pasteboard()
        board.clearContents()
        #expect(source.textView.writeSelection(to: board, types: source.textView.writablePasteboardTypes))

        let target = Editor("")
        let type = try #require(target.textView.preferredPasteboardType(from: board.types ?? [],
                                                                         restrictedToTypesFrom: nil))
        #expect(type == NoteTextView.noteTextType)
        #expect(target.textView.readSelection(from: board, type: type))
        #expect(target.plain == "☐ Milk\n☑ Eggs")
        let color = target.textView.textStorage!.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(color?.hexString == "#d4351c")
    }

    @Test("a paste undoes in one step")
    func pasteUndoes() {
        let board = pasteboard()
        board.clearContents()
        board.setString(Self.post, forType: .html)
        let e = Editor("Before")
        let undo = e.textView.undoManager!
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        _ = e.textView.readSelection(from: board, type: .html)
        undo.endUndoGrouping()
        e.controller.undo()
        #expect(e.plain == "Before")
    }
}
