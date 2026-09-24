import AppKit
import Foundation

// Local model servers — LM Studio and Ollama — found on this Mac, whether
// they are running, and starting or stopping them, so nobody has to type an
// address or open a terminal. A running server holds a model in memory, so
// the sidebar says so while one is on.

@MainActor
final class LocalServers: ObservableObject {
    static let shared = LocalServers()

    enum Kind: String, CaseIterable, Identifiable {
        case lmStudio, ollama
        var id: String { rawValue }

        var name: String { self == .lmStudio ? "LM Studio" : "Ollama" }
        /// The matching preset in AIProvider.
        var providerId: String { self == .lmStudio ? "lmstudio" : "ollama" }
        var port: Int { self == .lmStudio ? 1234 : 11434 }
        var bundleId: String { self == .lmStudio ? "ai.elementlabs.lmstudio" : "com.electron.ollama" }

        /// The command-line tool, where the installer puts it.
        var cliPaths: [String] {
            switch self {
            case .lmStudio: return [LocalServers.home + "/.lmstudio/bin/lms"]
            case .ollama: return ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            }
        }
    }

    struct Status: Equatable {
        var installed = false
        var running = false
        var models: [String] = []
    }

    @Published private(set) var status: [Kind: Status] = [:]
    /// Starting or stopping, so the buttons wait.
    @Published private(set) var working: Set<Kind> = []
    @Published private(set) var lastError: String?

    /// `ollama serve` started by this app, stopped with it.
    private var ollamaProcess: Process?
    private var polling: Task<Void, Never>?

    /// The real home folder: in the sandbox, NSHomeDirectory() is the container.
    nonisolated static var home: String {
        getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    }

    /// The tools look for their settings under $HOME, which the sandbox
    /// points at the app's container ("no such file … Containers/…/.lmstudio").
    nonisolated static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home
        return env
    }

    var running: [Kind] { Kind.allCases.filter { status[$0]?.running == true } }

    private init() {}

    /// Checks now, then every 20 seconds: a couple of requests to localhost.
    func startWatching() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// Stops the checks, when nothing is left on screen to show them.
    func stopWatching() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        var next: [Kind: Status] = [:]
        for kind in Kind.allCases {
            let models = await Self.models(at: kind.port)
            next[kind] = Status(installed: isInstalled(kind), running: models != nil, models: models ?? [])
        }
        if next != status { status = next }
    }

    func isInstalled(_ kind: Kind) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleId) != nil
            || cli(for: kind) != nil
    }

    private func cli(for kind: Kind) -> String? {
        kind.cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The models a server offers, or nil when nothing answers on its port.
    nonisolated static func models(at port: Int) async -> [String]? {
        guard let url = URL(string: "http://localhost:\(port)/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            // Embedding models can't chat.
            .filter { !$0.localizedCaseInsensitiveContains("embed") }
    }

    // MARK: - Start and stop

    func start(_ kind: Kind) async {
        guard !working.contains(kind) else { return }
        working.insert(kind)
        lastError = nil
        defer { working.remove(kind) }

        switch kind {
        case .lmStudio:
            if let lms = cli(for: kind), (try? await Self.run(lms, ["server", "start"])) == true {
                break
            }
            // No command-line tool, or the sandbox refused it: open the app,
            // whose server can be switched on there.
            await openApp(kind)
        case .ollama:
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleId) != nil {
                await openApp(kind)  // the Ollama app runs its own server
            } else if let ollama = cli(for: kind) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ollama)
                process.arguments = ["serve"]
                process.environment = Self.toolEnvironment
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run(); ollamaProcess = process } catch {
                    lastError = "Couldn't start Ollama: \(error.localizedDescription)"
                }
            }
        }
        await waitFor(kind, running: true)
        if status[kind]?.running != true, lastError == nil {
            lastError = kind == .lmStudio
                ? "LM Studio opened. Turn its server on in the Developer tab, or load a model."
                : "Ollama didn't start. Open it from Applications."
        }
    }

    func stop(_ kind: Kind) async {
        guard !working.contains(kind) else { return }
        working.insert(kind)
        lastError = nil
        defer { working.remove(kind) }

        switch kind {
        case .lmStudio:
            if let lms = cli(for: kind) { _ = try? await Self.run(lms, ["server", "stop"]) }
        case .ollama:
            ollamaProcess?.terminate()
            ollamaProcess = nil
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: kind.bundleId) {
                app.terminate()
            }
        }
        await waitFor(kind, running: false)
        if status[kind]?.running == true {
            lastError = "\(kind.name) is still running. Stop it from its own window."
        }
    }

    private func openApp(_ kind: Kind) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: kind.bundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Polls until the server is in the wanted state, for up to 15 seconds.
    private func waitFor(_ kind: Kind, running: Bool) async {
        for _ in 0..<30 {
            await refresh()
            if (status[kind]?.running == true) == running { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Runs a command-line tool; true when it exits cleanly within `timeout`.
    ///
    /// Its output goes nowhere. It used to go to a pipe that was read only
    /// after exit, and `lms server start` hands that pipe on to the server it
    /// launches, which never exits — so the read never finished, the call never
    /// returned, and Start and Stop stayed disabled until the app was relaunched.
    nonisolated static func run(_ path: String, _ arguments: [String], timeout: Double = 20) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = toolEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let running = process
        return try await withCheckedThrowingContinuation { continuation in
            let gate = OnceFlag()
            process.terminationHandler = { finished in
                guard gate.claim() else { return }
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                guard gate.claim() else { return }
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard gate.claim() else { return }
                if running.isRunning { running.terminate() }
                continuation.resume(returning: false)
            }
        }
    }

    /// Stops what this app started, on the way out: a server it launched
    /// would otherwise keep its model in memory after Four Notes has quit.
    func stopLaunched() {
        ollamaProcess?.terminate()
        ollamaProcess = nil
    }
}

/// True for the first caller only.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.withLock {
            guard !taken else { return false }
            taken = true
            return true
        }
    }
}
