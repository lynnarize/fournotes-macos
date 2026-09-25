import Foundation

// Sync with Google Drive. Ported from the web app's src/lib/gdrive.ts, and it
// has to stay in step with it: both apps read and write the same file.
//
// Data is one JSON file in Drive's hidden app-data folder: private to this app,
// invisible in the user's Drive. Each sync:
//   1. checks whether the file changed since this Mac last saw it,
//   2. if so, downloads it and merges (newer updatedAt wins, deletions are tombstones),
//   3. uploads the merged result when it differs from what's in Drive.

struct DriveFile: Codable, Equatable, Sendable {
    var id: String
    var modifiedTime: String
}

/// What this Mac remembers about the Drive file.
struct SyncCursor: Codable, Equatable, Sendable {
    var fileId: String?
    var lastModified: String?
    var lastSig: String?
}

enum DriveError: LocalizedError, Equatable {
    case unauthorized
    case notFound
    case refused(String)
    case http(Int)
    case offline
    /// The file holds rows this version can't read. Uploading would leave them
    /// out, so nothing is uploaded until the app is updated.
    case unreadableRows(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Google sign-in expired. Connect again."
        case .notFound: return "The sync file in Google Drive has gone."
        case .refused(let message): return message
        case .http(let status): return "Google Drive error (\(status))."
        case .offline: return "Couldn't reach Google Drive. Sync will try again."
        case .unreadableRows(let n):
            return "\(n) item\(n == 1 ? "" : "s") synced from another device need a newer Four Notes. "
                + "Update the app to finish syncing."
        }
    }
}

/// The four calls sync makes. The real one is `GoogleDrive`; the tests use a
/// fake held in memory. Main-actor bound like the rest of sync: the network
/// calls suspend, so nothing waits on the main thread.
@MainActor
protocol DriveStore {
    /// Every copy of the sync file, newest first.
    func list() async throws -> [DriveFile]
    func download(_ id: String) async throws -> Data
    /// Replaces `id`, or creates the file when `id` is nil.
    func upload(_ id: String?, _ body: Data) async throws -> DriveFile
    func delete(_ id: String) async throws
}

enum DriveSync {
    static let fileName = "four-notes-sync.json"

    // MARK: - Payload

    /// What goes to Drive. Sample rows are local scaffolding and scans stay on
    /// the device to keep the file small, as on the web. Only the settings the
    /// web app syncs are sent: categories and the Mac's theme stay here.
    static func payload(_ d: AppData) -> AppData {
        var out = AppData()
        out.notes = d.notes.filter { $0.sample != true }.map {
            var note = $0
            note.imageDataUrl = nil
            note.imageFile = nil
            return note
        }
        out.todos = d.todos.filter { $0.sample != true }
        out.transactions = d.transactions.filter { $0.sample != true }.map {
            var transaction = $0
            transaction.imageDataUrl = nil
            transaction.imageFile = nil
            return transaction
        }
        out.stickies = d.stickies.filter { $0.sample != true }
        out.settings.currency = d.settings.currency
        out.settings.budgets = d.settings.budgets
        out.settings.name = d.settings.name
        out.settings.voiceReplies = d.settings.voiceReplies
        out.settings.updatedAt = d.settings.updatedAt
        return out
    }

