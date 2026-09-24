import AppKit
import Testing
@testable import FourNotes

// The converter between what the editor shows and what everything else reads.
// The old HTML round-trip lost lists, checklists and dividers in both
// directions — silently — so this is the suite that has to be thorough.

@Suite("NoteDocument round-trip")
struct NoteDocumentTests {

    /// plain -> attributed -> plain must be the identity for everything the
    /// toolbar can produce.
    private func roundTrip(_ text: String) -> String {
        NoteDocument.plainText(from: NoteDocument.attributed(fromPlainText: text))
    }

    @Test("plain paragraphs")
    func paragraphs() {
        #expect(roundTrip("Hello") == "Hello")
        #expect(roundTrip("One\nTwo\nThree") == "One\nTwo\nThree")
    }

    @Test("bulleted lists survive")
    func bullets() {
        let text = "• Bandung\n• Bali\n• Lombok"
        #expect(roundTrip(text) == text)
    }

    @Test("numbered lists survive and renumber")
    func numbered() {
        #expect(roundTrip("1. First\n2. Second\n3. Third") == "1. First\n2. Second\n3. Third")
        // Whatever numbers the source used, the document renumbers from one.
        #expect(roundTrip("1. First\n1. Second\n1. Third") == "1. First\n2. Second\n3. Third")
    }

    @Test("checklists survive, checked and unchecked")
    func checklists() {
        let text = "☐ Buy groceries\n☑ Book dentist\n☐ Pay rent"
        #expect(roundTrip(text) == text)
    }

    @Test("headings survive at every level")
    func headings() {
        let text = "# Trip\n## Bandung\n### Coffee"
        #expect(roundTrip(text) == text)
    }

    @Test("quotes survive")
    func quotes() {
        #expect(roundTrip("> Remember this") == "> Remember this")
    }

    @Test("a mixed document survives intact")
    func mixed() {
        let text = """
        # Weekend trip

        Places to consider
        • Bandung — short drive, good coffee
        • Bali — flights are cheaper midweek

        ☐ Book the hotel
        ☑ Ask Andi

        1. Pack
        2. Leave early
        """
        #expect(roundTrip(text) == text)
    }

