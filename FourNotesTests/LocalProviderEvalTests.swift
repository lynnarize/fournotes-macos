import Foundation
import Testing
@testable import FourNotes

// The OpenAI-compatible path against a real model served on this Mac by
// LM Studio. Off by default, on with:
//
//   TEST_RUNNER_FOURNOTES_EVAL_LOCAL=qwen/qwen3.5-9b ./run-tests.sh
//
// (the value is the model id; the server must be running on port 1234).

private let localModel = ProcessInfo.processInfo.environment["FOURNOTES_EVAL_LOCAL"]

@Suite("Local provider evaluation", .serialized, .enabled(if: localModel != nil))
struct LocalProviderEvalTests {
    private func client() -> OpenAICompatibleClient {
        OpenAICompatibleClient(provider: AIProvider.find("lmstudio")!,
                               baseURL: "http://localhost:1234/v1", apiKey: nil, model: localModel ?? "")
    }

    private func context() -> ClientContext {
        ClientContext(now: DateKit.nowIso(), timezone: TimeZone.current.identifier, currency: "IDR",
                      notes: [.init(title: "Weekend trip ideas", snippet: "Bandung, Bali")],
                      relevantNotes: [],
                      todos: [.init(title: "Book dentist appointment", done: false, doing: nil, dueAt: nil, rrule: nil)],
                      transactions: [], budgets: [:],
                      categories: ["Food & Drink", "Transport", "Groceries", "Income", "Other"])
    }

    private func ask(_ text: String) async throws -> ChatResponse {
        var response = try await client().chat([ChatMessage(role: .user, content: text)], ctx: context())
        // As the app saves it: amounts checked against the message.
        response.actions = Intent.ground(response.actions, in: text)
        print("LOCAL | \(text) | \(response.actions) | \(response.reply.prefix(160))")
        return response
    }

    @Test("a reminder becomes a task")
    func reminder() async throws {
        let r = try await ask("remind me to call mom tomorrow at 7pm")
        #expect(r.actions.contains { if case .createTodo = $0 { true } else { false } })
    }

    @Test("spending is logged")
    func spending() async throws {
        let r = try await ask("coffee 25k at Kopi Kenangan")
        guard case let .addTransaction(_, amount, _, _, _, _, _, _)? = r.actions.first else {
            Issue.record("expected a transaction"); return
        }
        #expect(amount == 25_000)
    }

    @Test("a question is answered, not filed")
    func question() async throws {
        let r = try await ask("what's on my to-do list?")
        #expect(r.actions.isEmpty)
        #expect(r.reply.localizedCaseInsensitiveContains("dentist"))
    }

    @Test("the model list includes the model under test")
    func models() async throws {
        #expect(try await client().listModels().contains(localModel ?? ""))
    }
}