    /// The file's JSON, in the web app's SyncPayload shape.
    static func encode(_ payload: AppData, savedAt: String = DateKit.nowIso()) throws -> Data {
        let encoder = JSONEncoder()
        func object<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: encoder.encode(value))
        }
        // A note edited here drops the web editor's HTML (see NoteEditorView),
        // and the web app keeps any field a synced row leaves out. So the
        // absence has to be spelled out as null, or the web app goes on showing
        // the HTML — and a Mac later, the rich text — from before the edit.
        var notes = try object(payload.notes) as? [[String: Any]] ?? []
        for i in notes.indices {
            for key in ["html", "richText"] where notes[i][key] == nil { notes[i][key] = NSNull() }
        }
        let document: [String: Any] = [
            "app": "four-notes",
            "version": 1,
            "savedAt": savedAt,
            "notes": notes,
            "todos": try object(payload.todos),
            "transactions": try object(payload.transactions),
            "stickies": try object(payload.stickies),
            "settings": try object(payload.settings),
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.withoutEscapingSlashes])
    }

    /// Reads the file. Rows that can't be read are counted in `skippedRows`,
    /// the same way a document on disk is read.
    static func decode(_ data: Data) throws -> AppData {
        var remote = try JSONDecoder().decode(AppData.self, from: data)
        // Rich text is the Mac's own form. The web app doesn't touch it, so a
        // note edited there arrives newer, with the rich text from before —
        // which the Mac editor would open in preference to the new text.
        for i in remote.notes.indices {
            guard let archive = remote.notes[i].richText else { continue }
            let text = NoteDocument.unarchive(archive).map(NoteDocument.plainText(from:))
            if text != remote.notes[i].content { remote.notes[i].richText = nil }
        }
        return remote
    }

    // MARK: - Merge

    private static func mergeRows<T: BaseItem>(_ local: [T], _ remote: [T]) -> [T] {
        var order = local.map(\.id)
        var byId = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in remote {
            if let mine = byId[row.id] {
                if row.updatedAt > mine.updatedAt { byId[row.id] = row }
            } else {
                byId[row.id] = row
                order.append(row.id)
            }
        }
        var seen = Set<String>()
        return order.compactMap { seen.insert($0).inserted ? byId[$0] : nil }
    }

    static func merge(_ local: AppData, _ remote: AppData) -> AppData {
        var out = local
        out.notes = mergeRows(local.notes, remote.notes)
        out.todos = mergeRows(local.todos, remote.todos)
        out.transactions = mergeRows(local.transactions, remote.transactions)
        out.stickies = mergeRows(local.stickies, remote.stickies)
        if (remote.settings.updatedAt ?? "") > (local.settings.updatedAt ?? "") { out.settings = remote.settings }
        return out
    }

    /// Short fingerprint of item versions, to skip uploads when nothing
    /// changed. Same text and FNV-1a hash as the web app.
    static func signature(_ d: AppData) -> String {
        func versions<T: BaseItem>(_ rows: [T]) -> String {
            rows.map { "\($0.id)@\($0.updatedAt)" }.sorted().joined(separator: ",")
        }
        let text = [versions(d.notes), versions(d.todos), versions(d.transactions), versions(d.stickies),
                     d.settings.updatedAt ?? ""].joined(separator: "|")
        var hash: UInt32 = 0x811c_9dc5
        for unit in text.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return "\(text.utf16.count)-\(String(hash, radix: 16))"
    }

    // MARK: - Run

    /// One sync. `apply` merges what Drive had into the app; the returned
    /// cursor is what to remember for next time.
    @MainActor
    static func run(drive: some DriveStore, local: AppData, cursor: SyncCursor,
                    apply: (AppData) -> Void) async throws -> SyncCursor {
        let files = try await drive.list()
        let file = files.first
        let extras = files.dropFirst()
        var merged = payload(local)
        var remoteSig = file == nil ? nil : cursor.lastSig
        var unreadable = 0

        if let file, file.modifiedTime != cursor.lastModified {
            let remote = try decode(await drive.download(file.id))
            apply(remote)
            merged = merge(merged, remote)
            remoteSig = signature(remote)
            unreadable += remote.skippedRows
        }
        // Duplicates: two devices connecting at the same moment can each create
        // the file. Fold their contents in too, so nothing written to them is
        // lost. Another device may be removing them at the same time: a
        // vanished one is fine.
        for extra in extras {
            let remote: AppData
            do { remote = try decode(await drive.download(extra.id)) } catch DriveError.notFound { continue }
            apply(remote)
            merged = merge(merged, remote)
            unreadable += remote.skippedRows
        }
        if unreadable > 0 { throw DriveError.unreadableRows(unreadable) }

        let mergedSig = signature(merged)
        let result: SyncCursor
        if let file, mergedSig == remoteSig {
            result = SyncCursor(fileId: file.id, lastModified: file.modifiedTime, lastSig: mergedSig)
        } else {
            let saved = try await drive.upload(file?.id, encode(merged))
            result = SyncCursor(fileId: saved.id, lastModified: saved.modifiedTime, lastSig: mergedSig)
        }
        // Only after the merged copy is safely saved: remove the duplicates.
        for extra in extras {
            do { try await drive.delete(extra.id) } catch DriveError.notFound {}
        }
        return result
    }
}

