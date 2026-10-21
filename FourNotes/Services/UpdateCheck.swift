import AppKit
import Foundation

// Which build this is, and whether GitHub has a newer one.
//
// The version is MARKETING_VERSION in project.yml; the build number and commit
// are stamped into Info.plist at build time (the "Stamp build number" script in
// project.yml), so every build says exactly which commit it came from. Releases
// are tagged v<version> by scripts/release.sh. The check runs when asked and,
// unless turned off in Settings → About, once a day on its own. It sends
// nothing but the request itself — see the Privacy Policy.
//
// A release found is offered in a pop-up (UpdateSheet): its notes, and a button that
// downloads the disk image to Downloads and opens it. The app is sandboxed, so it
// can't replace itself in Applications; it quits when asked so the copy there can be
// replaced.

enum AppVersion {
    static let releasesPage = URL(string: "https://github.com/lynnarize/fournotes-macos/releases")!

    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    /// "0.1.1"
    static var marketing: String { info["CFBundleShortVersionString"] as? String ?? "0" }
    /// The commit count, or the project's CURRENT_PROJECT_VERSION outside git.
    static var build: String { info["CFBundleVersion"] as? String ?? "0" }
    /// Short hash, "-dirty" when built with uncommitted changes. Nil outside git.
    static var commit: String? {
        (info["FNGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.1.1 (42)" — what the section summary shows.
    static var short: String { "\(marketing) (\(build))" }

    /// The numbers in a version or tag: "v0.1.2-beta" → [0, 1, 2]. Anything
    /// after the first run of dotted numbers is ignored.
    static func numbers(in text: String) -> [Int] {
        guard let match = text.firstMatch(of: /\d+(\.\d+)*/) else { return [] }
        return match.output.0.split(separator: ".").compactMap { Int($0) }
    }

    /// Whether `candidate` is a later version than `current`; "0.2" == "0.2.0".
    static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        let count = max(candidate.count, current.count)
        let a = candidate + Array(repeating: 0, count: count - candidate.count)
        let b = current + Array(repeating: 0, count: count - current.count)
        return b.lexicographicallyPrecedes(a)
    }
}

@MainActor
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    /// A release later than this build.
    struct Available: Equatable {
        var version: String
        var page: URL
        /// What's new, tidied from the release's notes.
        var notes: String?
        /// The disk image attached to the release.
        var download: URL?
    }

    /// Fetching the disk image, then opening it.
    enum Download: Equatable {
        case idle
        case downloading(Double)
        /// Open in Finder: drag it to Applications.
        case opened(URL)
        case failed(String)
    }

    enum State: Equatable {
        case idle, checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The newest release found that is later than this build, remembered
    /// between launches so the badge shows without going online.
    @Published private(set) var available: Available?
    @Published private(set) var download: Download = .idle
    /// The version "Skip this version" was pressed on: no pop-up for it again.
    @Published private(set) var skippedVersion: String?
    /// The pop-up was shown this launch; "Later" means the next launch.
    private var promptedThisLaunch = false
    private var downloadTask: URLSessionDownloadTask?
    private var progressWatch: NSKeyValueObservation?
    /// The version whose badge was already seen, in Settings.
    @Published private(set) var seenVersion: String?

    /// Checks once a day on its own; off only if turned off in Settings.
    @Published var automatic: Bool {
        didSet {
            defaults.set(automatic, forKey: Keys.automatic)
            if automatic { startAutomatic() } else { loop?.cancel(); loop = nil }
        }
    }

    /// A day between automatic checks. Releases come every week or two, and
    /// GitHub allows 60 unauthenticated requests an hour per address, so this
    /// is timely without ever nearing the limit.
    static let interval: TimeInterval = 24 * 60 * 60
    /// How often a running app looks at whether a check is due.
    private static let tick: Duration = .seconds(60 * 60)
    /// Wait after launch, so the check never competes with opening the app.
    private static let launchDelay: Duration = .seconds(30)

    private static let latest = URL(string: "https://api.github.com/repos/lynnarize/fournotes-macos/releases/latest")!
    private let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?

    private enum Keys {
        static let automatic = "fournotes.updates.automatic"
        static let lastChecked = "fournotes.updates.lastChecked"
        static let etag = "fournotes.updates.etag"
        static let version = "fournotes.updates.availableVersion"
        static let page = "fournotes.updates.availablePage"
        static let seen = "fournotes.updates.seenVersion"
        static let notes = "fournotes.updates.availableNotes"
        static let download = "fournotes.updates.availableDownload"
        static let skipped = "fournotes.updates.skippedVersion"
    }

    private init() {
        automatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        seenVersion = defaults.string(forKey: Keys.seen)
        skippedVersion = defaults.string(forKey: Keys.skipped)
        if let version = defaults.string(forKey: Keys.version),
           let page = defaults.string(forKey: Keys.page).flatMap(URL.init(string:)),
           AppVersion.isNewer(AppVersion.numbers(in: version), than: AppVersion.numbers(in: AppVersion.marketing)) {
            available = Available(version: version, page: page,
                                  notes: defaults.string(forKey: Keys.notes),
                                  download: defaults.string(forKey: Keys.download).flatMap(URL.init(string:)))
        }
    }

    /// True while there's a release the user hasn't looked at in Settings.
    var hasUnseenUpdate: Bool {
        guard let available else { return false }
        return available.version != seenVersion
    }

    /// Settings showed the update; the badge can go.
    func markSeen() {
        guard let available, seenVersion != available.version else { return }
        seenVersion = available.version
        defaults.set(available.version, forKey: Keys.seen)
    }

    /// Whether to put the pop-up up now: a release this build doesn't have, not
    /// skipped, and not offered already since launch.
    var shouldPrompt: Bool {
        guard let available, !promptedThisLaunch else { return false }
        return available.version != skippedVersion
    }

    /// The pop-up went up; "Later" waits for the next launch.
    func didPrompt() { promptedThisLaunch = true }

    /// "Skip this version": no pop-up for it again. A later one still gets one.
    func skip() {
        guard let available else { return }
        skippedVersion = available.version
        defaults.set(available.version, forKey: Keys.skipped)
    }

    // MARK: - Downloading

    /// Downloads the release's disk image to Downloads and opens it, so the new app
    /// can be dragged over the old one. Without an image attached, opens the page.
    func downloadAndOpen() {
        guard let available else { return }
        guard let url = available.download else {
            NSWorkspace.shared.open(available.page)
            return
        }
        if case .downloading = download { return }
        download = .downloading(0)
        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            // The file at `location` is gone once this returns: move it now.
            let result: Result<URL, Error> = Result {
                if let error { throw error }
                guard let location, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                return try Self.keep(location, named: url.lastPathComponent)
            }
            Task { @MainActor in self?.finish(result) }
        }
        progressWatch = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading = self?.download { self?.download = .downloading(fraction) }
            }
        }
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        progressWatch = nil
        download = .idle
    }

    /// Into Downloads, where it can be found again; "FourNotes-0.3.0 2.dmg" if a
    /// copy is already there.
    nonisolated private static func keep(_ location: URL, named name: String) throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: location, to: target)
        return target
    }

    private func finish(_ result: Result<URL, Error>) {
        progressWatch = nil
        downloadTask = nil
        switch result {
        case .success(let file):
            download = .opened(file)
            NSWorkspace.shared.open(file)
        case .failure(let error as URLError) where error.code == .cancelled:
            download = .idle
        case .failure(let error as URLError) where error.code == .notConnectedToInternet:
            download = .failed("You're offline. Try again when you're back online.")
        case .failure:
            download = .failed("The download didn't finish. Try again, or get it from the release page.")
        }
    }

    /// Checks in the background: shortly after launch if a day has passed,
    /// then whenever another day has.
    func startAutomatic() {
        guard automatic, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.launchDelay)
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: Keys.lastChecked) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        run(quietly: true)
    }

    func check() { run(quietly: false) }

    /// A quiet check leaves the shown state alone when it fails: an automatic
    /// check that couldn't reach GitHub isn't worth an error.
    private func run(quietly: Bool) {
        guard state != .checking else { return }
        let before = state
        state = .checking
        Task {
            do {
                let result = try await compare()
                defaults.set(Date(), forKey: Keys.lastChecked)
                apply(result)
                state = result
            } catch let error as URLError where error.code == .notConnectedToInternet {
                state = quietly ? before : .failed("You're offline.")
            } catch {
                state = quietly ? before : .failed("Couldn't reach GitHub.")
            }
        }
    }

    private func apply(_ result: State) {
        switch result {
        case .available(let version, let page):
            let found = Available(version: version, page: page, notes: lastNotes, download: lastDownload)
            // A 304 brings no notes: keep what was read the first time.
            if available?.version != version || found.notes != nil { available = found }
            defaults.set(version, forKey: Keys.version)
            defaults.set(page.absoluteString, forKey: Keys.page)
            if let notes = available?.notes { defaults.set(notes, forKey: Keys.notes) }
            if let link = available?.download { defaults.set(link.absoluteString, forKey: Keys.download) }
        case .upToDate:
            available = nil
            for key in [Keys.version, Keys.page, Keys.notes, Keys.download] { defaults.removeObject(forKey: key) }
        default:
            break
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
        }
        var tag_name: String
        var name: String?
        var html_url: String
        var body: String?
        var assets: [Asset]?
    }

    /// Read from the latest release alongside its version.
    private var lastNotes: String?
    private var lastDownload: URL?

    private func compare() async throws -> State {
        var request = URLRequest(url: Self.latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // A conditional request: GitHub answers 304 when the latest release
        // is the one seen last time, and a 304 doesn't count against the
        // rate limit. That answer was saved as `available` (or its absence).
        if let etag = defaults.string(forKey: Keys.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .failed("GitHub didn't answer. Try again later.")
        }
        if http.statusCode == 304 {
            if let available {
                lastNotes = available.notes
                lastDownload = available.download
                return .available(version: available.version, page: available.page)
            }
            return .upToDate
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed("GitHub didn't answer. Try again later.")
        }
        if let tag = http.value(forHTTPHeaderField: "ETag") { defaults.set(tag, forKey: Keys.etag) }
        let release = try JSONDecoder().decode(Release.self, from: data)
        // The tag should be v<version>; older releases kept it in the title.
        let label = [release.tag_name, release.name ?? ""]
            .first { !AppVersion.numbers(in: $0).isEmpty } ?? release.tag_name
        let latest = AppVersion.numbers(in: label)
        guard !latest.isEmpty else { return .failed("The latest release has no version number.") }
        guard AppVersion.isNewer(latest, than: AppVersion.numbers(in: AppVersion.marketing)) else {
            return .upToDate
        }
        let page = URL(string: release.html_url) ?? AppVersion.releasesPage
        lastNotes = release.body.map(ReleaseNotes.tidy).flatMap { $0.isEmpty ? nil : $0 }
        lastDownload = release.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
        return .available(version: latest.map(String.init).joined(separator: "."), page: page)
    }
}

/// GitHub's generated release notes, cut down to what changed: no headings, no
/// "New Contributors", no changelog link, and "by @someone in <link>" dropped.
enum ReleaseNotes {
    static func tidy(_ body: String) -> String {
        var lines: [String] = []
        var skipping = false
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                // A section of its own: "New Contributors" is left out entirely.
                skipping = line.lowercased().contains("contributor")
                continue
            }
            if skipping || line.lowercased().hasPrefix("**full changelog**") { continue }
            var text = line
            if let range = text.range(of: #"\s+by @\S+(\s+in\s+\S+)?$"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            if text.hasPrefix("* ") || text.hasPrefix("- ") { text = "• " + text.dropFirst(2) }
            lines.append(text)
        }
        // No blank lines at either end, and never two in a row.
        var out: [String] = []
        for line in lines where !(line.isEmpty && (out.last?.isEmpty ?? true)) { out.append(line) }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
