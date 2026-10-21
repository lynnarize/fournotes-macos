import CryptoKit
import Foundation

// Speech models this Mac can download and run on its own: Whisper to transcribe
// recordings, and a speaker model to tell who said what. They come straight from
// Hugging Face, inside the app — no browser, no LM Studio — and then work offline.
//
// A download shows its size, speed and time left, can be paused and resumed (also
// after quitting: each file continues where it stopped, with an HTTP range
// request), cancelled, and deleted once installed. Every large file is checked
// against the SHA-256 Hugging Face publishes, and a model only moves into place
// when all of it has arrived intact.

@MainActor
final class SpeechModels: ObservableObject {
    static let shared = SpeechModels()

    // MARK: - What can be downloaded

    struct Pack: Identifiable, Sendable {
        enum Kind: Sendable { case whisper, speakers }
        let id: String
        let kind: Kind
        let name: String
        let detail: String
        let icon: String
        /// For the label before the exact size is known.
        let approxBytes: Int64
        let sources: [Source]
    }

    /// A folder of a Hugging Face repository, copied into the pack's folder.
    struct Source: Sendable {
        let repo: String
        /// The folder in the repo ("" for all of it).
        let path: String
        /// Only these file names, when set (Whisper's tokenizer lives in another repo).
        var only: Set<String>?
    }

