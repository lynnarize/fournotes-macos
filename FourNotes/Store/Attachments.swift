import AppKit
import Foundation

// Scanned receipts used to live inside the document as base64 data URLs — a
// habit carried over from localStorage. Every scan added tens of kilobytes to a
// file that is re-encoded on every save, and every list row base64-decoded its
// thumbnail again on every render.
//
// Images are files now. The document keeps a filename, and a backup export
// inlines them again so it stays self-contained and readable by the web app.

enum Attachments {
    /// Where images live, beside the document.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FourNotes/Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func url(for name: String) -> URL? {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"),
              name == (name as NSString).lastPathComponent else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Writes an image and returns the name to store on the row.
    @discardableResult
    static func save(_ jpeg: Data, name: String = "\(UUID().uuidString).jpg") -> String? {
        guard let destination = url(for: name) else { return nil }
        do {
            try jpeg.write(to: destination, options: .atomic)
            return name
        } catch {
            NSLog("Four Notes: could not save an attachment (\(error))")
            return nil
        }
    }

    static func data(for name: String) -> Data? {
        guard let destination = url(for: name) else { return nil }
        return try? Data(contentsOf: destination)
    }

    static func remove(_ name: String) {
        guard let destination = url(for: name) else { return }
        try? FileManager.default.removeItem(at: destination)
    }

    /// Decoded thumbnails, kept so a list row does not rebuild its image on
    /// every render.
    // NSCache is documented as thread-safe; it just is not marked Sendable.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let data = data(for: name), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }

    /// An image referenced either way: by file (ours) or inline (a document
    /// written by the web app, or an older version of this one).
    static func image(file: String?, dataUrl: String?) -> NSImage? {
        if let file, let image = image(named: file) { return image }
        return ImageKit.image(fromDataUrl: dataUrl)
    }

    // MARK: - Moving between the two forms

    /// Writes any inline image out to a file. Returns how many were moved.
    @discardableResult
    static func extractInlineImages(_ document: inout AppData) -> Int {
        var moved = 0
        // Each row is copied out first: two `inout` projections through the same
        // array subscript overlap, which the compiler rightly refuses.
        for i in document.notes.indices {
            var note = document.notes[i]
            guard extract(&note) else { continue }
            document.notes[i] = note
            moved += 1
        }
        for i in document.transactions.indices {
            var transaction = document.transactions[i]
            guard extract(&transaction) else { continue }
            document.transactions[i] = transaction
            moved += 1
        }
        return moved
    }

    private static func extract(_ note: inout Note) -> Bool {
        guard let name = moveOut(dataUrl: note.imageDataUrl, existing: note.imageFile) else { return false }
        note.imageFile = name
        note.imageDataUrl = nil
        return true
    }

    private static func extract(_ transaction: inout Transaction) -> Bool {
        guard let name = moveOut(dataUrl: transaction.imageDataUrl,
                                 existing: transaction.imageFile) else { return false }
        transaction.imageFile = name
        transaction.imageDataUrl = nil
        return true
    }

    private static func moveOut(dataUrl: String?, existing: String?) -> String? {
        guard let dataUrl, let jpeg = jpegData(fromDataUrl: dataUrl) else { return nil }
        if let existing, data(for: existing) != nil { return existing }
        if let existing, url(for: existing) != nil { return save(jpeg, name: existing) }
        return save(jpeg)
    }

    /// A copy with images inlined again, so an exported backup carries them and
    /// the web app can still read it.
    static func inliningImages(_ document: AppData) -> AppData {
        var copy = document
        for i in copy.notes.indices where copy.notes[i].imageDataUrl == nil {
            copy.notes[i].imageDataUrl = inlineForm(of: copy.notes[i].imageFile)
        }
        for i in copy.transactions.indices where copy.transactions[i].imageDataUrl == nil {
            copy.transactions[i].imageDataUrl = inlineForm(of: copy.transactions[i].imageFile)
        }
        return copy
    }

    private static func inlineForm(of file: String?) -> String? {
        guard let file, let data = data(for: file) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    /// Deletes files no row refers to any more.
    static func removeOrphans(keeping document: AppData) {
        let live = Set(document.notes.compactMap(\.imageFile)
                       + document.transactions.compactMap(\.imageFile))
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in existing where !live.contains(name) { remove(name) }
    }

    private static func jpegData(fromDataUrl dataUrl: String) -> Data? {
        guard let comma = dataUrl.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataUrl[dataUrl.index(after: comma)...]))
    }
}
