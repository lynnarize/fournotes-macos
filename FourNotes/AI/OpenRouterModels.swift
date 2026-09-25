import Foundation

// OpenRouter's free models that passed the web app's probe (`npm run
// probe:models`: real tool calls, forced capture, and a receipt photo for the
// vision ones). The list is the web app's own verified-models.json, copied
// into the app, so re-running the probe and copying the file updates both.
// Ported from src/lib/ai/models.ts.

enum OpenRouterModels {
    struct FreeModel: Identifiable, Equatable {
        var id: String
        var label: String
        var vision: Bool
        var verified: Bool

        /// "Ling 3.0 Flash VL · free, reads photos"
        var menuLabel: String { "\(label) · free\(vision ? ", reads photos" : "")" }
    }

    /// OpenRouter's Free Models Router. Never offered as a choice — it can land
    /// on a model that writes about calling a tool instead of calling it — only
    /// the last fallback.
    static let autoModel = "openrouter/free"

    private struct File: Decodable {
        struct Model: Decodable { var id: String; var label: String; var vision: Bool; var verified: Bool }
        var checkedAt: String?
        var fast: String?
        var models: [Model]
    }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "verified-models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    /// In order of preference; the first is the default.
    static let free: [FreeModel] = (file?.models ?? []).map {
        FreeModel(id: $0.id, label: $0.label, vision: $0.vision, verified: $0.verified)
    }

    static var checkedAt: Date? { file?.checkedAt.flatMap(DateKit.date) }

    static var defaultModel: String { free.first?.id ?? autoModel }
    /// For the brief and the monthly review.
    static var fastModel: String { file?.fast ?? defaultModel }
    static var defaultVisionModel: String { free.first(where: \.vision)?.id ?? autoModel }

    /// Models that can never spend credits.
    static func isFree(_ id: String) -> Bool { id == autoModel || id.hasSuffix(":free") }

    /// Unknown paid models are assumed to handle images; unlisted free ones aren't.
    static func supportsVision(_ id: String) -> Bool {
        if id == autoModel { return true }
        if let known = free.first(where: { $0.id == id }) { return known.vision }
        return !isFree(id)
    }

    /// Photos need a model that can see; otherwise the tested free vision model.
    static func visionModel(for id: String) -> String {
        supportsVision(id) ? id : defaultVisionModel
    }

    // MARK: - Paid

    static let keysPage = "https://openrouter.ai/keys"
    static let creditsPage = "https://openrouter.ai/settings/credits"

    /// A paid model offered in Settings, from OpenRouter's live list.
    struct PaidModel: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var vision: Bool
        var context: Int
        /// USD per token.
        var prompt: Double
        var completion: Double

        /// "Claude Sonnet 5 · $3 in / $15 out · reads photos"
        var menuLabel: String {
            "\(name) · \(perMillion(prompt)) in / \(perMillion(completion)) out\(vision ? " · reads photos" : "")"
        }
    }

    /// An OpenRouter slug like "anthropic/claude-sonnet-5". Paid models are typed freely, so check the shape.
    static func isModelId(_ id: String?) -> Bool {
        guard let id, id.count <= 120 else { return false }
        return id.range(of: #"^~?[a-z0-9][\w.-]*/[a-z0-9][\w.:-]*$"#,
                        options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// USD per 1M tokens, for display.
    static func perMillion(_ usdPerToken: Double) -> String {
        let v = usdPerToken * 1e6
        if v < 1 {
            var s = String(format: "%.2f", v)
            if s.hasSuffix("0") { s.removeLast() }
            return "$" + s
        }
        return v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    /// OpenRouter's paid models that can call tools (the app files to-dos and
    /// transactions through tool calls). A public list: no key needed.
    /// Ported from the web app's /api/ai/openrouter-models.
    static func paid() async throws -> [PaidModel] {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }
        let price = { (v: Any?) in Double(v as? String ?? "") ?? (v as? Double) ?? 0 }
        return (json["data"] as? [[String: Any]] ?? []).compactMap { m -> PaidModel? in
            guard let id = m["id"] as? String,
                  (m["supported_parameters"] as? [String])?.contains("tools") == true,
                  // ":free" is the free tier, ":batch" isn't for live replies.
                  id.range(of: #":(free|batch)$"#, options: .regularExpression) == nil else { return nil }
            let pricing = m["pricing"] as? [String: Any]
            let prompt = price(pricing?["prompt"]), completion = price(pricing?["completion"])
            // Negative prices mark routers with variable pricing.
            guard prompt >= 0, completion >= 0, prompt + completion > 0 else { return nil }
            let modalities = (m["architecture"] as? [String: Any])?["input_modalities"] as? [String] ?? []
            return PaidModel(id: id, name: m["name"] as? String ?? id, vision: modalities.contains("image"),
                             context: m["context_length"] as? Int ?? 0, prompt: prompt, completion: completion)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Models to try, in order, for one request (OpenRouter's `models`
    /// fallback): the chosen one, another tested one, then the router. A paid,
    /// user-chosen model is never swapped behind their back. Kept to three:
    /// longer lists are rejected on some endpoints.
    static func fallbackChain(_ primary: String, vision: Bool = false) -> [String] {
        guard isFree(primary) else { return [primary] }
        var chain: [String] = []
        for id in [primary] + free.filter({ !vision || $0.vision }).map(\.id)
        where id != autoModel && !chain.contains(id) {
            chain.append(id)
        }
        return Array(chain.prefix(2)) + [autoModel]
    }
}