// MARK: - Drive REST

/// Drive's v3 REST API, as used by the web app.
struct GoogleDrive: DriveStore {
    /// A current access token; `true` asks for a fresh one.
    let token: @MainActor (Bool) async throws -> String

    private static let files = "https://www.googleapis.com/drive/v3/files"
    private static let upload = "https://www.googleapis.com/upload/drive/v3/files"

    func list() async throws -> [DriveFile] {
        var components = URLComponents(string: Self.files)!
        components.queryItems = [
            .init(name: "spaces", value: "appDataFolder"),
            .init(name: "q", value: "name='\(DriveSync.fileName)' and trashed=false"),
            .init(name: "fields", value: "files(id,modifiedTime)"),
            .init(name: "orderBy", value: "modifiedTime desc"),
            .init(name: "pageSize", value: "20"),
        ]
        struct Listing: Decodable { var files: [DriveFile]? }
        let data = try await send(URLRequest(url: components.url!))
        return (try JSONDecoder().decode(Listing.self, from: data)).files ?? []
    }

    func download(_ id: String) async throws -> Data {
        try await send(URLRequest(url: URL(string: "\(Self.files)/\(id)?alt=media")!))
    }

    func upload(_ id: String?, _ body: Data) async throws -> DriveFile {
        var request: URLRequest
        if let id {
            request = URLRequest(url: URL(string: "\(Self.upload)/\(id)?uploadType=media&fields=id,modifiedTime")!)
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        } else {
            let boundary = "fournotes-\(UUID().uuidString)"
            let metadata = #"{"name":"\#(DriveSync.fileName)","parents":["appDataFolder"],"mimeType":"application/json"}"#
            var multipart = Data()
            let part = "Content-Type: application/json; charset=UTF-8\r\n\r\n"
            multipart.append(Data("--\(boundary)\r\n\(part)\(metadata)\r\n--\(boundary)\r\n\(part)".utf8))
            multipart.append(body)
            multipart.append(Data("\r\n--\(boundary)--".utf8))
            request = URLRequest(url: URL(string: "\(Self.upload)?uploadType=multipart&fields=id,modifiedTime")!)
            request.httpMethod = "POST"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = multipart
        }
        return try JSONDecoder().decode(DriveFile.self, from: await send(request))
    }

    func delete(_ id: String) async throws {
        var request = URLRequest(url: URL(string: "\(Self.files)/\(id)")!)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    /// Sends with the current token, and once more with a fresh one if Drive
    /// says it expired.
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await send(request, token: token(false))
        } catch DriveError.unauthorized {
            return try await send(request, token: token(true))
        }
    }

    private func send(_ request: URLRequest, token: String) async throws -> Data {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DriveError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw DriveError.unauthorized
        case 403, 429: throw DriveError.refused(Self.message(status: status, body: data))
        case 404: throw DriveError.notFound
        default: throw DriveError.http(status)
        }
    }

    /// Drive uses 403 for very different problems; only one of them is fixed by reconnecting.
    static func message(status: Int, body: Data) -> String {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
        let reason = ((error?["errors"] as? [[String: Any]])?.first?["reason"] as? String)
            ?? (error?["status"] as? String) ?? ""
        switch reason {
        case "accessNotConfigured", "SERVICE_DISABLED":
            return "Google Drive isn't switched on for this app yet (the Google Drive API is disabled in its Google Cloud project). Try again later."
        case "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT":
            return "Google Drive access wasn't allowed. Disconnect, then connect again and tick the Google Drive permission."
        case "rateLimitExceeded", "userRateLimitExceeded", "RESOURCE_EXHAUSTED":
            return "Google Drive is busy right now. Sync will try again in a minute."
        case "storageQuotaExceeded":
            return "Your Google Drive is full, so sync can't save. Free up some space and try again."
        default:
            return status == 429
                ? "Google Drive is busy right now. Sync will try again in a minute."
                : "Google Drive refused the request (\(reason.isEmpty ? "\(status)" : reason))."
        }
    }
}
