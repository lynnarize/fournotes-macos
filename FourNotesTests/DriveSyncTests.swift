import AppKit
import Foundation
import Testing
@testable import FourNotes

// Google Drive sync. The file is shared with the web app, so the shape, the
// merge and the fingerprint have to match src/lib/gdrive.ts exactly, and a
// mistake here loses data on every device at once.

/// Drive in memory: newest first, like the real listing.
@MainActor
private final class FakeDrive: DriveStore {
    var files: [(file: DriveFile, body: Data)] = []
    var uploads = 0
    var deletes: [String] = []
    private var clock = 0

    private func stamp() -> String {
        clock += 1
        return String(format: "2026-09-25T00:00:%02d.000Z", clock)
    }

    func list() async throws -> [DriveFile] {
        files.map(\.file).sorted { $0.modifiedTime > $1.modifiedTime }
    }

    func download(_ id: String) async throws -> Data {
        guard let entry = files.first(where: { $0.file.id == id }) else { throw DriveError.notFound }
        return entry.body
    }

    func upload(_ id: String?, _ body: Data) async throws -> DriveFile {
        uploads += 1
        let file = DriveFile(id: id ?? "file-\(files.count + 1)", modifiedTime: stamp())
        files.removeAll { $0.file.id == file.id }
        files.append((file, body))
        return file
    }

    func delete(_ id: String) async throws {
        deletes.append(id)
        files.removeAll { $0.file.id == id }
    }

    /// Another device writing the file.
    func put(_ id: String, _ data: AppData) throws {
        files.removeAll { $0.file.id == id }
        files.append((DriveFile(id: id, modifiedTime: stamp()), try DriveSync.encode(data)))
    }

