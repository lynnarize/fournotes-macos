import Testing
@testable import FourNotes

// Reading a version out of a GitHub tag or title, and comparing it with the
// running build's, for Settings → About → Check for updates.

@Suite("AppVersion")
struct AppVersionTests {

    @Test("numbers from tags and titles", arguments: [
        ("v0.1.2", [0, 1, 2]), ("0.1.2", [0, 1, 2]), ("v0.1.1-beta", [0, 1, 1]),
        ("Four Notes 1.2", [1, 2]), ("macos-app", []), ("", []),
    ])
    func numbers(text: String, expected: [Int]) {
        #expect(AppVersion.numbers(in: text) == expected)
    }

    @Test("newer, older and equal")
    func compare() {
        #expect(AppVersion.isNewer([0, 1, 2], than: [0, 1, 1]))
        #expect(AppVersion.isNewer([0, 2], than: [0, 1, 9]))
        #expect(AppVersion.isNewer([1, 0, 0], than: [0, 99, 99]))
        #expect(!AppVersion.isNewer([0, 1, 1], than: [0, 1, 1]))
        #expect(!AppVersion.isNewer([0, 2], than: [0, 2, 0]))
        #expect(!AppVersion.isNewer([0, 1, 0], than: [0, 1, 1]))
    }
}
