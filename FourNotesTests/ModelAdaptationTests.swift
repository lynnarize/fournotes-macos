import Foundation
import Testing
@testable import FourNotes

// The web app's handling of free and open models, ported: each case is
// something a real model did (see src/lib/ai/text.ts and openrouter.ts).

@Suite("Model text clean-up")
struct ModelTextTests {
    @Test("thinking is stripped, tagged or left open")
    func clean() {
        #expect(ModelText.clean("<think>plan it</think>Saved.") == "Saved.")
        #expect(ModelText.clean("stray reasoning</think>Saved.") == "Saved.")
        #expect(ModelText.clean("Saved.<think>and then") == "Saved.")
    }

    @Test("working-out is recognised as such")
    func thinking() {
        #expect(ModelText.looksLikeThinking("Here's a thinking process: 1. Analyze the request"))
        #expect(ModelText.looksLikeThinking("The user wants a brief."))
        #expect(!ModelText.looksLikeThinking("Added “Call mom” to To-Do."))
        #expect(ModelText.looksLikePlanning("I will call create_todo with dueAt tomorrow"))
        #expect(!ModelText.looksLikePlanning("Added it for tomorrow."))
    }

    @Test("only the final answer is kept")
    func answer() {
        #expect(ModelText.extractAnswer("draft…<answer>one</answer> then <answer>two</answer>") == "two")
        #expect(ModelText.extractAnswer("no tags") == "no tags")
    }

    @Test("a brief is three emoji lines, the last three")
    func brief() {
        let text = "Let me draft the brief.\n🎯 Pay rent\n💸 Spent Rp 30,000\n📌 Andi owes you\n"
        #expect(ModelText.briefLines(text) == ["🎯 Pay rent", "💸 Spent Rp 30,000", "📌 Andi owes you"])
        #expect(ModelText.briefLines("Just one line") == nil)
    }

    @Test("JSON is read out of prose and fences")
    func json() {
        #expect(ModelText.json(#"{"kind":"receipt"}"#)?["kind"] as? String == "receipt")
        #expect(ModelText.json("Sure!\n```json\n{\"kind\":\"note\"}\n```")?["kind"] as? String == "note")
        #expect(ModelText.json("no json here") == nil)
    }

    @Test("union types are simplified for strict parsers")
    func schema() {
        let out = ModelText.simplifySchema(["type": "object",
                                            "properties": ["dueAt": ["type": ["string", "null"]]]]) as? [String: Any]
        let due = (out?["properties"] as? [String: Any])?["dueAt"] as? [String: Any]
        #expect(due?["type"] as? String == "string")
    }

    @Test("the data-only brief has three lines")
    func localBrief() {
        let input = BriefInput(now: DateKit.nowIso(), timezone: "Asia/Jakarta", currency: "IDR", name: nil,
                               tasksToday: [.init(title: "Pay rent", dueAt: nil, overdue: true)],
                               yesterdaySpend: [.init(merchant: "Warteg", amount: 30_000, category: "Food & Drink")],
                               stickies: [], alerts: ["Andi owes you Rp 30,000"])
        let lines = LocalSummaries.brief(input).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("Pay rent"))
        #expect(ModelText.briefLines(LocalSummaries.brief(input)) != nil)
    }
}

@Suite("OpenRouter models")
struct OpenRouterModelsTests {
    @Test("the verified list ships with the app, Ling first")
    func list() {
        #expect(!OpenRouterModels.free.isEmpty)
        #expect(OpenRouterModels.defaultModel.hasPrefix("inclusionai/ling"))
        #expect(OpenRouterModels.supportsVision(OpenRouterModels.defaultVisionModel))
    }

    @Test("free models fall back down the tested list, paid ones never")
    func chain() {
        let chain = OpenRouterModels.fallbackChain(OpenRouterModels.defaultModel)
        #expect(chain.first == OpenRouterModels.defaultModel)
        #expect(chain.last == OpenRouterModels.autoModel)
        #expect(chain.count <= 3)
        #expect(OpenRouterModels.fallbackChain("openai/gpt-4o") == ["openai/gpt-4o"])
        // A photo only goes to models that can see.
        let vision = OpenRouterModels.fallbackChain(OpenRouterModels.defaultModel, vision: true)
        #expect(vision.dropFirst().dropLast().allSatisfy { OpenRouterModels.supportsVision($0) })
    }

    @Test("photos go to a model that can see")
    func vision() {
        let textOnly = OpenRouterModels.free.first { !$0.vision }?.id ?? "x/text-only:free"
        #expect(OpenRouterModels.visionModel(for: textOnly) == OpenRouterModels.defaultVisionModel)
        #expect(OpenRouterModels.visionModel(for: "openai/gpt-4o") == "openai/gpt-4o")
    }
}
