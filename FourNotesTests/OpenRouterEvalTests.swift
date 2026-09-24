import AppKit
import Foundation
import Testing
@testable import FourNotes

// The OpenRouter path against the real service, with the key saved in this
// Mac's Keychain (it is read here, never passed on the command line). Off by
// default — free models allow about 50 requests a day — on with:
//
//   TEST_RUNNER_FOURNOTES_EVAL_OPENROUTER=inclusionai/ling-3.0-flash-fin:free ./run-tests.sh
//
// About ten requests per run.

private let routerModel = ProcessInfo.processInfo.environment["FOURNOTES_EVAL_OPENROUTER"]

@Suite("OpenRouter evaluation", .serialized, .enabled(if: routerModel != nil))
struct OpenRouterEvalTests {
    private func client() throws -> OpenAICompatibleClient {
        let saved: String? = Keychain.read(.providerKey)
        let key: String? = (saved?.isEmpty == false) ? saved : Keychain.read(.openrouterKey)
        guard let key, !key.isEmpty else { throw APIError.server("No OpenRouter key in the Keychain.") }
        let model = routerModel ?? OpenRouterModels.defaultModel
        return OpenAICompatibleClient(provider: AIProvider.find("openrouter")!,
                                      baseURL: "https://openrouter.ai/api/v1",
                                      apiKey: key,
                                      model: model,
                                      fastModel: OpenRouterModels.isFree(model) ? OpenRouterModels.fastModel : nil)
    }

    private func context() -> ClientContext {
        ClientContext(now: DateKit.nowIso(), timezone: TimeZone.current.identifier, currency: "IDR",
                      notes: [.init(title: "Weekend trip ideas", snippet: "Bandung, Bali")],
                      relevantNotes: [],
                      todos: [.init(title: "Book dentist appointment", done: false, doing: nil, dueAt: nil, rrule: nil)],
                      transactions: [.init(merchant: "Warteg Bahari", amount: 30000, category: "Food & Drink",
                                           date: DateKit.localDate())],
                      budgets: [:],
                      categories: ["Food & Drink", "Transport", "Groceries", "Bills & Utilities", "Income", "Other"])
    }

    private func ask(_ text: String) async throws -> ChatResponse {
        var response = try await client().chat([ChatMessage(role: .user, content: text)], ctx: context())
        response.actions = Intent.ground(response.actions, in: text)
        print("ROUTER | \(text) | \(response.actions) | \(response.reply.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))")
        return response
    }

    @Test("a reminder becomes a task")
    func reminder() async throws {
        let r = try await ask("remind me to call mom tomorrow at 7pm")
        #expect(r.actions.contains { if case .createTodo = $0 { true } else { false } })
    }

    @Test("spending is logged at the amount typed")
    func spending() async throws {
        let r = try await ask("coffee 25k at Kopi Kenangan")
        guard case let .addTransaction(_, amount, _, category, _, _, _, _)? = r.actions.first else {
            Issue.record("expected a transaction"); return
        }
        #expect(amount == 25_000)
        #expect(category == "Food & Drink")
    }

    @Test("a question is answered, not filed")
    func question() async throws {
        let r = try await ask("what's on my to-do list?")
        #expect(r.actions.isEmpty)
        #expect(r.reply.localizedCaseInsensitiveContains("dentist"))
    }

    @Test("a receipt read on-device is filed with its total")
    func receiptText() async throws {
        let result = try await client().captureText("""
            KOPI KENANGAN
            Grand Indonesia
            Kopi Kenangan Mantan  1 x 25.000
            Roti Bakar            1 x 18.000
            TOTAL                 43.000
            23/09/2026
            """, ctx: context())
        print("ROUTER | receipt text | \(result.kind) | \(result.actions)")
        #expect(result.kind == .receipt)
        guard case let .addTransaction(_, amount, _, _, _, _, _, _)? = result.actions.first(where: {
            if case .addTransaction = $0 { true } else { false }
        }) else { Issue.record("expected a transaction"); return }
        #expect(amount == 43_000)
    }

    @Test("a receipt photo goes to a model that can see")
    func receiptPhoto() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/probe-receipt.jpg")
        let jpeg = try Data(contentsOf: url)
        let result = try await client().captureImage(jpeg, ctx: context())
        print("ROUTER | receipt photo | \(result.kind) | \(result.actions)")
        #expect(result.kind == .receipt)
        #expect(result.actions.contains { if case .addTransaction = $0 { true } else { false } })
    }

    @Test("the brief is three usable lines")
    func brief() async throws {
        let input = BriefInput(now: DateKit.nowIso(), timezone: TimeZone.current.identifier, currency: "IDR",
                               name: "Lynn",
                               tasksToday: [.init(title: "Pay rent", dueAt: nil, overdue: true)],
                               yesterdaySpend: [.init(merchant: "Warteg", amount: 30_000, category: "Food & Drink")],
                               stickies: [], alerts: ["Andi still owes you Rp 30,000"])
        let text = try await client().dailyBrief(input)
        print("ROUTER | brief | \(text.replacingOccurrences(of: "\n", with: " ⏎ "))")
        #expect(ModelText.briefLines(text)?.count == 3)
        // Worth knowing whether the model wrote it or the data-only fallback did.
        print("ROUTER | brief written by \(text == LocalSummaries.brief(input) ? "the data-only fallback" : "the model")")
    }

    @Test("asked which model it is, it says")
    func identity() async throws {
        let r = try await client().chat([ChatMessage(role: .user, content: "what model are you")], ctx: context(),
                                        tools: !Intent.answerOnly("what model are you"))
        print("ROUTER | what model are you | \(r.reply.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(200))")
        #expect(r.actions.isEmpty)
        #expect(r.reply != "Done!")
        #expect(r.reply.localizedCaseInsensitiveContains("ling") || r.reply.localizedCaseInsensitiveContains("OpenRouter"))
    }

    @Test("a recommendation request is answered, and nothing is filed")
    func itinerary() async throws {
        let text = "recommend itinery on bandung"
        let r = try await client().chat([ChatMessage(role: .user, content: text)], ctx: context(),
                                        tools: !Intent.answerOnly(text))
        print("ROUTER | \(text) | \(r.actions) | \(r.reply.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(240))")
        #expect(r.actions.isEmpty)
        #expect(!r.reply.localizedCaseInsensitiveContains("can't provide"))
        #expect(r.reply.count > 120)
    }
}
