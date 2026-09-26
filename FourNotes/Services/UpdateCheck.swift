import Foundation

// Which build this is, and whether GitHub has a newer one.
//
// The version is MARKETING_VERSION in project.yml; the build number and commit
// are stamped into Info.plist at build time (the "Stamp build number" script in
// project.yml), so every build says exactly which commit it came from. Releases
// are tagged v<version> by scripts/release.sh. The check runs when asked and,
// unless turned off in Settings → About, once a day on its own. It sends
// nothing but the request itself — see the Privacy Policy.

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

    enum State: Equatable {
        case idle, checking
        case upToDate
        case available(version: String, page: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The newest release found that is later than this build, remembered
    /// between launches so the badge shows without going online.
    @Published private(set) var available: (version: String, page: URL)?
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
    }

    private init() {
        automatic = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        seenVersion = defaults.string(forKey: Keys.seen)
        if let version = defaults.string(forKey: Keys.version),
           let page = defaults.string(forKey: Keys.page).flatMap(URL.init(string:)),
           AppVersion.isNewer(AppVersion.numbers(in: version), than: AppVersion.numbers(in: AppVersion.marketing)) {
            available = (version, page)
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
            available = (version, page)
            defaults.set(version, forKey: Keys.version)
            defaults.set(page.absoluteString, forKey: Keys.page)
        case .upToDate:
            available = nil
            defaults.removeObject(forKey: Keys.version)
            defaults.removeObject(forKey: Keys.page)
        default:
            break
        }
    }

    private struct Release: Decodable {
        var tag_name: String
        var name: String?
        var html_url: String
    }

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
            if let available { return .available(version: available.version, page: available.page) }
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
        return .available(version: latest.map(String.init).joined(separator: "."), page: page)
    }
}
