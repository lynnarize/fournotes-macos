import Foundation
import Testing
@testable import FourNotes

// Starting and stopping LM Studio's server from inside the app's sandbox.
// It really starts a server, so it is off by default; on with:
//
//   TEST_RUNNER_FOURNOTES_EVAL_LOCALSERVER=1 ./run-tests.sh

private let enabled = ProcessInfo.processInfo.environment["FOURNOTES_EVAL_LOCALSERVER"] == "1"

@Suite("Local model servers", .serialized, .enabled(if: enabled))
@MainActor
struct LocalServersTests {
    @Test("LM Studio is found, started and stopped from the sandbox")
    func lmStudio() async throws {
        let servers = LocalServers.shared
        #expect(servers.isInstalled(.lmStudio))
        await servers.refresh()
        let wasRunning = servers.status[.lmStudio]?.running == true
        print("LOCALSERVER | installed, running before: \(wasRunning)")

        await servers.start(.lmStudio)
        print("LOCALSERVER | after start: \(servers.status[.lmStudio] ?? .init()) error: \(servers.lastError ?? "none")")
        #expect(servers.status[.lmStudio]?.running == true)
        #expect(servers.status[.lmStudio]?.models.isEmpty == false)

        if !wasRunning {
            await servers.stop(.lmStudio)
            print("LOCALSERVER | after stop: \(servers.status[.lmStudio] ?? .init()) error: \(servers.lastError ?? "none")")
            #expect(servers.status[.lmStudio]?.running == false)
        }
    }
}
