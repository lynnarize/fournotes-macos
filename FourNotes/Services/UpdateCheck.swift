import Foundation

// Which build this is, and whether GitHub has a newer one.
//
// The version is MARKETING_VERSION in project.yml; the build number and commit
// are stamped into Info.plist at build time (the "Stamp build number" script in
// project.yml), so every build says exactly which commit it came from. Releases
// are tagged v<version> by scripts/release.sh. The check runs only when asked,
// and sends nothing but the request itself — see the Privacy Policy.

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

    private static let latest = URL(string: "https://api.github.com/repos/lynnarize/fournotes-macos/releases/latest")!

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                state = try await Self.compare()
            } catch let error as URLError where error.code == .notConnectedToInternet {
                state = .failed("You're offline.")
            } catch {
                state = .failed("Couldn't reach GitHub.")
            }
        }
    }

    private struct Release: Decodable {
        var tag_name: String
        var name: String?
        var html_url: String
    }

    private static func compare() async throws -> State {
        var request = URLRequest(url: latest, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .failed("GitHub didn't answer. Try again later.")
        }
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