    nonisolated static let whisper = Pack(
        id: "whisper-large-v3-turbo",
        kind: .whisper,
        name: "Whisper large-v3 turbo",
        detail: "Transcribes recordings in 99 languages, Indonesian and English included.",
        icon: "mic",
        approxBytes: 630_000_000,
        sources: [
            Source(repo: "argmaxinc/whisperkit-coreml", path: "openai_whisper-large-v3-v20240930_626MB"),
            // Without its tokenizer next to it, WhisperKit would fetch one on first use.
            Source(repo: "openai/whisper-large-v3", path: "",
                   only: ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json"]),
        ])

    nonisolated static let speakers = Pack(
        id: "speakerkit-pyannote",
        kind: .speakers,
        name: "Speaker separation",
        detail: "Tells who said what in a recording (pyannote, by SpeakerKit).",
        icon: "users",
        approxBytes: 33_000_000,
        sources: [Source(repo: "argmaxinc/speakerkit-coreml", path: "")])

    nonisolated static let packs = [whisper, speakers]

    // MARK: - State

    enum Phase: Equatable {
        case notInstalled
        case listing
        case downloading
        case paused
        case verifying
        /// Loading it once, so Core ML can compile it for this Mac (first time only, a minute or two).
        case preparing
        case installed
        case failed(String)
    }

    struct Status: Equatable {
        var phase: Phase = .notInstalled
        var received: Int64 = 0
        /// The exact size, once the file list has been fetched.
        var total: Int64?
        /// Bytes a second, smoothed.
        var rate: Double?

        var fraction: Double {
            guard let total, total > 0 else { return 0 }
            return min(1, Double(received) / Double(total))
        }
        var isBusy: Bool { [.listing, .downloading, .verifying, .preparing].contains(phase) }
    }

    @Published private(set) var status: [String: Status] = [:]
    /// Transcribe recordings with Whisper once it's installed (Apple's recognizer otherwise).
    @Published var useForRecordings: Bool {
        didSet { UserDefaults.standard.set(useForRecordings, forKey: Self.useKey) }
    }

    func status(_ pack: Pack) -> Status { status[pack.id] ?? Status() }
    func isInstalled(_ pack: Pack) -> Bool { status(pack).phase == .installed }
    func folder(_ pack: Pack) -> URL { Self.root.appendingPathComponent(pack.id, isDirectory: true) }

    private static let useKey = "fournotes.speech.useWhisper"
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Why the current task is being stopped: true for a pause (keeps what arrived), false for a cancel.
    private var stopping: [String: Bool] = [:]
    private var meters: [String: Meter] = [:]

    private init() {
        useForRecordings = UserDefaults.standard.object(forKey: Self.useKey) as? Bool ?? true
        for pack in Self.packs { status[pack.id] = Self.statusOnDisk(pack) }
    }

    // MARK: - Where they live

    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FourNotes/SpeechModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func partial(_ pack: Pack) -> URL { root.appendingPathComponent(pack.id + ".partial", isDirectory: true) }
    private static func manifest(in folder: URL) -> URL { folder.appendingPathComponent(".fournotes-manifest.json") }
    private static func plan(in folder: URL) -> URL { folder.appendingPathComponent(".fournotes-plan.json") }

    /// What's on disk from an earlier launch: installed, or a download paused part-way.
    private static func statusOnDisk(_ pack: Pack) -> Status {
        let fm = FileManager.default
        let installed = root.appendingPathComponent(pack.id, isDirectory: true)
        if fm.fileExists(atPath: manifest(in: installed).path) {
            let total = (try? Data(contentsOf: manifest(in: installed))).flatMap { try? JSONDecoder().decode([RemoteFile].self, from: $0) }
                .map { $0.reduce(0) { $0 + $1.size } }
            return Status(phase: .installed, received: total ?? 0, total: total)
        }
        let part = partial(pack)
        if let data = try? Data(contentsOf: plan(in: part)), let files = try? JSONDecoder().decode([RemoteFile].self, from: data) {
            let received = files.reduce(Int64(0)) { sum, f in sum + min(f.size, fileSize(part.appendingPathComponent(f.local))) }
            return Status(phase: .paused, received: received, total: files.reduce(0) { $0 + $1.size })
        }
        return Status()
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Downloading

    /// Starts the download, or carries on after a pause (or after quitting mid-way).
    func download(_ pack: Pack) {
        guard tasks[pack.id] == nil else { return }
        stopping[pack.id] = nil
        var s = status(pack)
        s.phase = s.total == nil ? .listing : .downloading
        s.rate = nil
        status[pack.id] = s
        tasks[pack.id] = Task { [weak self] in
            await self?.run(pack)
            self?.tasks[pack.id] = nil
        }
    }

    /// Stops, keeping what has arrived: Resume continues from there.
    func pause(_ pack: Pack) {
        guard let task = tasks[pack.id] else { return }
        stopping[pack.id] = true
        task.cancel()
    }

    /// Stops and throws away what has arrived.
    func cancel(_ pack: Pack) {
        if let task = tasks[pack.id] {
            stopping[pack.id] = false
            task.cancel()
        } else {
            try? FileManager.default.removeItem(at: Self.partial(pack))
            status[pack.id] = Status()
        }
    }

    /// Removes an installed model from this Mac.
    func delete(_ pack: Pack) {
        guard tasks[pack.id] == nil else { return }
        try? FileManager.default.removeItem(at: folder(pack))
        status[pack.id] = Status()
    }

    private func run(_ pack: Pack) async {
        let part = Self.partial(pack)
        do {
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
            let files = try await plan(pack, in: part)
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            try Self.checkSpace(needed: total - status(pack).received)

            var done = files.reduce(Int64(0)) { sum, f in sum + min(f.size, Self.fileSize(part.appendingPathComponent(f.local))) }
            update(pack) { $0.phase = .downloading; $0.total = total; $0.received = done }
            meters[pack.id] = Meter(start: done)

            for file in files {
                let target = part.appendingPathComponent(file.local)
                if Self.fileSize(target) == file.size { continue }
                let before = Self.fileSize(target)
                let others = done - before
                try await Fetch.file(file.url, to: target, expected: file.size) { [weak self] got in
                    Task { @MainActor in self?.progress(pack, received: others + got) }
                }
                done += file.size - before
                update(pack) { $0.received = done }
            }

            update(pack) { $0.phase = .verifying; $0.rate = nil }
            for file in files {
                try Task.checkCancellation()
                let target = part.appendingPathComponent(file.local)
                guard Self.fileSize(target) == file.size else { throw Failure.corrupt(file.local) }
                if let sha = file.sha256, try await Self.sha256(of: target) != sha {
                    try? FileManager.default.removeItem(at: target)
                    throw Failure.corrupt(file.local)
                }
            }

            // All here and intact: into place in one move.
            let final = folder(pack)
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.removeItem(at: Self.plan(in: part))
            try FileManager.default.moveItem(at: part, to: final)
            try JSONEncoder().encode(files).write(to: Self.manifest(in: final))

            update(pack) { $0.phase = .preparing }
            await LocalSpeech.prepare(pack, in: final)
            update(pack) { $0 = Status(phase: .installed, received: total, total: total) }
        } catch {
            let reason = stopping[pack.id]
            stopping[pack.id] = nil
            meters[pack.id] = nil
            let stopped = error is CancellationError || (error as? URLError)?.code == .cancelled
            if reason == false {
                try? FileManager.default.removeItem(at: part)
                status[pack.id] = Status()
            } else if reason == true || stopped {
                update(pack) { $0.phase = .paused; $0.rate = nil }
            } else {
                update(pack) { $0.phase = .failed(Self.message(for: error)); $0.rate = nil }
            }
        }
    }

    private func progress(_ pack: Pack, received: Int64) {
        guard status(pack).phase == .downloading else { return }
        let rate = meters[pack.id]?.rate(at: received)
        update(pack) { s in
            s.received = received
            if let rate { s.rate = rate }
        }
    }

    private func update(_ pack: Pack, _ change: (inout Status) -> Void) {
        var s = status(pack)
        change(&s)
        status[pack.id] = s
    }

    /// The files to fetch, from Hugging Face's file list (saved, so a resume after quitting knows them).
    private func plan(_ pack: Pack, in part: URL) async throws -> [RemoteFile] {
        if let data = try? Data(contentsOf: Self.plan(in: part)), let saved = try? JSONDecoder().decode([RemoteFile].self, from: data) {
            return saved
        }
        var files: [RemoteFile] = []
        for source in pack.sources {
            files += try await HuggingFace.files(in: source)
        }
        guard !files.isEmpty else { throw Failure.empty }
        try JSONEncoder().encode(files).write(to: Self.plan(in: part))
        return files
    }

    private static func checkSpace(needed: Int64) throws {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        // Room to spare: Core ML writes a compiled copy the first time a model loads.
        if free < needed + 1_000_000_000 { throw Failure.space(needed: needed, free: free) }
    }

    nonisolated private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    enum Failure: LocalizedError {
        case empty, corrupt(String), space(needed: Int64, free: Int64), http(Int)
        var errorDescription: String? {
            switch self {
            case .empty: return "Hugging Face listed no files for this model."
            case .corrupt: return "A file arrived damaged. Try again: it downloads that file once more."
            case .space(let needed, let free):
                return "Not enough free space: it needs \(SpeechModels.size(needed + 1_000_000_000)), this Mac has \(SpeechModels.size(free))."
            case .http(let code): return "Hugging Face answered \(code). Try again in a moment."
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You're offline. Resume when you're back online."
            case .timedOut: return "The connection timed out. Resume to carry on."
            default: return "The download stopped (\(url.localizedDescription)). Resume to carry on."
            }
        }
        return error.localizedDescription
    }

    // MARK: - Words

    /// 6.3e8 -> "630 MB", 1.6e9 -> "1.6 GB".
    nonisolated static func size(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1e9 { return String(format: "%.1f GB", b / 1e9) }
        if b >= 1e6 { return "\(Int((b / 1e6).rounded())) MB" }
        return "\(max(0, Int((b / 1e3).rounded()))) KB"
    }

    /// For the folded group in Settings: "Whisper installed", "Downloading 42%".
    var summary: String {
        let w = status(Self.whisper)
        switch w.phase {
        case .installed: return isInstalled(Self.speakers) ? "Whisper and speakers" : "Whisper installed"
        case .downloading, .listing, .verifying: return "Downloading \(Int(w.fraction * 100))%"
        case .preparing: return "Getting ready"
        case .paused: return "Paused"
        case .failed: return "Needs attention"
        case .notInstalled: return "Apple speech"
        }
    }
}

// MARK: - Files on Hugging Face

/// One file to fetch: where from, where to (inside the pack's folder), and how big.
struct RemoteFile: Codable, Sendable {
    let url: URL
    let local: String
    let size: Int64
    /// For large (LFS) files, the SHA-256 Hugging Face publishes.
    let sha256: String?
}

enum HuggingFace {
    private struct Entry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        let lfs: LFS?
        struct LFS: Decodable { let oid: String; let size: Int64 }
    }

    static func files(in source: SpeechModels.Source) async throws -> [RemoteFile] {
        let folder = source.path.isEmpty ? "" : "/" + source.path
        guard let list = URL(string: "https://huggingface.co/api/models/\(source.repo)/tree/main\(folder)?recursive=true") else { return [] }
        let (data, response) = try await URLSession.shared.data(from: list)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw SpeechModels.Failure.http(http.statusCode) }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries.compactMap { e -> RemoteFile? in
            guard e.type == "file" else { return nil }
            let name = (e.path as NSString).lastPathComponent
            if let only = source.only, !only.contains(name) { return nil }
            // The repo's own housekeeping isn't part of the model.
            if [".gitattributes", "README.md"].contains(name) || name.hasPrefix(".") { return nil }
            let local = source.path.isEmpty ? e.path : String(e.path.dropFirst(source.path.count + 1))
            let encoded = e.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
            guard let url = URL(string: "https://huggingface.co/\(source.repo)/resolve/main/\(encoded)") else { return nil }
            return RemoteFile(url: url, local: local, size: e.lfs?.size ?? e.size ?? 0, sha256: e.lfs?.oid)
        }
    }
}

