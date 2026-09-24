import Foundation
import Testing
@testable import FourNotes

// Images moved out of the document. These check that nothing is lost on the way
// out or on the way back in — a backup has to stay readable by the web app.

@Suite("Attachments")
struct AttachmentTests {

    /// A one-pixel JPEG, small enough to keep in the test.
    private var sampleJPEG: Data {
        Data(base64Encoded: """
        /9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a\
        HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA\
        AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==
        """.replacingOccurrences(of: "\n", with: ""))!
    }

    @Test("an inline image is moved to a file and can be read back")
    func extractAndRead() throws {
        var document = AppData()
        let inline = "data:image/jpeg;base64," + sampleJPEG.base64EncodedString()
        document.transactions = [Transaction(id: "t1", createdAt: "2026-09-01T00:00:00.000Z",
                                             updatedAt: "2026-09-01T00:00:00.000Z",
                                             merchant: "Warung", amount: 25_000,
                                             date: "2026-09-01", imageDataUrl: inline)]

        let moved = Attachments.extractInlineImages(&document)
        #expect(moved == 1)

        let file = try #require(document.transactions.first?.imageFile)
        defer { Attachments.remove(file) }
        #expect(document.transactions.first?.imageDataUrl == nil, "the inline copy should be dropped")
        #expect(Attachments.data(for: file) == sampleJPEG, "the bytes should survive the move")
    }

    @Test("a backup inlines images again so it stays self-contained")
    func inlineForExport() throws {
        var document = AppData()
        let inline = "data:image/jpeg;base64," + sampleJPEG.base64EncodedString()
        document.notes = [Note(id: "n1", createdAt: "2026-09-01T00:00:00.000Z",
                               updatedAt: "2026-09-01T00:00:00.000Z", title: "Scan",
                               imageDataUrl: inline)]
        Attachments.extractInlineImages(&document)
        let file = try #require(document.notes.first?.imageFile)
        defer { Attachments.remove(file) }

        let exported = Attachments.inliningImages(document)
        #expect(exported.notes.first?.imageDataUrl == inline, "the export lost its image")
    }

    @Test("moving is not repeated on the next load")
    func idempotent() throws {
        var document = AppData()
        document.notes = [Note(id: "n1", createdAt: "2026-09-01T00:00:00.000Z",
                               updatedAt: "2026-09-01T00:00:00.000Z", title: "Scan",
                               imageDataUrl: "data:image/jpeg;base64," + sampleJPEG.base64EncodedString())]
        #expect(Attachments.extractInlineImages(&document) == 1)
        let file = try #require(document.notes.first?.imageFile)
        defer { Attachments.remove(file) }
        #expect(Attachments.extractInlineImages(&document) == 0, "a second pass should find nothing")
    }

    @Test("an imported file name is materialized when its file is missing")
    func importedInlineImage() throws {
        let name = "fournotes-import-\(UUID().uuidString).jpg"
        Attachments.remove(name)
        var document = AppData()
        let inline = "data:image/jpeg;base64," + sampleJPEG.base64EncodedString()
        document.transactions = [Transaction(id: "t1", createdAt: "2026-09-01T00:00:00.000Z",
                                             updatedAt: "2026-09-01T00:00:00.000Z",
                                             merchant: "Imported", amount: 25_000,
                                             date: "2026-09-01", imageDataUrl: inline,
                                             imageFile: name)]
        defer { Attachments.remove(name) }

        #expect(Attachments.extractInlineImages(&document) == 1)
        #expect(document.transactions.first?.imageFile == name)
        #expect(document.transactions.first?.imageDataUrl == nil)
        #expect(Attachments.data(for: name) == sampleJPEG)
    }

    @Test("a file name cannot escape the attachments directory")
    func rejectsTraversal() {
        #expect(Attachments.url(for: "../secret.json") == nil)
        #expect(Attachments.data(for: "../../Library/key") == nil)
        #expect(Attachments.save(sampleJPEG, name: "../escaped.jpg") == nil)
    }

    @Test("a row with no image is left alone")
    func noImage() {
        var document = AppData()
        document.notes = [Note(id: "n1", createdAt: "2026-09-01T00:00:00.000Z",
                               updatedAt: "2026-09-01T00:00:00.000Z", title: "Plain")]
        #expect(Attachments.extractInlineImages(&document) == 0)
        #expect(document.notes.first?.imageFile == nil)
    }
}
