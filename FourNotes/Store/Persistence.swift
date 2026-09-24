import Foundation

/// Saves the whole document as one JSON file, in the same shape the web app
/// keeps in localStorage["four-notes:v1"] — so an export from one side imports
/// cleanly into the other, and the Drive/Supabase merge rules stay identical.
final class Persistence: Sendable {
    static let shared = Persistence()

    enum SaveError: LocalizedError {
        case encoding(Error)
        case writing(Error)

        var errorDescription: String? {
            switch self {
            case .encoding(let error):
                return "Your notes could not be prepared for saving (\(error.localizedDescription)). "
                    + "Nothing has been written; export a backup from Settings."
            case .writing(let error):
                return "Your notes could not be written to disk (\(error.localizedDescription))."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.fournotes.persistence", qos: .utility)
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FourNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("four-notes-v1.json")
        }
    }

    var location: URL { fileURL }

    /// Where a document we could not read is kept, so nothing overwrites it.
    var backupLocation: URL {
        fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
    }

    // MARK: - Loading

    enum LoadResult {
        case loaded(AppData)
        /// No document yet: a new install.
        case missing
        /// A document is there but could not be read. Never treat this as a
        /// new install — the next save would write an empty document over it.
        case unreadable(String)
    }

    func loadResult() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            if !FileManager.default.fileExists(atPath: fileURL.path) { return .missing }
            NSLog("Four Notes: could not open saved data (\(error))")
            return .unreadable(error.localizedDescription)
        }
        do {
            let decoded = try JSONDecoder().decode(AppData.self, from: data)
            // Rows we had to skip mean this file held something we could not
            // read. Keep the original before the app saves over it.
            if decoded.skippedRows > 0 { keepCopy(of: data) }
            return .loaded(decoded)
        } catch {
            let copy = keepCopy(of: data)
            NSLog("Four Notes: could not read saved data (\(error)); kept a copy at \(copy?.path ?? "—")")
            return .unreadable("The saved data could not be read. A copy is kept at \(copy?.path ?? backupLocation.path).")
        }
    }

    func load() -> AppData? {
        if case .loaded(let data) = loadResult() { return data }
        return nil
    }

    /// Keeps the original beside the document. An earlier copy is never
    /// replaced: a second bad load used to overwrite the first one kept.
    @discardableResult
    private func keepCopy(of data: Data) -> URL? {
        var target = backupLocation
        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            target = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(stamp).json")
        }
        return (try? data.write(to: target)) != nil ? target : nil
    }

    // MARK: - Saving

    /// Writes immediately and reports what went wrong. Used on quit, before an
    /// export, and by the tests.
    func saveNow(_ data: AppData) throws {
        // Queue the write behind any pending background save. Writing directly
        // here let an older queued snapshot finish later and overwrite the
        // newer state saved during quit or export.
        try queue.sync { try writeNow(data) }
    }

    private func writeNow(_ data: AppData) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded: Data
        do { encoded = try Self.makeEncoder().encode(data) }
        catch { throw SaveError.encoding(error) }
        do { try encoded.write(to: fileURL, options: .atomic) }
        catch { throw SaveError.writing(error) }
    }

    /// Encodes and writes off the main thread. `onFailure` is called on the main
    /// queue, because a save that quietly does nothing is how a whole session's
    /// work disappears.
    func save(_ data: AppData, onFailure: (@Sendable (SaveError) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.writeNow(data)
            } catch let error as SaveError {
                NSLog("Four Notes: save failed (\(error))")
                if let onFailure { DispatchQueue.main.async { onFailure(error) } }
            } catch {
                NSLog("Four Notes: save failed (\(error))")
            }
        }
    }

    /// Blocks until every queued write has finished. Called on the way out.
    func waitForPendingWrites() {
        queue.sync { }
    }

    // MARK: - Coding

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    func decode(_ data: Data) throws -> AppData { try JSONDecoder().decode(AppData.self, from: data) }

    func encode(_ data: AppData) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(data)
    }
}