// MARK: - Speed

/// Bytes a second over the last moments, smoothed so one fast or slow second doesn't swing the time left.
struct Meter: Sendable {
    private var last: (at: Date, bytes: Int64)
    private var smoothed: Double?
    init(start: Int64) { last = (Date(), start) }

    mutating func rate(at bytes: Int64) -> Double? {
        let now = Date()
        let dt = now.timeIntervalSince(last.at)
        guard dt >= 0.5 else { return nil }
        let instant = Double(bytes - last.bytes) / dt
        last = (now, bytes)
        guard instant >= 0 else { return smoothed }
        smoothed = smoothed.map { $0 * 0.75 + instant * 0.25 } ?? instant
        return smoothed
    }
}

// MARK: - One file, resumable

/// Streams a file to disk, continuing a partial one with an HTTP range request.
/// Cancelling the surrounding task stops it, leaving what arrived for next time.
final class Fetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let target: URL
    private let expected: Int64
    private let onProgress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64
    private var continuation: CheckedContinuation<Void, Error>?
    private var lastReport = Date.distantPast
    private let lock = NSLock()

    private init(target: URL, expected: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.target = target
        self.expected = expected
        self.onProgress = onProgress
        self.written = Self.size(of: target)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func file(_ url: URL, to target: URL, expected: Int64, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) { FileManager.default.createFile(atPath: target.path, contents: nil) }
        // More than expected: the file changed upstream. Start it over.
        if size(of: target) > expected { try Data().write(to: target) }

        let fetch = Fetch(target: target, expected: expected, onProgress: onProgress)
        var request = URLRequest(url: url, timeoutInterval: 60)
        if fetch.written > 0 { request.setValue("bytes=\(fetch.written)-", forHTTPHeaderField: "Range") }
        let session = URLSession(configuration: .default, delegate: fetch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                fetch.lock.withLock { fetch.continuation = c }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        try? handle?.close()
        handle = nil
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { return completionHandler(.allow) }
        switch http.statusCode {
        case 206:
            break
        case 200:
            // The range was ignored: the whole file is coming, so start it over.
            written = 0
            try? Data().write(to: target)
        case 416:
            // Nothing left to send: it's complete already.
            completionHandler(.cancel)
            finish(.success(()))
            return
        default:
            completionHandler(.cancel)
            finish(.failure(SpeechModels.Failure.http(http.statusCode)))
            return
        }
        do {
            handle = try FileHandle(forWritingTo: target)
            try handle?.seekToEnd()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            // A few reports a second is enough for a progress bar.
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                onProgress(written)
            }
        } catch {
            dataTask.cancel()
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onProgress(written)
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        } else if written < expected {
            finish(.failure(URLError(.networkConnectionLost)))
        } else {
            finish(.success(()))
        }
    }
}
