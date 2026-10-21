import AppKit
import Combine
import SwiftUI

// Decides who answers each request. There are two kinds of model:
//
//   on this Mac — a local model server (LM Studio, Ollama) if one is set up,
//                 then Apple Intelligence
//   in the cloud — the user's own keys, one tab each in Settings: OpenRouter,
//                  OpenCode, Claude, Other (OpenAI, Groq, Gemini…). The one
//                  picked there first, then the rest (see CloudProviders)
//
// Local first (the default): requests stay on this Mac while any local model
// exists, and the cloud is used only when there is none — or when the user
// asks for it on one reply ("Ask OpenRouter"). Cloud first: the cloud answers,
// and this Mac steps in when it fails.
//
// Scanning and voice notes always read on-device first, so they work with no
// key and no network; a model is only asked to sort and tidy the result.

@MainActor
final class AIEngine: ObservableObject {
    enum Route: Equatable {
        case anthropic
        case provider(String)
        case appleIntelligence
        case onDevice
        case unavailable

        var label: String {
            switch self {
            case .anthropic: return "Your Anthropic key"
            case .provider(let name): return name
            case .appleIntelligence: return "Apple Intelligence"
            case .onDevice: return "This Mac"
            case .unavailable: return "Not set up"
            }
        }
    }

    /// Which kind of model is asked first.
    enum Priority: String, CaseIterable {
        case localFirst = "local"
        case cloudFirst = "cloud"

        var label: String { self == .localFirst ? "This Mac first" : "Cloud first" }
    }

    /// One model the app can ask.
    enum Answerer {
        case anthropic(AnthropicClient)
        case provider(OpenAICompatibleClient)
        case apple(AppleProvider)

        var isLocal: Bool {
            switch self {
            case .anthropic: return false
            case .provider(let client): return client.runsOnThisMac
            case .apple: return true
            }
        }

        var route: Route {
            switch self {
            case .anthropic: return .anthropic
            case .provider(let client): return .provider(client.provider.name)
            case .apple: return .appleIntelligence
            }
        }

        /// "OpenRouter · Ling 3.0 Flash Fin", for the Settings summary.
        var detail: String {
            switch self {
            case .anthropic(let client):
                return AnthropicClient.userModels.first { $0.id == client.model }
                    .map { "Claude · " + ($0.label.components(separatedBy: " · ").first ?? $0.label)
                        .replacingOccurrences(of: "Claude ", with: "") } ?? "Claude"
            case .provider(let client):
                let model = OpenRouterModels.free.first { $0.id == client.model }?.label
                    ?? (OpenCodeModels.free + OpenCodeModels.go).first { $0.id == client.model }?.label
                    ?? client.model.split(separator: "/").last.map(String.init)?
                        .replacingOccurrences(of: ":free", with: "") ?? client.model
                return "\(client.provider.shortName) · \(model)"
            case .apple:
                return "Apple Intelligence"
            }
        }

        /// For "Ask …" and the mark under a reply.
        var shortName: String {
            switch self {
            case .anthropic: return "Claude"
            case .provider(let client): return client.provider.shortName
            case .apple: return "Apple Intelligence"
            }
        }
    }

    @Published private(set) var route: Route = .unavailable
    /// Set by Settings so the route recomputes when a key is added or removed.
    @Published var revision = 0

