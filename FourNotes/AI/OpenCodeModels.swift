import Foundation

// OpenCode models this app can call (chat-completions format only; the others
// there use the Messages or Responses APIs). OpenCode is a coding agent, so all
// of them call tools. One OpenCode key, two tiers:
//   Free — OpenCode Zen's free models. They may log prompts to improve the model.
//   Go   — a $10/month subscription with 5-hour, weekly and monthly usage
//          limits. List: https://opencode.ai/docs/go/
// Ported from the web app's src/lib/ai/models.ts.

enum OpenCodeModels {
    struct Model: Identifiable, Equatable {
        var id: String
        var label: String
        var vision: Bool

        var menuLabel: String { label + (vision ? " · reads photos" : "") }
    }

    enum Tier: String, CaseIterable {
        case free
        case go = "paid"

        var providerId: String { self == .go ? "opencode-go" : "opencode" }
    }

    static let free: [Model] = [
        Model(id: "big-pickle", label: "Big Pickle", vision: false),
        Model(id: "ling-3.0-flash-fin-free", label: "Ling 3.0 Flash Fin", vision: false),
        Model(id: "mimo-v2.6-flash-free", label: "MiMo V2.6 Flash", vision: false),
        Model(id: "nemotron-3-ultra-free", label: "Nemotron 3 Ultra", vision: false),
        Model(id: "nemotron-3.5-lightning-free", label: "Nemotron 3.5 Lightning", vision: false),
    ]

    static let go: [Model] = [
        Model(id: "kimi-k3", label: "Kimi K3", vision: false),
        Model(id: "kimi-k2.6", label: "Kimi K2.6", vision: false),
        Model(id: "glm-5.3", label: "GLM 5.3", vision: false),
        Model(id: "glm-5.3-flash", label: "GLM 5.3 Flash", vision: false),
        Model(id: "deepseek-v4-pro", label: "DeepSeek V4 Pro", vision: false),
        Model(id: "deepseek-v4.1-flash", label: "DeepSeek V4.1 Flash", vision: false),
        Model(id: "deepseek-v4-flash-vision-exp", label: "DeepSeek V4 Flash Vision (experimental)", vision: true),
        Model(id: "mimo-v2.6-pro", label: "MiMo V2.6 Pro", vision: false),
        Model(id: "mimo-v2.6-flash", label: "MiMo V2.6 Flash", vision: false),
        Model(id: "longcat-2.0", label: "LongCat 2.0", vision: false),
    ]

    static let defaultFree = "big-pickle"
    static let defaultGo = "kimi-k3"
    /// Photos need a model that can see: on Go it's part of the plan, on Free it needs a Zen balance.
    static let visionModel = "deepseek-v4-flash-vision-exp"
    static let keysPage = "https://opencode.ai/auth"
    static let goPage = "https://opencode.ai/go"
    /// OpenCode asks clients to name themselves rather than send a generic user agent.
    static var userAgent: String { "FourNotes/\(AppVersion.marketing) (+https://app.fournotes.xyz)" }

    static func models(_ tier: Tier) -> [Model] { tier == .go ? go : free }
    static func defaultModel(_ tier: Tier) -> String { tier == .go ? defaultGo : defaultFree }

    /// A listed model, or the tier's default: a model saved before it was withdrawn falls back.
    static func resolve(_ id: String?, tier: Tier) -> String {
        models(tier).contains { $0.id == id } ? id! : defaultModel(tier)
    }

    static func label(_ id: String?, tier: Tier) -> String {
        let list = models(tier)
        return list.first { $0.id == id }?.label ?? list.first { $0.id == defaultModel(tier) }?.label ?? id ?? ""
    }

    static func vision(for id: String, tier: Tier) -> String {
        models(tier).first { $0.id == id }?.vision == true ? id : visionModel
    }
}
