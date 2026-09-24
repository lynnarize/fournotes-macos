import Foundation
import Testing
@testable import FourNotes

@Suite("Archive size")
struct ArchiveSizeTests {
    @Test("the native archive is small enough to keep in the document")
    func size() throws {
        let short = "☐ Buy groceries\n• Bandung\n# Heading"
        let long = String(repeating: "A paragraph of ordinary note text that someone typed. ", count: 60)

        for (name, text) in [("short", short), ("long", long)] {
            let data = try #require(NoteDocument.archive(NoteDocument.attributed(fromPlainText: text)))
            let base64 = data.base64EncodedData().count
            print("  \(name): text \(text.utf8.count)B, archive \(data.count)B, base64 \(base64)B")
            #expect(base64 < 200_000)
        }
    }
}
