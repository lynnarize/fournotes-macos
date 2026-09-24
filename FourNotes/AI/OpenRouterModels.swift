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
