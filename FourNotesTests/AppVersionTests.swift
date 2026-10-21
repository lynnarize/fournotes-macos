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

// GitHub's generated notes, as the update pop-up shows them.

@Suite("Release notes")
struct ReleaseNotesTests {

    @Test("keeps what changed, drops the rest")
    func generated() {
        let body = """
        ## What's Changed\r
        * New mark and light/dark app icon, Edge Dock restyle by @lynnarize in https://github.com/lynnarize/fournotes-macos/pull/1\r
        * Main window redesign by @lynnarize in https://github.com/lynnarize/fournotes-macos/pull/2\r
        \r
        ## New Contributors\r
        * @lynnarize made their first contribution in https://github.com/lynnarize/fournotes-macos/pull/1\r
        \r
        **Full Changelog**: https://github.com/lynnarize/fournotes-macos/compare/v0.1.5...v0.2.0-beta
        """
        #expect(ReleaseNotes.tidy(body) == """
        • New mark and light/dark app icon, Edge Dock restyle
        • Main window redesign
        """)
    }

    @Test("written notes pass through")
    func written() {
        #expect(ReleaseNotes.tidy("Faster sync.\n\n\n- Fixed a crash") == "Faster sync.\n\n• Fixed a crash")
        #expect(ReleaseNotes.tidy("") == "")
    }
}
