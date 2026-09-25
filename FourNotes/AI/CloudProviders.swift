import Foundation

// The cloud models, one tab each in Settings → AI & API keys, as on the web
// (src/components/ApiKeysSection.tsx): OpenRouter (Free or Paid), OpenCode
// (Free or Go), Claude, and Other (OpenAI, Groq, Gemini, any OpenAI-compatible
// endpoint). Each keeps its own key, so switching between them loses nothing.
// With several set up, the one picked in Settings is asked first, then Claude,
// OpenCode, OpenRouter and Other — the web app's order.

enum CloudProviders {
    enum Tab: String, CaseIterable, Identifiable {
        case openrouter, opencode, anthropic, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .openrouter: return "OpenRouter"
            case .opencode: return "OpenCode"
            case .anthropic: return "Claude"
            case .other: return "Other"
            }
        }
    }

    /// The order they are asked in when none is picked.
    private static let defaultOrder: [Tab] = [.anthropic, .opencode, .openrouter, .other]

    /// The tab picked to answer first, if any.
    static var preferred: Tab? { Keychain.read(.cloudProvider).flatMap(Tab.init) }

    static func prefer(_ tab: Tab) { Keychain.write(.cloudProvider, tab.rawValue) }

    /// `ready` in the order they are asked: the picked one first.
    static func ordered(_ ready: [Tab], preferred: Tab? = preferred) -> [Tab] {
        let rest = defaultOrder.filter { $0 != preferred && ready.contains($0) }
        return (preferred.map { ready.contains($0) ? [$0] : [] } ?? []) + rest
    }

    static func hasKey(_ tab: Tab) -> Bool {
        switch tab {
        case .openrouter: return key(.openrouterKey) != nil
        case .opencode: return key(.opencodeKey) != nil
        case .anthropic: return key(.anthropicKey) != nil
        case .other: return key(.providerKey) != nil || AIProvider.find(Keychain.read(.providerId))?.needsKey == false
        }
    }

    // MARK: - OpenRouter

    static var openRouterPaid: Bool { Keychain.read(.openrouterTier) == "paid" }

    /// The model OpenRouter requests use: the paid pick, or a tested free one.
    static var openRouterModel: String {
        if openRouterPaid, let paid = Keychain.read(.openrouterPaidModel), OpenRouterModels.isModelId(paid) {
            return paid
        }
        let free = Keychain.read(.openrouterModel)
        return OpenRouterModels.free.contains { $0.id == free } ? free! : OpenRouterModels.defaultModel
    }

    static func openRouter() -> OpenAICompatibleClient? {
        guard let key = key(.openrouterKey), let provider = AIProvider.find("openrouter") else { return nil }
        let model = openRouterModel
        let free = OpenRouterModels.isFree(model)
        return OpenAICompatibleClient(
            provider: provider, baseURL: provider.baseURL, apiKey: key, model: model,
            // A free model writes the brief and review with the tested fast one;
            // paid means leaving the free limits behind, so it does everything.
            fastModel: free ? OpenRouterModels.fastModel : nil,
            // A text-only paid model hands photos to the tested free one that can see.
            visionModel: !free && Keychain.read(.openrouterPaidTextOnly) == "1"
                ? OpenRouterModels.defaultVisionModel : nil)
    }

    // MARK: - OpenCode

    static var openCodeTier: OpenCodeModels.Tier {
        Keychain.read(.opencodeTier) == OpenCodeModels.Tier.go.rawValue ? .go : .free
    }

    static var openCodeModel: String {
        let tier = openCodeTier
        return OpenCodeModels.resolve(Keychain.read(tier == .go ? .opencodeGoModel : .opencodeModel), tier: tier)
    }

    static func openCode() -> OpenAICompatibleClient? {
        let tier = openCodeTier
        guard let key = key(.opencodeKey), let provider = AIProvider.find(tier.providerId) else { return nil }
        let model = openCodeModel
        return OpenAICompatibleClient(provider: provider, baseURL: provider.baseURL, apiKey: key, model: model,
                                      visionModel: OpenCodeModels.vision(for: model, tier: tier))
    }

    // MARK: - Moving earlier settings

    private static let migratedKey = "fournotes.settings.cloudTabs"

    /// Before the tabs, OpenRouter was one choice in the single cloud slot,
    /// with its key in the slot's key. Moves it to the OpenRouter tab, once.
    /// Whatever was chosen stays the one asked first.
    static func migrate() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard let chosen = Keychain.read(.providerId), !chosen.isEmpty else { return }
        guard chosen == "openrouter" else {
            // OpenAI, Groq…: now the Other tab. Asked before an OpenRouter key
            // left over from the old Four Notes server, as it was before.
            prefer(.other)
            return
        }
        if key(.openrouterKey) == nil, let old = key(.providerKey) { Keychain.write(.openrouterKey, old) }
        if let model = Keychain.read(.providerModel), !model.isEmpty {
            if OpenRouterModels.isFree(model) {
                Keychain.write(.openrouterModel, model)
            } else if OpenRouterModels.isModelId(model) {
                Keychain.write(.openrouterTier, "paid")
                Keychain.write(.openrouterPaidModel, model)
            }
        }
        for item in [Keychain.Item.providerId, .providerBaseURL, .providerModel, .providerKey] {
            Keychain.write(item, nil)
        }
        prefer(.openrouter)
    }

    private static func key(_ item: Keychain.Item) -> String? {
        Keychain.read(item).flatMap { Keychain.isValid($0) && !$0.isEmpty ? $0 : nil }
    }
}