    var priority: Priority {
        get { Priority(rawValue: UserDefaults.standard.string(forKey: "fournotes.aiPriority") ?? "") ?? .localFirst }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "fournotes.aiPriority")
            refresh()
        }
    }

    /// How long any single model call may take before the app stops waiting.
    /// Apple's on-device model is normally a second or two, but a wide request
    /// can run for minutes, and nothing in the UI may hang on one.
    private enum Deadline {
        static let chat: Double = 90
        static let capture: Double = 25
        static let summary: Double = 45
        /// A cloud or local-server model: slower than on-device, but a slow
        /// free model must still never lock chat, scan and record for minutes.
        static let remote: Double = 150
    }

    init() {
        // The Four Notes server address, from before providers were direct.
        UserDefaults.standard.removeObject(forKey: "fournotes.baseURL")
        CloudProviders.migrate()
        refresh()
    }

    func refresh() {
        cachedAnthropic = nil
        cachedCloud = nil
        cachedLocal = nil
        route = answerers.first?.route ?? .unavailable
        revision += 1
    }

    // MARK: - The models

    /// Read once per `refresh()` rather than per access: these are read from
    /// view bodies, and each is several Keychain round-trips.
    private var cachedAnthropic: AnthropicClient??
    private var cachedCloud: [(tab: CloudProviders.Tab, answerer: Answerer)]?
    private var cachedLocal: OpenAICompatibleClient??

    private var anthropic: AnthropicClient? {
        if let cachedAnthropic { return cachedAnthropic }
        let resolved = resolveAnthropic()
        cachedAnthropic = .some(resolved)
        return resolved
    }

    private func resolveAnthropic() -> AnthropicClient? {
        guard let key = Keychain.read(.anthropicKey), Keychain.isValid(key), !key.isEmpty else { return nil }
        return AnthropicClient(
            apiKey: key,
            model: Keychain.read(.anthropicModel).flatMap { $0.isEmpty ? nil : $0 }
                ?? AnthropicClient.defaultModel,
            fastModel: Keychain.read(.anthropicFastModel).flatMap { $0.isEmpty ? nil : $0 }
                ?? AnthropicClient.defaultFastModel)
    }

    /// Every cloud model with a key, in the order they are asked.
    private var cloud: [(tab: CloudProviders.Tab, answerer: Answerer)] {
        if let cachedCloud { return cachedCloud }
        var ready: [CloudProviders.Tab: Answerer] = [:]
        ready[.anthropic] = anthropic.map(Answerer.anthropic)
        ready[.openrouter] = CloudProviders.openRouter().map(Answerer.provider)
        ready[.opencode] = CloudProviders.openCode().map(Answerer.provider)
        ready[.other] = Self.resolveProvider(.cloud).map(Answerer.provider)
        let resolved = CloudProviders.ordered(Array(ready.keys)).compactMap { tab in ready[tab].map { (tab, $0) } }
        cachedCloud = resolved
        return resolved
    }

    private var cloudAnswerers: [Answerer] { cloud.map(\.answerer) }

    /// The Settings tabs whose model is ready, in the order they are asked.
    var cloudTabs: [CloudProviders.Tab] { cloud.map(\.tab) }

    /// The local model server — LM Studio, Ollama — when one is chosen.
    private var localProvider: OpenAICompatibleClient? {
        if let cachedLocal { return cachedLocal }
        let resolved = Self.resolveProvider(.local)
        cachedLocal = .some(resolved)
        return resolved
    }

    static func resolveProvider(_ slot: AIProvider.Slot) -> OpenAICompatibleClient? {
        // OpenRouter and OpenCode have tabs of their own, with their own keys.
        guard let chosen = AIProvider.find(Keychain.read(slot.idItem)), chosen.slot == slot,
              !chosen.hasOwnTab else { return nil }
        let base = Keychain.read(slot.baseURLItem).flatMap { $0.isEmpty ? nil : $0 } ?? chosen.baseURL
        let key = slot.keyItem.flatMap(Keychain.read).flatMap { Keychain.isValid($0) && !$0.isEmpty ? $0 : nil }
        let model = Keychain.read(slot.modelItem) ?? ""
        guard !base.isEmpty, !model.isEmpty, key != nil || !chosen.needsKey else { return nil }
        return OpenAICompatibleClient(provider: chosen, baseURL: base, apiKey: key, model: model)
    }

    /// Apple's on-device model, when this Mac has it. It calls tools, so it can
    /// file things the same way Claude does.
    private func appleProvider() -> AppleProvider? {
        OnDevice.languageModelAvailable ? AppleProvider() : nil
    }

    private var localAnswerers: [Answerer] {
        [localProvider.flatMap { isStopped($0) ? nil : Answerer.provider($0) },
         appleProvider().map(Answerer.apple)].compactMap { $0 }
    }

    /// LM Studio or Ollama, known to be stopped. Asking it would only fail —
    /// and with "This Mac first", every request would fail with it, even
    /// with Apple Intelligence or a cloud key ready. Unknown counts as running.
    private func isStopped(_ client: OpenAICompatibleClient) -> Bool {
        guard client.runsOnThisMac,
              let kind = LocalServers.Kind.allCases.first(where: { $0.providerId == client.provider.id }),
              let status = LocalServers.shared.status[kind] else { return false }
        return !status.running
    }

    /// Everyone who may answer, in the order they are asked. Local first never
    /// falls through to the cloud while a local model exists: that is the
    /// user's call, one reply at a time.
    private var answerers: [Answerer] {
        Self.ordered(local: localAnswerers, cloud: cloudAnswerers, priority: priority)
    }

    nonisolated static func ordered<T>(local: [T], cloud: [T], priority: Priority) -> [T] {
        switch priority {
        case .localFirst: return local.isEmpty ? cloud : local
        case .cloudFirst: return cloud + local
        }
    }

    /// What each group is set to, in the order it is asked.
    var localSummary: String {
        let names = localAnswerers.map(\.detail)
        return names.isEmpty ? "Nothing available" : names.joined(separator: ", then ")
    }

    var cloudSummary: String {
        let names = cloudAnswerers.map(\.detail)
        return names.isEmpty ? "Not set up" : names.joined(separator: ", then ")
    }

    /// True when chat is answered on this Mac rather than in the cloud.
    var chatRunsOnDevice: Bool { answerers.first?.isLocal == true }

    /// Who answers chat first: "Apple Intelligence", "Claude", "LM Studio"…
    var chatAnswererName: String? { answerers.first?.shortName }

    /// The cloud model a local answer can be handed to, when there is one.
    var cloudOffer: String? {
        // Only while online: the whole point is what the internet knows.
        guard chatRunsOnDevice, Connectivity.shared.isOnline else { return nil }
        return cloudAnswerers.first?.shortName
    }

    /// Chat needs tool calling: Claude, a provider, or Apple's on-device model.
    var canChat: Bool { !answerers.isEmpty }
    /// Scanning always works: Vision reads the page even with no model at all.
    var canScan: Bool { true }
    /// Briefs and reviews work on-device too.
    var canSummarize: Bool { canChat || OnDevice.languageModelAvailable }

    // MARK: - Web

    /// Searching the web needs Claude: Apple's on-device model has no internet.
    var canSearchWeb: Bool { anthropic != nil }

    func webIdeas(title: String, content: String, question: String) async throws -> WebAnswer {
        guard let anthropic else {
            throw APIError.server("Add an Anthropic key in Settings → AI & API keys to search the web from here.")
        }
        return try await anthropic.webIdeas(title: title, content: content, question: question)
    }

    // MARK: - Chat

    /// `tools: false` for a message to answer rather than file.
    func chat(_ messages: [ChatMessage], context: ClientContext, tools: Bool = true) async throws -> ChatResponse {
        try await chat(messages, context: context, using: answerers, tools: tools)
    }

    /// The same conversation, answered in the cloud: the user asked for it on
    /// a reply this Mac wrote.
    /// Answer only: this Mac already filed whatever the message asked for.
    func chatInCloud(_ messages: [ChatMessage], context: ClientContext) async throws -> ChatResponse {
        let cloud = cloudAnswerers
        guard !cloud.isEmpty else {
            throw APIError.server("Add a cloud model in Settings → AI & API keys to ask it from here.")
        }
        return try await chat(messages, context: context, using: cloud, tools: false)
    }

    private func chat(_ messages: [ChatMessage], context: ClientContext,
                      using list: [Answerer], tools: Bool = true) async throws -> ChatResponse {
        let messages = Guard.trim(messages)
        // Refused before any model is asked (see Guard). The first model's
        // rules apply: a cloud model that fails may hand over to this Mac, but
        // "This Mac first" never hands over to the cloud.
        let tier: Guard.Tier = list.first?.isLocal == true ? .local : .cloud
        if let last = messages.last, last.role == .user, let refusal = Guard.blockedReply(last.content, tier: tier) {
            var response = ChatResponse(reply: refusal, actions: [])
            response.answeredBy = .onDevice
            response.answererName = "Four Notes"
            response.refused = true
            return response
        }
        var failure: Error?
        var failedName: String?
        for answerer in list {
            do {
                var response: ChatResponse
                switch answerer {
                case .anthropic(let client):
                    response = try await withDeadline(seconds: Deadline.remote) {
                        try await client.chat(messages, ctx: context, tools: tools)
                    }
                case .provider(let client):
                    response = try await withDeadline(seconds: Deadline.remote) {
                        try await client.chat(messages, ctx: context, tools: tools)
                    }
                case .apple(let apple):
                    response = try await withDeadline(seconds: Deadline.chat) {
                        try await apple.chat(messages, ctx: context, tools: tools)
                    }
                }
                // Said by the chat's own marks, not in the reply.
                if answerer.isLocal {
                    response.answeredBy = failure != nil && list.first?.isLocal == false ? .onDeviceFallback : .onDevice
                } else {
                    response.answeredBy = .cloud
                }
                response.answererName = answerer.shortName
                // Whatever a cloud model wrote, code and overlong answers aren't shown.
                let shown = Guard.enforce(response.reply, tier: answerer.isLocal ? .local : .cloud)
                if shown != response.reply {
                    response.reply = shown
                    response.refused = true
                }
                // Said in the chat, not hidden in a hover: the model the user
                // chose failed, and why.
                if let failure, let failedName {
                    response.fallbackNote = "\(failedName) couldn't answer (\(Self.reason(failure))), "
                        + "so \(answerer.shortName) stepped in."
                }
                return response
            } catch {
                // A model that is down, unreachable or misconfigured must not
                // take the whole assistant with it when the next can answer.
                if failure == nil { failedName = answerer.shortName }
                failure = error
            }
        }
        if let failure { throw failure }
        throw APIError.server(
            "Chat needs a model that can file things for you. Turn on Apple Intelligence, or add a model "
            + "in Settings → AI & API keys.")
    }

    /// A failure in a few words: "key rejected", "rate limited", "offline".
    nonisolated static func reason(_ error: Error) -> String {
        if case APIError.offline = error { return "offline" }
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("rejected") || lower.contains("401") || lower.contains("invalid") && lower.contains("key") {
            return "key rejected"
        }
        if lower.contains("credit") { return "out of credit" }
        if lower.contains("limit") || lower.contains("busy") || lower.contains("429") { return "busy or rate limited" }
        if lower.contains("dropped") || lower.contains("reach") || lower.contains("connection") { return "connection failed" }
        if lower.contains("too long") { return "timed out" }
        return "server error"
    }

    // MARK: - Scanning

    /// Reads the photo on this Mac first, then asks a model to sort and tidy the
    /// text. Falls back to the rule-based parsers when there is no model.
    func scan(_ image: NSImage, jpeg: Data, context: ClientContext) async throws -> CaptureResult {
        let ocr = await OnDevice.readText(from: image)
        // Vision read it cleanly: send the text, which is far cheaper than the
        // image. If it read little, or read it poorly, send the photo instead.
        let readWell = !ocr.isEmpty && ocr.confidence >= 0.5 && ocr.text.count >= 24
        var failure: Error?

        for answerer in answerers {
            switch answerer {
            case .anthropic(let client):
                do {
                    return try await withDeadline(seconds: Deadline.remote) {
                        readWell ? try await client.captureText(ocr.text, ctx: context)
                                 : try await client.captureImage(jpeg, ctx: context)
                    }
                } catch { failure = error }
            case .provider(let client):
                // Text first: every model reads text, not all can see.
                if readWell {
                    do {
                        return try await withDeadline(seconds: Deadline.remote) {
                            try await client.captureText(ocr.text, ctx: context)
                        }
                    } catch { failure = error }
                }
                do {
                    return try await withDeadline(seconds: Deadline.remote) {
                        try await client.captureImage(jpeg, ctx: context)
                    }
                } catch { failure = error }
            case .apple:
                break  // below, after the built-in reader
            }
        }

        guard !ocr.isEmpty else {
            throw failure ?? APIError.server(
                "No text could be read from that image, and no AI model is set up to look closer.")
        }
        // The built-in reader handles receipts: it is instant and more accurate
        // than the small model at pulling a total off a page.
        let local = OnDevice.fileLocally(ocr.text, ctx: context)
        if local.kind == .receipt { return local }

        // Anything else is prose, which the on-device model is good at tidying.
        if let apple = appleProvider(),
           let tidied = try? await withDeadline(seconds: Deadline.capture, {
               try await apple.tidyNote(ocr.text, ctx: context, isRecording: false)
           }) {
            return tidied
        }
        return local
    }

    // MARK: - Voice notes

    /// The transcript is produced on-device while recording, so a model only has
    /// to write it up. With no model, the transcript is saved as a note as-is.
    func summarizeRecording(_ transcript: String, audio: Data?,
                            context: ClientContext) async throws -> CaptureResult {
        guard !transcript.isEmpty else {
            throw APIError.server("Nothing was transcribed from that recording.")
        }
        for answerer in answerers {
            switch answerer {
            case .anthropic(let client):
                if let result = try? await withDeadline(seconds: Deadline.remote, {
                    try await client.summarizeRecording(transcript, ctx: context)
                }) { return result }
            case .provider(let client):
                if let result = try? await withDeadline(seconds: Deadline.remote, {
                    try await client.summarizeRecording(transcript, ctx: context)
                }) { return result }
            case .apple(let apple):
                // The path that produced the three-minute hang: it was the one
                // caller of tidyNote without a deadline.
                if let tidied = try? await withDeadline(seconds: Deadline.capture, {
                    try await apple.tidyNote(transcript, ctx: context, isRecording: true)
                }) {
                    return tidied
                }
            }
        }
        let action: [String: Any] = [
            "type": "create_note",
            "title": String(transcript.prefix(60)),
            "content": transcript,
            "tags": ["recording"],
        ]
        return CaptureResult(
            kind: .handwritten_note,
            reply: "Transcribed on this Mac and saved as a note. Add an AI model to get a summary and action items.",
            actions: AITools.decodeActions([action]))
    }

    // MARK: - Short text jobs

    /// Asks each model in turn; the first answer wins.
    private func firstAnswer(_ job: String,
                             anthropic: @escaping @MainActor (AnthropicClient) async throws -> String,
                             provider: @escaping @MainActor (OpenAICompatibleClient) async throws -> String,
                             apple: @escaping @Sendable () async throws -> String) async throws -> String {
        var failure: Error?
        for answerer in answerers {
            do {
                switch answerer {
                case .anthropic(let client):
                    return try await withMainActorDeadline(seconds: Deadline.remote) { try await anthropic(client) }
                case .provider(let client):
                    return try await withMainActorDeadline(seconds: Deadline.remote) { try await provider(client) }
                case .apple: return try await withDeadline(seconds: Deadline.summary, apple)
                }
            } catch { failure = error }
        }
        throw failure ?? APIError.server("The \(job) needs Apple Intelligence or an AI model.")
    }

    func dailyBrief(_ input: BriefInput) async throws -> String {
        try await firstAnswer("brief",
                              anthropic: { try await $0.dailyBrief(input) },
                              provider: { try await $0.dailyBrief(input) },
                              apple: { try await OnDevice.dailyBrief(input) })
    }

    func monthlySummary(month: String, currency: String,
                        transactions: [Transaction]) async throws -> String {
        try await firstAnswer("review",
                              anthropic: { try await $0.monthlySummary(month: month, currency: currency,
                                                                        transactions: transactions) },
                              provider: { try await $0.monthlySummary(month: month, currency: currency,
                                                                       transactions: transactions) },
                              apple: { try await OnDevice.monthlySummary(month: month, currency: currency,
                                                                          transactions: transactions) })
    }

    func write(_ task: WriteTask, text: String, title: String) async throws -> String {
        try await firstAnswer("writing help",
                              anthropic: { try await $0.write(task, text: text, title: title) },
                              provider: { try await $0.write(task, text: text, title: title) },
                              apple: { try await OnDevice.write(task, text: text, title: title) })
    }

    /// Exchange rates, from the public endpoint the web app uses.
    func fx(from: String, to: String) async throws -> Double {
        try await FXRates.fetch(from: from, to: to)
    }

    // MARK: - Diagnostics for Settings

    struct Readiness {
        var route: Route
        var chat: String
        var scanning: String
        var voice: String
        var summaries: String
    }

    var readiness: Readiness {
        let sorter = route == .unavailable ? nil : route.label
        return Readiness(
            route: route,
            chat: canChat
                ? "Ready · \(route.label)"
                : "Unavailable · \(OnDevice.languageModelStatus)",
            scanning: sorter.map { "Read on this Mac (Vision), sorted by \($0)" }
                ?? "Read on this Mac (Vision), filed by the built-in parser",
            voice: sorter.map { "Transcribed on this Mac, written up by \($0)" }
                ?? "Transcribed on this Mac, saved as a plain note",
            summaries: canSummarize
                ? "Ready · \(route.label)"
                : "Unavailable · \(OnDevice.languageModelStatus)")
    }
}

