import CryptoKit
import Foundation

// Talks to any provider with OpenAI's chat-completions API: OpenRouter,
// OpenCode (Zen's free models, or a Go subscription), OpenAI, Groq, Gemini,
// Ollama, LM Studio, or another endpoint of the same shape. It does what
// AnthropicClient does — chat with the app's tools, reading scans and voice
// notes, the brief, the review and writing help — with the same prompts and
// tools, translated into function calling.
//
// It carries the web app's hard-won handling of free and open models
// (src/lib/ai/openrouter.ts): schemas simplified for strict parsers, a second
// ask when a model describes a tool call instead of making it, thinking
// stripped from replies, JSON read out of prose, a re-ask for half-filled
// receipts, and data-only fallbacks for an unusable brief or review. On
// OpenRouter it also routes free models down the probe-verified list, sends
// photos to a model that can see, and asks only providers that support tools.
// On OpenCode it names the app and keeps one session id per conversation, as
// OpenCode asks (Go rejects requests without one).

struct OpenAICompatibleClient {
    var provider: AIProvider
    var baseURL: String
    var apiKey: String?
    var model: String
    /// For the brief and the review; the main model when nil.
    var fastModel: String?
    /// For photos, when the main model can't see; on OpenRouter worked out from the model.
    var visionModel: String?
    /// OpenCode's x-opencode-session: one per conversation in chat, one per request otherwise.
    private var session: String?