    func json(_ id: String) throws -> [String: Any] {
        let body = try #require(files.first { $0.file.id == id }?.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

private func note(_ id: String, _ updatedAt: String, title: String = "Note") -> Note {
    Note(id: id, createdAt: "2026-09-01T00:00:00.000Z", updatedAt: updatedAt, title: title)
}

@Suite("Google Drive sync")
@MainActor
struct DriveSyncTests {

    private func run(_ drive: FakeDrive, _ local: inout AppData, _ cursor: SyncCursor = SyncCursor()) async throws -> SyncCursor {
        var applied: [AppData] = []
        let next = try await DriveSync.run(drive: drive, local: local, cursor: cursor) { applied.append($0) }
        for remote in applied { local = DriveSync.merge(local, remote) }
        return next
    }

    @Test("the first sync creates the file, without samples, scans or Mac-only settings")
    func firstSync() async throws {
        let drive = FakeDrive()
        var local = AppData()
        var scanned = note("n1", "2026-09-01T00:00:00.000Z")
        scanned.imageFile = "scan.jpg"
        scanned.imageDataUrl = "data:image/jpeg;base64,AAAA"
        var sample = note("s1", "2026-09-01T00:00:00.000Z")
        sample.sample = true
        local.notes = [scanned, sample]
        local.settings.theme = .dark
        local.settings.categories = ["Pets"]

        let cursor = try await run(drive, &local)

        #expect(drive.uploads == 1)
        #expect(cursor.fileId == "file-1")
        let json = try drive.json("file-1")
        #expect(json["app"] as? String == "four-notes")
        #expect(json["version"] as? Int == 1)
        let notes = try #require(json["notes"] as? [[String: Any]])
        #expect(notes.map { $0["id"] as? String } == ["n1"])
        #expect(notes[0]["imageFile"] == nil)
        #expect(notes[0]["imageDataUrl"] == nil)
        let settings = try #require(json["settings"] as? [String: Any])
        #expect(settings["theme"] == nil)
        #expect(settings["categories"] == nil)
    }

    @Test("a note edited on the Mac tells the web app its old HTML is gone")
    func htmlIsNulled() async throws {
        let drive = FakeDrive()
        var local = AppData()
        local.notes = [note("n1", "2026-09-01T00:00:00.000Z")]
        _ = try await run(drive, &local)
        let notes = try #require(try drive.json("file-1")["notes"] as? [[String: Any]])
        // Present and null, so the web app's `{ ...local, ...row }` clears it.
        #expect(notes[0]["html"] is NSNull)
        #expect(notes[0]["richText"] is NSNull)
    }

    @Test("nothing changed: no upload, and no download either")
    func unchanged() async throws {
        let drive = FakeDrive()
        var local = AppData()
        local.notes = [note("n1", "2026-09-01T00:00:00.000Z")]
        let first = try await run(drive, &local)
        let second = try await run(drive, &local, first)
        #expect(drive.uploads == 1)
        #expect(second == first)
    }

    @Test("newer rows win in both directions")
    func newerWins() async throws {
        let drive = FakeDrive()
        var other = AppData()
        other.notes = [note("a", "2026-09-05T00:00:00.000Z", title: "Web edit"),
                       note("b", "2026-09-01T00:00:00.000Z", title: "Old web")]
        try drive.put("web", other)

        var local = AppData()
        local.notes = [note("a", "2026-09-02T00:00:00.000Z", title: "Mac old"),
                       note("b", "2026-09-06T00:00:00.000Z", title: "Mac edit")]
        _ = try await run(drive, &local)

        #expect(local.notes.first { $0.id == "a" }?.title == "Web edit")
        #expect(local.notes.first { $0.id == "b" }?.title == "Mac edit")
        let uploaded = try DriveSync.decode(try await drive.download("web"))
        #expect(uploaded.notes.first { $0.id == "a" }?.title == "Web edit")
        #expect(uploaded.notes.first { $0.id == "b" }?.title == "Mac edit")
    }

    @Test("duplicate files are folded in, then removed")
    func duplicates() async throws {
        let drive = FakeDrive()
        var one = AppData()
        one.notes = [note("x", "2026-09-01T00:00:00.000Z")]
        var two = AppData()
        two.todos = [Todo(id: "t", createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z")]
        try drive.put("older", one)
        try drive.put("newer", two)

        var local = AppData()
        _ = try await run(drive, &local)

        #expect(drive.deletes == ["older"])
        let kept = try DriveSync.decode(try await drive.download("newer"))
        #expect(kept.notes.map(\.id) == ["x"])
        #expect(kept.todos.map(\.id) == ["t"])
        #expect(local.notes.map(\.id) == ["x"])
    }

    @Test("rows this version can't read stop the upload")
    func unreadableRows() async throws {
        let drive = FakeDrive()
        let body = """
        {"app":"four-notes","version":1,"savedAt":"","notes":[
          {"id":"n","createdAt":"2026-09-01T00:00:00.000Z","updatedAt":"2026-09-01T00:00:00.000Z",
           "title":"From the future","content":"","source":"telepathy","tags":[]}],
         "todos":[],"transactions":[],"stickies":[],"settings":{"currency":"IDR","budgets":{},"voiceReplies":true}}
        """
        drive.files = [(DriveFile(id: "f", modifiedTime: "2026-09-01T00:00:00.000Z"), Data(body.utf8))]
        var local = AppData()
        local.notes = [note("mine", "2026-09-02T00:00:00.000Z")]

        await #expect(throws: DriveError.unreadableRows(1)) { _ = try await run(drive, &local) }
        #expect(drive.uploads == 0)
    }

    @Test("rich text older than the note's text is dropped")
    func staleRichText() throws {
        let bold = NSAttributedString(string: "Before", attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        let archive = try #require(NoteDocument.archive(bold))
        var stale = note("stale", "2026-09-02T00:00:00.000Z")
        stale.content = "After, edited on the web"
        stale.richText = archive
        var current = note("current", "2026-09-02T00:00:00.000Z")
        current.content = "Before"
        current.richText = archive
        var data = AppData()
        data.notes = [stale, current]

        let back = try DriveSync.decode(try DriveSync.encode(DriveSync.payload(data)))
        #expect(back.notes.first { $0.id == "stale" }?.richText == nil)
        #expect(back.notes.first { $0.id == "current" }?.richText == archive)
    }

    @Test("the fingerprint matches the web app's")
    func signatureParity() {
        var data = AppData()
        data.notes = [note("n2", "2026-09-02T00:00:00.000Z"), note("n1", "2026-09-01T00:00:00.000Z")]
        data.todos = [Todo(id: "t1", createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-03T00:00:00.000Z")]
        data.settings.updatedAt = "2026-09-04T00:00:00.000Z"
        // Computed with the signature() in src/lib/gdrive.ts.
        #expect(DriveSync.signature(data) == "110-18e54d2d")
    }

    @Test("a newer row from Drive keeps this Mac's scan, and untouched settings don't reset it")
    func applyKeepsLocal() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fournotes-sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = Store(persistence: Persistence(fileURL: url))
        let local = store.addNote {
            $0.title = "Receipt"
            $0.imageFile = "receipt.jpg"
        }
        store.updateSettings { $0.currency = "USD" }

        var remote = AppData()
        var edited = local
        edited.title = "Receipt, renamed on the web"
        edited.imageFile = nil
        edited.updatedAt = "2999-01-01T00:00:00.000Z"
        remote.notes = [edited]
        remote.settings.updatedAt = nil
        store.applySync(remote)

        let merged = store.all.notes.first { $0.id == local.id }
        #expect(merged?.title == "Receipt, renamed on the web")
        #expect(merged?.imageFile == "receipt.jpg")
        #expect(store.settings.currency == "USD")
    }

    @Test("the redirect scheme is the reversed client ID")
    func redirectScheme() {
        #expect(GoogleAuth.redirectScheme(for: "123-abc.apps.googleusercontent.com")
                == "com.googleusercontent.apps.123-abc")
    }
}