    @Test("a checklist really is a checkbox, not a character")
    func checkboxIsAnAttachment() throws {
        let document = NoteDocument.attributed(fromPlainText: "☐ Buy groceries")
        let checkbox = try #require(NoteDocument.firstCheckbox(in: document),
                                    "the checklist item should carry a real checkbox")
        #expect(checkbox.isChecked == false)
        #expect(!document.string.contains("☐"), "the marker should not be literal text")
    }

    @Test("a bullet really is an NSTextList")
    func bulletIsATextList() throws {
        let document = NoteDocument.attributed(fromPlainText: "• Bandung")
        let style = try #require(document.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                                 as? NSParagraphStyle)
        #expect(style.textLists.first?.markerFormat == .disc)
        #expect(!document.string.contains("•"), "the marker should not be literal text")
    }

    @Test("toggling a checkbox changes what the rest of the app reads")
    func togglingUpdatesPlainText() throws {
        let document = NoteDocument.attributed(fromPlainText: "☐ Buy groceries")
        let checkbox = try #require(NoteDocument.firstCheckbox(in: document))
        checkbox.isChecked = true
        #expect(NoteDocument.plainText(from: document) == "☑ Buy groceries")
    }

    @Test("the native archive keeps checkboxes and lists")
    func archiveRoundTrip() throws {
        let text = "☐ Buy groceries\n• Bandung\n# Heading"
        let original = NoteDocument.attributed(fromPlainText: text)
        let data = try #require(NoteDocument.archive(original))
        let restored = try #require(NoteDocument.unarchive(data))
        #expect(NoteDocument.plainText(from: restored) == text)
    }

    @Test("an empty note is empty, not a stray marker")
    func empty() {
        #expect(roundTrip("") == "")
        #expect(NoteDocument.attributed(fromPlainText: "").length == 0)
    }

    @Test("markdown-style bullets from the assistant are understood")
    func assistantBullets() {
        // The assistant writes "- item"; the app shows and stores "• item".
        #expect(roundTrip("- Bandung\n- Bali") == "• Bandung\n• Bali")
    }

    // MARK: - Lists that look right, not just read right

    @Test("a numbered list rebuilt from text counts 1, 2, 3 on screen")
    func numberedListIsOneList() throws {
        // Each item used to get its own NSTextList, so the text read "1. 2. 3."
        // while the editor drew "1. 1. 1.".
        let document = NoteDocument.attributed(fromPlainText: "1. First\n2. Second\n3. Third")
        let third = (document.string as NSString).range(of: "Third").location
        let style = try #require(document.attribute(.paragraphStyle, at: third, effectiveRange: nil)
                                 as? NSParagraphStyle)
        let list = try #require(style.textLists.last)
        #expect(document.itemNumber(in: list, at: third) == 3)
    }

    @Test("a paragraph between two lists starts the numbering again")
    func numberingRestarts() {
        #expect(roundTrip("1. One\n2. Two\n\nBreak\n1. Again") == "1. One\n2. Two\n\nBreak\n1. Again")
    }

    @Test("nested lists keep their levels", arguments: [
        "• Trip\n  • Bandung\n  • Bali\n• Budget",
        "1. Pack\n  1. Clothes\n  2. Charger\n2. Leave",
        "• Mixed\n  1. First\n  2. Second",
        "☐ Book\n  ☐ Hotel\n  ☑ Flight\n☐ Pack",
    ])
    func nested(_ text: String) {
        #expect(roundTrip(text) == text)
    }

    @Test("a nested list is drawn indented")
    func nestedIsIndented() throws {
        let document = NoteDocument.attributed(fromPlainText: "• Outer\n  • Inner")
        let inner = (document.string as NSString).range(of: "Inner").location
        let style = try #require(document.attribute(.paragraphStyle, at: inner, effectiveRange: nil)
                                 as? NSParagraphStyle)
        #expect(style.textLists.count == 2)
        #expect(style.headIndent > NoteDocument.indentStep)
    }

    @Test("dividers are stored the way the web app writes them", arguments: ["---", "———", "***"])
    func dividers(_ marker: String) {
        #expect(roundTrip("Above\n\(marker)\nBelow") == "Above\n---\nBelow")
    }

    // MARK: - Formatting that has to be kept

    @Test("a font choice is formatting worth keeping")
    func fontFamilyIsFormatting() throws {
        // Serif and Monospace were silently dropped on save: nothing counted a
        // different typeface as formatting, so only the plain text was kept.
        let serif = try #require(NSFont(name: "Georgia", size: NoteDocument.bodySize))
        let document = NSAttributedString(string: "Dear diary", attributes: [.font: serif])
        #expect(NoteDocument.hasInlineFormatting(document))
        let code = NSAttributedString(string: "let x = 1", attributes: [.font: NoteDocument.codeFont])
        #expect(NoteDocument.hasInlineFormatting(code))
    }

    @Test("plain body text still needs no archive")
    func plainNeedsNoArchive() {
        #expect(!NoteDocument.hasInlineFormatting(NoteDocument.attributed(fromPlainText: "• Just a list")))
    }
}

@Suite("Note tags")
struct TagTests {
    @Test("tags are cleaned the way the web app cleans them", arguments: [
        ("quick", "quick"), ("#Quick", "quick"), ("##idea", "idea"),
        ("  Road Trip  ", "road-trip"), ("a  b\tc", "a-b-c"),
    ])
    func clean(_ raw: String, _ expected: String) {
        #expect(NoteText.tag(raw) == expected)
    }

    @Test("nothing left means no tag")
    func empty() {
        #expect(NoteText.tag("") == nil)
        #expect(NoteText.tag("  # ") == nil)
    }

    @Test("long tags are cut to 30 characters")
    func long() {
        #expect(NoteText.tag(String(repeating: "x", count: 50))?.count == 30)
    }

    @Test("repeats collapse, keeping the first spelling's place")
    func repeats() {
        #expect(NoteText.tags(["quick", "#Quick", "work", "QUICK", ""]) == ["quick", "work"])
    }
}
