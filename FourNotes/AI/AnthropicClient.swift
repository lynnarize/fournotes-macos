import Foundation

// Talks to the Claude Messages API directly. On a single-user Mac app the key
// is the user's own and lives in this Mac's Keychain, so there is no shared
// deployment to protect and no reason to relay through a server.
// Ported from src/lib/ai/anthropic.ts.

struct AnthropicClient {
    var apiKey: String
    var model: String
    var fastModel: String

    static let defaultModel = "claude-sonnet-5"
    static let defaultFastModel = "claude-haiku-4-5"

    static let userModels: [(id: String, label: String)] = [
        ("claude-opus-5", "Claude Opus 5 · most capable"),
        ("claude-sonnet-5", "Claude Sonnet 5 · balanced"),
        ("claude-haiku-4-5", "Claude Haiku 4.5 · fastest, cheapest"),
    ]

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    // MARK: - Chat

    /// `tools: false` answers only: offered no tools, the model can't claim to
    /// have filed anything.
    func chat(_ history: [ChatMessage], ctx: ClientContext, tools: Bool = true) async throws -> ChatResponse {
        var messages: [[String: Any]] = history.suffix(20).map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        var rawActions: [[String: Any]] = []
        var reply = ""

        // Small agent loop: the model may call tools, we "execute" them by
        // queuing actions for the store, send back a tool_result, and let it finish.
        for _ in 0..<4 {
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 1024,
                "system": cachedSystem(ctx, chat: true),
                "messages": messages,
            ]
            if tools { body["tools"] = AITools.cachedActionTools }
            let response = try await send(body)

            reply += response.text
            let toolUses = response.toolUses
            if response.stopReason != "tool_use" || toolUses.isEmpty { break }

            for use in toolUses {
                var action = use.input
                action["type"] = use.name
                rawActions.append(action)
            }
            messages.append(["role": "assistant", "content": response.content])
            messages.append([
                "role": "user",
                "content": toolUses.map {
                    ["type": "tool_result", "tool_use_id": $0.id, "content": "saved"]
                },
            ])
        }

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let actions = AITools.decodeActions(rawActions)
        return ChatResponse(reply: trimmed.isEmpty ? "Done!" : trimmed,
                            actions: actions,
                            droppedActions: rawActions.count - actions.count)
    }

    // MARK: - Web ideas

    /// Recommendations for what a note is about, found on the web with
    /// Anthropic's server-side web search. Only ever run from the user's own
    /// "Ideas from the web" tap: it sends the note to Anthropic and searches.
    func webIdeas(title: String, content: String, question: String) async throws -> WebAnswer {
        // The dynamic-filtering search needs a current Sonnet or Opus; Haiku
        // keeps the basic tool.
        let searchTool = model.contains("haiku") ? "web_search_20250305" : "web_search_20260209"
        let ask = question.isEmpty
            ? "Suggest a few concrete, current recommendations that would help with this note."
            : question
        var messages: [[String: Any]] = [[
            "role": "user",
            "content": """
                My note “\(title)”:
                \(String(content.prefix(6000)))

                \(ask)
                """,
        ]]
        var text = ""
        var content: [[String: Any]] = []

        // A long search can come back paused; sending the turn back as it
        // stands lets it carry on.
        for _ in 0..<3 {
            let response = try await send([
                "model": model,
                "max_tokens": 4000,
                "system": Prompts.webIdeasSystem,
                "tools": [["type": searchTool, "name": "web_search", "max_uses": 4]],
                "messages": messages,
            ], timeout: 180)
            text += response.text
            content += response.content
            guard response.stopReason == "pause_turn" else { break }
            messages.append(["role": "assistant", "content": response.content])
        }

        // Sources: every page a sentence of the answer cites, once each.
        var sources: [WebAnswer.Source] = []
        for block in content where block["type"] as? String == "text" {
            for citation in block["citations"] as? [[String: Any]] ?? [] {
                guard let url = citation["url"] as? String, !sources.contains(where: { $0.url == url }) else { continue }
                sources.append(.init(title: citation["title"] as? String ?? url, url: url))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.server("The web search came back empty. Try again in a moment.") }
        return WebAnswer(text: trimmed, sources: Array(sources.prefix(6)))
    }

    // MARK: - Capture

    /// Send the photo itself and let the model do the reading.
    func captureImage(_ jpeg: Data, ctx: ClientContext) async throws -> CaptureResult {
        try await capture(ctx: ctx, content: [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg",
                        "data": jpeg.base64EncodedString()]],
            ["type": "text", "text": Prompts.imageCapture],
        ])
    }

    /// Send text that Vision already read off the page — no image tokens.
    func captureText(_ text: String, ctx: ClientContext) async throws -> CaptureResult {
        try await capture(ctx: ctx, content: [["type": "text", "text": Prompts.textCapture(text)]])
    }

    func summarizeRecording(_ transcript: String, ctx: ClientContext) async throws -> CaptureResult {
        var result = try await capture(ctx: ctx,
                                       content: [["type": "text", "text": Prompts.recording(transcript)]])
        // Keep the raw transcript under the summary so nothing is lost.
        result.actions = result.actions.map { action in
            if case let .createNote(title, content, tags, ref) = action {
                return .createNote(title: title,
                                   content: content + "\n\n---\nTranscript:\n\(transcript)",
                                   tags: tags, ref: ref)
            }
            return action
        }
        return result
    }

    private func capture(ctx: ClientContext, content: [[String: Any]]) async throws -> CaptureResult {
        // The capture prompts do not need the user's rows, only their categories
        // and currency, so the big context blocks are dropped.
        var lean = ctx
        lean.notes = []
        lean.todos = []
        lean.transactions = []
        lean.relevantNotes = []

        let response = try await send([
            "model": model,
            "max_tokens": 2048,
            "system": cachedSystem(lean),
            "tools": [AITools.captureTool],
            "tool_choice": ["type": "tool", "name": "file_capture"],
            "messages": [["role": "user", "content": content]],
        ])
        return CaptureMapper.toActions(response.toolUses.first?.input ?? [:], ctx: ctx)
    }

    // MARK: - Short text jobs (the cheap model)

    func monthlySummary(month: String, currency: String, transactions: [Transaction]) async throws -> String {
        try await text(model: fastModel, maxTokens: 600,
                       prompt: Prompts.monthlySummary(month: month, currency: currency,
                                                      transactions: transactions))
    }

    func dailyBrief(_ input: BriefInput) async throws -> String {
        try await text(model: fastModel, maxTokens: 250, prompt: Prompts.dailyBrief(input))
    }

    func write(_ task: WriteTask, text body: String, title: String) async throws -> String {
        try await text(model: model, maxTokens: 1500, system: Prompts.writingSystem,
                       prompt: Prompts.writing(task, text: body, title: title))
    }

    private func text(model: String, maxTokens: Int, system: String? = nil,
                      prompt: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        if let system { body["system"] = system }
        return try await send(body).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transport

    /// Prompt caching: the static instructions and tool definitions are identical
    /// on every request, so they carry a cache breakpoint. Per-user data goes after it.
    /// `chat` adds the scope rules (see Guard) after the breakpoint, so caching still works.
    private func cachedSystem(_ ctx: ClientContext, chat: Bool = false) -> [[String: Any]] {
        [
            ["type": "text", "text": Prompts.staticInstructions,
             "cache_control": ["type": "ephemeral"]],
            ["type": "text", "text": Prompts.dynamicContext(ctx) + "\n\n"
                + Prompts.identity(model: model, provider: "your own Anthropic API key")
                + (chat ? "\n\n" + Guard.scopeInstructions(.cloud) : "")],
        ]
    }

    private struct Response {
        var content: [[String: Any]]
        var stopReason: String?
        var text: String
        var toolUses: [(id: String, name: String, input: [String: Any])]
    }

    private func send(_ body: [String: Any], timeout: TimeInterval = 120) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, urlResponse: URLResponse
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            if error.code == .notConnectedToInternet { throw APIError.offline }
            if error.code == .networkConnectionLost || error.code == .timedOut {
                throw APIError.server("The connection to Anthropic dropped. Try again in a moment.")
            }
            throw APIError.server(error.localizedDescription)
        }

        guard let http = urlResponse as? HTTPURLResponse else { throw APIError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(http.statusCode) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String
            throw APIError.server(message ?? anthropicStatusMessage(http.statusCode))
        }

        let content = json["content"] as? [[String: Any]] ?? []
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        let toolUses = content.compactMap { block -> (String, String, [String: Any])? in
            guard block["type"] as? String == "tool_use",
                  let id = block["id"] as? String,
                  let name = block["name"] as? String else { return nil }
            return (id, name, block["input"] as? [String: Any] ?? [:])
        }
        return Response(content: content, stopReason: json["stop_reason"] as? String,
                        text: text, toolUses: toolUses)
    }

    private func anthropicStatusMessage(_ code: Int) -> String {
        switch code {
        case 401: return "That Anthropic key was rejected. Check it in Settings → AI & API keys."
        case 429: return "Anthropic is rate limiting this key. Try again in a moment."
        case 529: return "Anthropic is overloaded right now. Try again in a moment."
        default: return "Anthropic request failed (\(code))."
        }
    }
}