/// Runs `work`, giving up if it takes too long.
///
/// Every model call goes through this — on-device, local server and cloud. A
/// wide request can run for minutes, and a scan, a chat turn or a voice note
/// must never leave the assistant stuck with no way out.
///
/// The deadline wins even when `work` ignores cancellation: the caller is
/// released at once and `work` is cancelled and left to finish on its own. (A
/// task group waits for every child, so it could only give up when the stuck
/// call itself did.)
func withDeadline<T: Sendable>(seconds: Double,
                               _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.start(continuation)
            let worker = Task {
                do { gate.resume(.success(try await work())) } catch { gate.resume(.failure(error)) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                gate.resume(.failure(APIError.server("That took too long, so the app stopped waiting.")))
            }
            gate.onFinish { worker.cancel(); timer.cancel() }
        }
    } onCancel: {
        gate.resume(.failure(CancellationError()))
    }
}

/// The same, for work that has to stay on the main actor (a closure handed in
/// by a caller there).
@MainActor
func withMainActorDeadline(seconds: Double,
                           _ work: @escaping @MainActor () async throws -> String) async throws -> String {
    try await withDeadline(seconds: seconds) { try await work() }
}

/// Resumes a continuation exactly once, from whichever of the work, the timer
/// or a cancellation gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var cleanup: (@Sendable () -> Void)?
    private var done = false

    func start(_ c: CheckedContinuation<T, Error>) {
        let early: Result<T, Error>? = lock.withLock {
            if let pending { self.pending = nil; return pending }
            continuation = c
            return nil
        }
        if let early { c.resume(with: early) }
    }

    func onFinish(_ run: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if done { return true }
            cleanup = run
            return false
        }
        if runNow { run() }
    }

    func resume(_ result: Result<T, Error>) {
        let (c, run): (CheckedContinuation<T, Error>?, (@Sendable () -> Void)?) = lock.withLock {
            guard !done else { return (nil, nil) }
            done = true
            let c = continuation
            continuation = nil
            // Cancelled before the continuation existed: keep it for start().
            if c == nil { pending = result }
            let run = cleanup
            cleanup = nil
            return (c, run)
        }
        c?.resume(with: result)
        run?()
    }
}

// MARK: - Exchange rates without a server

enum FXRates {
    /// Three letters, nothing else — the shape every ISO 4217 code has.
    static func isCurrencyCode(_ code: String) -> Bool {
        code.count == 3 && code.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// The same free endpoint the web app's /api/fx route proxies.
    static func fetch(from: String, to: String) async throws -> Double {
        guard from != to else { return 1 }
        // `from` is whatever ended up on the transaction, which may have come
        // from a model. Anything but a plain ISO code is refused rather than
        // force-unwrapped into a URL.
        guard isCurrencyCode(from), isCurrencyCode(to),
              let url = URL(string: "https://api.frankfurter.app/latest?from=\(from)&to=\(to)")
        else { throw APIError.server("\(from) is not a currency this app can look up.") }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rates = json["rates"] as? [String: Any],
                  let rate = rates[to] as? Double else {
                throw APIError.server("No exchange rate for \(from) → \(to).")
            }
            return rate
        } catch let error as URLError {
            if error.code == .notConnectedToInternet { throw APIError.offline }
            throw APIError.server(error.localizedDescription)
        }
    }
}
