import Foundation
import Testing
@testable import FourNotes

// The OpenAI-compatible client against a stubbed endpoint: the request it
// sends, and the actions it reads back from function calls.

final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [[String: Any]] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        // URLSession moves the body into a stream; keep it readable.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            captured.httpBody = data
        }
        Self.requests.append(captured)
        let body = Self.responses.isEmpty ? [:] : Self.responses.removeFirst()
        let data = try! JSONSerialization.data(withJSONObject: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("OpenAI-compatible provider", .serialized)
struct OpenAICompatibleTests {
    private func client() -> OpenAICompatibleClient {
        OpenAICompatibleClient(provider: AIProvider.find("custom")!, baseURL: "https://stub.test/v1/",
                               apiKey: "sk-test", model: "test-model")
    }

    private func context() -> ClientContext {
        ClientContext(now: DateKit.nowIso(), timezone: "Asia/Jakarta", currency: "IDR", notes: [],
                      relevantNotes: [], todos: [], transactions: [], budgets: [:],
                      categories: ["Food & Drink", "Other"])
    }

    @Test("Claude's tool definitions become functions")
    func functions() {
        let converted = OpenAICompatibleClient.functions([
            ["name": "create_note", "description": "Save a note",
             "input_schema": ["type": "object", "properties": ["title": ["type": "string"]]]],
        ])
        let function = converted.first?["function"] as? [String: Any]
        #expect(converted.first?["type"] as? String == "function")
        #expect(function?["name"] as? String == "create_note")
        #expect((function?["parameters"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test("a function call is filed, and the conversation goes back to finish")
    func chatWithToolCall() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = [
            ["choices": [["message": [
                "role": "assistant", "content": NSNull(),
                "tool_calls": [["id": "call_1", "type": "function",
                                "function": ["name": "create_note",
                                             "arguments": #"{"title":"Trip","content":"Bandung, Bali"}"#]]],
            ]]]],
            ["choices": [["message": ["role": "assistant", "content": "Saved your note."]]]],
        ]

        let response = try await client().chat([ChatMessage(role: .user, content: "note: trip, Bandung, Bali")],
                                               ctx: context())

        #expect(response.reply == "Saved your note.")
        guard case let .createNote(title, content, _, _)? = response.actions.first else {
            Issue.record("expected a note, got \(response.actions)"); return
        }
        #expect(title == "Trip")
        #expect(content == "Bandung, Bali")

        let first = try #require(StubProtocol.requests.first)
        #expect(first.url?.absoluteString == "https://stub.test/v1/chat/completions")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(first.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["model"] as? String == "test-model")
        #expect((body["tools"] as? [Any])?.isEmpty == false)

        // The second request carries the tool result for call_1.
        let second = try #require(StubProtocol.requests.last?.httpBody
            .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let messages = second["messages"] as? [[String: Any]] ?? []
        #expect(messages.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "call_1" })
    }

    @Test("the model list comes from /models")
    func models() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = [["data": [["id": "b-model"], ["id": "a-model"]]]]
        #expect(try await client().listModels() == ["a-model", "b-model"])
        #expect(StubProtocol.requests.first?.url?.absoluteString == "https://stub.test/v1/models")
    }

    @Test("a model that describes a tool call is asked again, and must call it")
    func planningRetry() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = [
            ["choices": [["message": ["role": "assistant", "content": "I will call create_note with title Trip."]]]],
            ["choices": [["message": [
                "role": "assistant", "content": "",
                "tool_calls": [["id": "c1", "type": "function",
                                "function": ["name": "create_note", "arguments": #"{"title":"Trip","content":"Bali"}"#]]],
            ]]]],
            ["choices": [["message": ["role": "assistant", "content": "<think>done</think>"]]]],
        ]
        let response = try await client().chat([ChatMessage(role: .user, content: "note: trip to Bali")], ctx: context())
        #expect(response.actions.count == 1)
        // The planning text is never shown; the reply is built from what was saved.
        #expect(response.reply == "Done: 1 note.")
        let second = try #require(StubProtocol.requests.dropFirst().first?.httpBody
            .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(second["tool_choice"] as? String == "required")
    }

    @Test("on OpenRouter, free models get the tested fallbacks and tool-capable providers")
    func openRouterBody() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = [["choices": [["message": ["role": "assistant", "content": "Hi!"]]]]]
        let router = OpenAICompatibleClient(provider: AIProvider.find("openrouter")!, baseURL: "https://stub.test/api/v1",
                                            apiKey: "sk-or", model: OpenRouterModels.defaultModel)
        _ = try await router.chat([ChatMessage(role: .user, content: "hello")], ctx: context())
        let body = try #require(StubProtocol.requests.first?.httpBody
            .flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["provider"] as? [String: Any])?["require_parameters"] as? Bool == true)
        #expect((body["models"] as? [String])?.last == OpenRouterModels.autoModel)
        #expect(StubProtocol.requests.first?.value(forHTTPHeaderField: "X-Title") == "Four Notes")
    }

    @Test("on OpenCode, the app names itself and keeps one session per conversation")
    func openCodeHeaders() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = Array(repeating: ["choices": [["message": ["role": "assistant", "content": "Hi!"]]]],
                                       count: 3)
        let go = OpenAICompatibleClient(provider: AIProvider.find("opencode-go")!, baseURL: "https://stub.test/zen/go/v1",
                                        apiKey: "sk-oc", model: "kimi-k3")
        let opening = ChatMessage(role: .user, content: "hello")
        _ = try await go.chat([opening], ctx: context())
        _ = try await go.chat([opening, ChatMessage(role: .assistant, content: "Hi!"),
                               ChatMessage(role: .user, content: "and again")], ctx: context())
        _ = try await go.chat([ChatMessage(role: .user, content: "another chat")], ctx: context())

        let sessions = StubProtocol.requests.map { $0.value(forHTTPHeaderField: "x-opencode-session") }
        #expect(sessions.allSatisfy { $0?.count == 32 })
        #expect(sessions[0] == sessions[1])
        #expect(sessions[1] != sessions[2])
        let first = try #require(StubProtocol.requests.first)
        #expect(first.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("FourNotes/") == true)
        #expect(first.value(forHTTPHeaderField: "X-Title") == nil)
        let body = try #require(first.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(body["models"] == nil)
        #expect(body["max_tokens"] as? Int == 2048)
        // The chat prompt carries the assistant's limits.
        let system = (body["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
        #expect(system.contains("SCOPE"))
    }

    @Test("a capture sent back as JSON in prose is still filed")
    func captureFromJSONText() async throws {
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        StubProtocol.requests = []
        StubProtocol.responses = [["choices": [["message": [
            "role": "assistant",
            "content": "Here you go:\n```json\n{\"kind\":\"receipt\",\"reply\":\"Logged\",\"receipt\":{\"merchant\":\"Kopi Kenangan\",\"total\":25000,\"category\":\"Food & Drink\"}}\n```",
        ]]]]]
        let result = try await client().captureText("KOPI KENANGAN TOTAL 25.000", ctx: context())
        #expect(result.kind == .receipt)
        guard case let .addTransaction(merchant, amount, _, _, _, _, _, _)? = result.actions.first else {
            Issue.record("expected a transaction, got \(result.actions)"); return
        }
        #expect(merchant == "Kopi Kenangan")
        #expect(amount == 25_000)
    }
}

@Suite("Where a model runs")
struct ThisMacTests {
    @Test("only an address on this Mac counts as local")
    func local() {
        #expect(OpenAICompatibleClient.isThisMac("http://localhost:1234/v1"))
        #expect(OpenAICompatibleClient.isThisMac("http://127.0.0.1:11434/v1"))
        #expect(!OpenAICompatibleClient.isThisMac("http://192.168.1.20:1234/v1"))
        #expect(!OpenAICompatibleClient.isThisMac("https://openrouter.ai/api/v1"))
        #expect(!OpenAICompatibleClient.isThisMac("http://localhost.evil.com/v1"))
    }
}