    init(provider: AIProvider, baseURL: String, apiKey: String?, model: String,
         fastModel: String? = nil, visionModel: String? = nil) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.fastModel = fastModel
        self.visionModel = visionModel
    }

    private var isOpenRouter: Bool { provider.id == "openrouter" }
    private var isOpenCode: Bool { provider.isOpenCode }
    /// OpenRouter and OpenCode host reasoning models that need room to think.
    private var capsTokens: Bool { isOpenRouter || isOpenCode }

    /// Runs on this Mac: the address actually used points here. A local
    /// preset whose address was changed to another machine is not "on this
    /// Mac", whatever its name says.
    var runsOnThisMac: Bool { Self.isThisMac(baseURL) }

    static func isThisMac(_ address: String) -> Bool {
        guard let host = URL(string: address)?.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// A request the provider refused, with its HTTP status.
    struct Failure: LocalizedError {
        var status: Int
        var message: String
        /// The provider's own words.
        var detail = ""
        var errorDescription: String? { message }
    }

    private static let couldNotAct =
        "I couldn't do that with this model. Try again, or pick another model in Settings → AI & API keys."
    private static let couldNotAnswer = "I couldn't answer that right now. Try again in a moment."
    private static let jsonFallback = " If you cannot call a tool, reply with the same fields as plain JSON."
    private static let receiptNudge =
        "That is a receipt, but the receipt fields were missing. Call file_capture again with kind 'receipt' and fill "
        + "receipt: {merchant, total (grand total as a number, 'Rp 128.500' = 128500), date, category, items}. "
        + "Put line items in receipt.items, never in todos."

    // MARK: - Chat

    /// `tools: false` answers only: offered no tools, the model can't claim to
    /// have filed anything.
    func chat(_ history: [ChatMessage], ctx: ClientContext, tools: Bool = true) async throws -> ChatResponse {
        // The same conversation (same key, same opening message) keeps the same session id across turns.
        var client = self
        let opening = history.first { $0.role == .user }?.content ?? ""
        client.session = SHA256.hash(data: Data("\(apiKey ?? "")\n\(opening)".utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(32).description
        return try await client.converse(history, ctx: ctx, tools: tools)
    }

    private func converse(_ history: [ChatMessage], ctx: ClientContext, tools: Bool) async throws -> ChatResponse {
        let base: [[String: Any]] = [["role": "system", "content": system(ctx) + "\n\n"
                                         + Guard.scopeInstructions(runsOnThisMac ? .local : .cloud)]]
            + history.suffix(20).map { ["role": $0.role.rawValue, "content": $0.content] }

        var out = try await chatLoop(base, firstChoice: tools ? "auto" : nil)
        // Some models describe the tool call in prose instead of making it: insist once.
        if tools, out.raw.isEmpty, ModelText.looksLikePlanning(out.reply),
           let insisted = try? await chatLoop(base, firstChoice: "required") {
            out = insisted
        }

        let actions = AITools.decodeActions(out.raw)
        // Never show a model's working-out (or a safety classifier's verdict,
        // which the free router can land on) as the answer, and never claim
        // "done" when nothing was filed.
        let reply: String
        if out.reply.isEmpty || ModelText.looksLikePlanning(out.reply) || ModelText.looksLikeThinking(out.reply)
            || Self.isClassifierVerdict(out.reply) {
            reply = !actions.isEmpty ? ModelText.describe(actions)
                : (tools && !out.reply.isEmpty ? Self.couldNotAct : Self.couldNotAnswer)
        } else {
            reply = out.reply
        }
        return ChatResponse(reply: reply, actions: actions, droppedActions: out.raw.count - actions.count)
    }

    /// `firstChoice` nil: no tools at all.
    private func chatLoop(_ start: [[String: Any]], firstChoice: String?) async throws
        -> (reply: String, raw: [[String: Any]]) {
        var messages = start
        var raw: [[String: Any]] = []
        var reply = ""

        // Tools are "run" by queuing actions for the store and answering
        // "saved"; then the model finishes.
        for turn in 0..<3 {
            var body: [String: Any] = ["model": model, "messages": messages]
            if let firstChoice {
                body["tools"] = Self.functions(AITools.actionTools)
                // "required" only on the first turn, or it could never stop calling tools.
                body["tool_choice"] = turn == 0 ? firstChoice : "auto"
            }
            if capsTokens { body["max_tokens"] = 2048 }  // reasoning models spend part of this thinking
            let message = try await complete(body)
            let text = ModelText.clean(message.text)
            if !text.isEmpty { reply += (reply.isEmpty ? "" : "\n") + text }
            if message.toolCalls.isEmpty { break }

            for call in message.toolCalls {
                var action = call.arguments
                action["type"] = call.name
                raw.append(action)
            }
            messages.append(message.raw)
            for call in message.toolCalls {
                messages.append(["role": "tool", "tool_call_id": call.id, "content": "saved"])
            }
        }
        return (reply.trimmingCharacters(in: .whitespacesAndNewlines), raw)
    }

    // MARK: - Capture

    /// The photo itself — on OpenRouter, sent to a model that can see.
    func captureImage(_ jpeg: Data, ctx: ClientContext) async throws -> CaptureResult {
        try await capture(ctx: ctx,
                          content: [
                              ["type": "image_url",
                               "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                              ["type": "text", "text": Prompts.imageCapture + Self.jsonFallback],
                          ],
                          model: visionModel ?? (isOpenRouter ? OpenRouterModels.visionModel(for: model) : model))
    }

    /// Text that Vision already read off the page.
    func captureText(_ text: String, ctx: ClientContext) async throws -> CaptureResult {
        try await capture(ctx: ctx, content: Prompts.textCapture(text) + Self.jsonFallback, model: model)
    }

    func summarizeRecording(_ transcript: String, ctx: ClientContext) async throws -> CaptureResult {
        var result = try await capture(ctx: ctx, content: Prompts.recording(transcript) + Self.jsonFallback,
                                       model: model)
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

    private func capture(ctx: ClientContext, content: Any, model: String) async throws -> CaptureResult {
        var lean = ctx
        lean.notes = []
        lean.todos = []
        lean.transactions = []
        lean.relevantNotes = []
        let messages: [[String: Any]] = [
            ["role": "system", "content": system(lean)],
            ["role": "user", "content": content],
        ]
        return try await captureCall(messages, ctx: ctx, model: model, retried: false)
    }

    /// Forced tool use where the model supports it; otherwise its own choice,
    /// or plain JSON in the reply.
    private func captureCall(_ messages: [[String: Any]], ctx: ClientContext, model: String,
                             retried: Bool) async throws -> CaptureResult {
        let tool = AITools.captureTool
        let name = tool["name"] as? String ?? "file_capture"
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": Self.functions([tool]),
            "tool_choice": ["type": "function", "function": ["name": name]],
        ]
        if capsTokens { body["max_tokens"] = 3072 }

        let message: Message
        do {
            message = try await complete(body)
        } catch let failure as Failure where failure.status < 500 && failure.status != 429
                    && ![401, 402, 403, 404].contains(failure.status) {
            // A rejected key, no credit or no such model won't be fixed by
            // asking again; anything else may be a model that can't be forced
            // to a tool, so let it choose.
            body["tool_choice"] = "auto"
            message = try await complete(body)
        }

        let text = ModelText.clean(message.text)
        let input = message.toolCalls.first(where: { $0.name == name })?.arguments ?? ModelText.json(text)

        if let input, input["kind"] as? String == "receipt", !retried {
            let receipt = CaptureMapper.receiptFields(input)
            if receipt.merchant == nil || (receipt.total ?? 0) == 0 {
                // Read it, but filed it in the wrong fields: ask once more.
                return try await captureCall(messages + [["role": "user", "content": Self.receiptNudge]],
                                             ctx: ctx, model: model, retried: true)
            }
        }
        if let input, input["kind"] != nil || input["note"] != nil || input["receipt"] != nil || input["todos"] != nil {
            return CaptureMapper.toActions(input, ctx: ctx)
        }

        // Last resort: keep whatever the model read so nothing is lost — but
        // not its working-out.
        let kept = ModelText.looksLikePlanning(text) ? "" : text
        return CaptureResult(
            kind: .other,
            reply: kept.isEmpty ? "I couldn't read that one." : "I couldn't sort that automatically, so I saved it as a note.",
            actions: kept.isEmpty ? [] : AITools.decodeActions([
                ["type": "create_note", "title": "Scanned item", "content": kept],
            ]))
    }

    // MARK: - Short text jobs

    func monthlySummary(month: String, currency: String, transactions: [Transaction]) async throws -> String {
        let text = try await self.text(Prompts.monthlySummary(month: month, currency: currency,
                                                              transactions: transactions),
                                       model: fastModel ?? model)
        let words = text.split(whereSeparator: \.isWhitespace).count
        if text.isEmpty || words > 220 || ModelText.looksLikeThinking(text) || ModelText.looksLikePlanning(text) {
            return LocalSummaries.monthly(month: month, currency: currency, transactions: transactions)
        }
        return text
    }

    func dailyBrief(_ input: BriefInput) async throws -> String {
        let text = try await self.text(Prompts.dailyBrief(input), model: fastModel ?? model)
        return ModelText.briefLines(text)?.joined(separator: "\n") ?? LocalSummaries.brief(input)
    }

    func write(_ task: WriteTask, text body: String, title: String) async throws -> String {
        let out = try await text(Prompts.writingSystem + "\n\n" + Prompts.writing(task, text: body, title: title),
                                 model: model)
        if out.isEmpty || ModelText.looksLikeThinking(out) || ModelText.looksLikePlanning(out) {
            throw APIError.server("The model couldn't do that right now. Try again, or pick another model in Settings → AI & API keys.")
        }
        return out
    }

    /// Plain text. Thinking models get room to think, but only the <answer> is kept.
    private func text(_ prompt: String, model: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt + "\n\n" + ModelText.answerInstruction]],
        ]
        if capsTokens { body["max_tokens"] = 2048 }
        // Keep reasoning out of the reply where supported (an OpenRouter-only parameter).
        if isOpenRouter { body["reasoning"] = ["exclude": true] }
        return ModelText.extractAnswer(try await complete(body).text)
    }

    // MARK: - Settings

    /// The models the endpoint offers, which also proves the address and key work.
    func listModels() async throws -> [String] {
        guard let url = endpoint("models") else { throw APIError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        authorise(&request)
        let json = try await perform(request)
        let ids = (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.sorted()
    }

    /// Settings → Test on the OpenRouter and OpenCode tabs: does the key work
    /// with the chosen model, in one sentence. Ported from the web app's
    /// /api/ai/test; uses no tokens where it can.
    func checkKey(modelLabel: String) async -> (ok: Bool, message: String) {
        guard let apiKey, !apiKey.isEmpty else { return (false, "Add your \(provider.name) key first.") }
        do {
            return isOpenCode ? try await checkOpenCode(modelLabel) : try await checkOpenRouter(modelLabel)
        } catch let failure as Failure {
            return (false, failure.message)
        } catch {
            return (false, (error as? LocalizedError)?.errorDescription ?? "Test failed. Check the key and try again.")
        }
    }

    private func checkOpenRouter(_ label: String) async throws -> (ok: Bool, message: String) {
        guard let url = endpoint("key") else { throw APIError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        authorise(&request)
        let info: [String: Any]
        do {
            info = try await perform(request)["data"] as? [String: Any] ?? [:]
        } catch let failure as Failure where [401, 403].contains(failure.status) {
            return (false, "OpenRouter rejected this key.")
        }
        let remaining = info["limit_remaining"] as? Double
        // A working key isn't enough: the chosen model has to still exist.
        let listed = try? await listModels()
        let missing = listed.map { !$0.isEmpty && !$0.contains(model) } ?? false
        if !OpenRouterModels.isFree(model) {
            if missing { return (false, "Key works, but OpenRouter has no model called \(model).") }
            if info["is_free_tier"] as? Bool == true {
                return (false, "Key works, but this account has no credits yet. Add some to use \(label).")
            }
            if let remaining, remaining <= 0 {
                return (false, "Key works, but its credit limit is used up. \(label) needs credits.")
            }
            return (true, "Key works. Using \(label) (paid)"
                + (remaining.map { String(format: " · $%.2f left on this key", $0) } ?? "") + ".")
        }
        if missing, model != OpenRouterModels.autoModel {
            return (true, "Key works, but \(label) is no longer offered. Another tested free model will answer.")
        }
        return (true, "Key works. Using \(label). Free models have daily limits.")
    }

    /// Zen and Go have no key-info endpoint (their model lists are public), so send the smallest real request.
    private func checkOpenCode(_ label: String) async throws -> (ok: Bool, message: String) {
        guard let url = endpoint("chat/completions") else { throw APIError.notConfigured }
        let go = provider.id == "opencode-go"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorise(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 16, "messages": [["role": "user", "content": "ping"]],
        ] as [String: Any])
        do {
            _ = try await perform(request)
            return (true, "Key works. Using \(label)\(go ? " on OpenCode Go" : " (free)").")
        } catch let failure as Failure {
            switch failure.status {
            case 401, 403: return (false, "OpenCode rejected this key.")
            case 402:
                return (false, go
                    ? "Key works, but it has no active OpenCode Go subscription. Subscribe at opencode.ai/go, or switch to Free."
                    : "Key works, but \(label) needs a balance. Add credits at opencode.ai, or pick a free model.")
            case 429 where go: return (true, "Key works. Go usage limit reached for now; \(label) will work again when it resets.")
            case 429: return (true, "Key works (rate limited right now). Using \(label).")
            case 404: return (false, "Key works, but OpenCode doesn't offer \(label) any more. Pick another model.")
            default:
                // A 400 here is about the request (model, parameters), not the key.
                let detail = failure.detail.isEmpty ? "" : ": \(failure.detail.prefix(200))"
                return (false, "OpenCode returned an error (\(failure.status))\(detail).")
            }
        }
    }

    // MARK: - Transport

    private func system(_ ctx: ClientContext) -> String {
        Prompts.staticInstructions + "\n\n" + Prompts.dynamicContext(ctx) + "\n\n"
            + Prompts.identity(model: model, provider: provider.shortName)
    }

    /// Claude's tool definitions in the function-calling format, with union
    /// types some models reject simplified away.
    static func functions(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let schema = tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()]
            return ["type": "function",
                    "function": ["name": name,
                                 "description": tool["description"] as? String ?? "",
                                 "parameters": ModelText.simplifySchema(schema)]]
        }
    }

    struct ToolCall {
        var id: String
        var name: String
        var arguments: [String: Any]
    }

    private struct Message {
        var raw: [String: Any]
        var text: String
        var toolCalls: [ToolCall]
    }

    private func endpoint(_ path: String) -> URL? {
        var raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: "\(raw)/\(path)")
    }

    private func authorise(_ request: inout URLRequest) {
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if isOpenRouter {
            // OpenRouter's attribution headers.
            request.setValue("https://app.fournotes.xyz", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Four Notes", forHTTPHeaderField: "X-Title")
        }
        if isOpenCode {
            request.setValue(OpenCodeModels.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(session ?? UUID().uuidString, forHTTPHeaderField: "x-opencode-session")
        }
    }

    /// "User Safety: safe": a safety classifier reached through the free router, not an answer.
    static func isClassifierVerdict(_ text: String) -> Bool {
        text.range(of: #"(?im)^\s*(user|response|prompt)\s+safety\s*:|^\s*(safe|unsafe)\s*$"#,
                   options: .regularExpression) != nil
    }

    private func complete(_ input: [String: Any], rerouted: Bool = false) async throws -> Message {
        guard let url = endpoint("chat/completions") else { throw APIError.notConfigured }
        let chosen = input["model"] as? String ?? ""
        guard !chosen.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw APIError.server("Choose a \(provider.name) model in Settings → AI & API keys.")
        }

        var body = input
        if isOpenRouter {
            // Tool requests only go to providers that actually support tools.
            if body["tools"] != nil { body["provider"] = ["require_parameters": true] }
            // Free models are busy or withdrawn often: let OpenRouter move down the tested list.
            if body["models"] == nil, OpenRouterModels.isFree(chosen) {
                let chain = OpenRouterModels.fallbackChain(chosen, vision: Self.hasImage(body))
                // Without tools nothing limits the free router to chat models (it
                // can land on a safety classifier), so plain answers stay on the tested list.
                body["models"] = body["tools"] != nil ? chain : chain.filter { $0 != OpenRouterModels.autoModel }
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorise(&request)
        guard JSONSerialization.isValidJSONObject(body) else { throw APIError.badResponse }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json: [String: Any]
        do {
            json = try await perform(request)
        } catch let failure as Failure where isOpenRouter && !rerouted && chosen != OpenRouterModels.autoModel
            && input["tools"] != nil && Self.modelGone(failure) {
            // A withdrawn id anywhere in the list fails the whole request, so
            // retry on the router alone.
            var retry = input
            retry["model"] = OpenRouterModels.autoModel
            retry["models"] = [OpenRouterModels.autoModel]
            return try await complete(retry, rerouted: true)
        }

        #if DEBUG
        // Which model answered: on OpenRouter a free model may have fallen back.
        let usage = json["usage"] as? [String: Any]
        print("[ai:\(provider.id)] model=\(json["model"] ?? chosen) in=\(usage?["prompt_tokens"] ?? "?") out=\(usage?["completion_tokens"] ?? "?")")
        #endif
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw APIError.badResponse
        }
        // Content is a string on most providers and a list of parts on a few.
        let text: String
        if let s = message["content"] as? String {
            text = s
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { call -> ToolCall? in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String else { return nil }
            // Arguments arrive as a JSON string — sometimes wrapped in prose or
            // fences — and from a few providers as an object.
            let arguments = (function["arguments"] as? [String: Any])
                ?? (function["arguments"] as? String).flatMap(ModelText.json)
                ?? [:]
            return ToolCall(id: call["id"] as? String ?? UUID().uuidString, name: name, arguments: arguments)
        }
        // What goes back into the conversation: the assistant turn as sent.
        var raw: [String: Any] = ["role": "assistant", "content": text]
        if let toolCalls = message["tool_calls"] { raw["tool_calls"] = toolCalls }
        return Message(raw: raw, text: text, toolCalls: calls)
    }

    private static func hasImage(_ body: [String: Any]) -> Bool {
        (body["messages"] as? [[String: Any]] ?? []).contains { message in
            (message["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" }
        }
    }

    private static func modelGone(_ failure: Failure) -> Bool {
        failure.status == 404 || (failure.status == 400
            && failure.detail.range(of: "not a valid model|no endpoints found|model.*(not found|does not exist)",
                                     options: [.regularExpression, .caseInsensitive]) != nil)
    }

    private func perform(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet:
                throw APIError.offline
            case .networkConnectionLost, .timedOut:
                // Busy free models drop long requests; the Mac is still online.
                throw APIError.server("The connection to \(provider.shortName) dropped. Try again in a moment.")
            case .cannotConnectToHost, .cannotFindHost:
                throw APIError.server(provider.isLocal
                    ? "\(provider.name.replacingOccurrences(of: " (on this Mac)", with: "")) isn't running on this Mac. Start its server, then try again."
                    : "Couldn't reach \(provider.name) at \(request.url?.host() ?? "that address").")
            default:
                throw APIError.server(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // OpenRouter can report an error inside a 200.
        let error = json["error"]
        guard (200..<300).contains(http.statusCode), error == nil else {
            let detail = (error as? [String: Any])?["message"] as? String ?? error as? String ?? ""
            let code = (error as? [String: Any])?["code"] as? Int
            let status = (200..<300).contains(http.statusCode) ? (code ?? 500) : http.statusCode
            let metadata = (error as? [String: Any])?["metadata"] as? [String: Any]
            let upstream = "\(metadata?["limit_source"] ?? "") \(metadata?["raw"] ?? "")"
            throw Failure(status: status, message: message(status: status, detail: detail, upstream: upstream),
                          detail: detail)
        }
        return json
    }

    private func message(status: Int, detail: String, upstream: String) -> String {
        let name = provider.name
        if provider.id == "opencode-go" {
            // Go is a subscription: 402/429 mean no active plan, or a 5-hour / weekly / monthly limit reached.
            if status == 402 {
                return "This key has no active OpenCode Go subscription. Subscribe at opencode.ai/go, or switch OpenCode to Free in Settings → AI & API keys."
            }
            if status == 429 {
                return "You've reached your OpenCode Go usage limit for now. Wait for it to reset, or switch OpenCode to Free in Settings → AI & API keys."
            }
        }
        switch status {
        case 401, 403:
            return "\(name) rejected that key. Check it in Settings → AI & API keys."
        case 402 where isOpenCode:
            return "That OpenCode model needs credits. Add some at opencode.ai, or choose a free model in Settings → AI & API keys."
        case 429 where isOpenCode:
            return "OpenCode's rate limit was hit. Wait a moment, or pick another model in Settings → AI & API keys."
        case 404 where isOpenCode:
            return "OpenCode doesn't offer \(model) any more. Pick another model in Settings → AI & API keys."
        case 402:
            return isOpenRouter
                ? "That OpenRouter model needs credits. Choose a free model in Settings → AI & API keys."
                : "\(name) says the account is out of credit."
        case 429 where isOpenRouter && upstream.range(of: "upstream", options: .caseInsensitive) != nil:
            // The model's shared free pool is full, not this account's limit.
            return "This free model is busy right now. Try again in a moment, or pick another model in Settings → AI & API keys."
        case 429:
            return isOpenRouter
                ? "You've hit the free AI limit for now (per minute or per day). Wait a bit, or add credits to your OpenRouter account."
                : "\(name) is rate limiting this key. Try again in a moment."
        case 404:
            return "\(name) doesn't know that model or address."
        default:
            if status >= 500 || detail.range(of: "overloaded|temporarily|capacity|try again later",
                                             options: [.regularExpression, .caseInsensitive]) != nil {
                return "\(name) is busy right now. Try again in a moment."
            }
            return detail.isEmpty ? "\(name) request failed (\(status))." : detail
        }
    }
}
