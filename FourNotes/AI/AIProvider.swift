import Foundation

// The AI providers that speak OpenAI's chat-completions API — OpenRouter,
// OpenAI, Groq, Gemini, a local Ollama, or any other endpoint with the same
// shape. The choice, address and model are settings; the key is a secret and
// lives in the Keychain like the Anthropic one.

struct AIProvider: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    /// Where to get a key, if the provider needs one.
    var keyPage: String?
    var modelHint: String

    /// Runs on this Mac: no key, and plain http to localhost.
    var isLocal: Bool { baseURL.hasPrefix("http://localhost") }
    var needsKey: Bool { !isLocal && id != "custom" }
    var slot: Slot { isLocal ? .local : .cloud }

    /// "LM Studio", not "LM Studio (on this Mac)"; for "Ask …" buttons.
    var shortName: String {
        id == "custom" ? "the cloud model" : name.replacingOccurrences(of: " (on this Mac)", with: "")
    }

    /// Where a provider is set up: one model server on this Mac, one in the cloud.
    enum Slot: Sendable {
        case local, cloud

        var idItem: Keychain.Item { self == .local ? .localProviderId : .providerId }
        var baseURLItem: Keychain.Item { self == .local ? .localProviderBaseURL : .providerBaseURL }
        var modelItem: Keychain.Item { self == .local ? .localProviderModel : .providerModel }
        /// Local servers take no key.
        var keyItem: Keychain.Item? { self == .local ? nil : .providerKey }
    }

    static let all: [AIProvider] = [
        AIProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                   keyPage: "https://openrouter.ai/keys", modelHint: "A tested free model, or any model id"),
        AIProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                   keyPage: "https://platform.openai.com/api-keys", modelHint: "e.g. gpt-4o-mini"),
        AIProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                   keyPage: "https://console.groq.com/keys", modelHint: "e.g. llama-3.3-70b-versatile"),
        AIProvider(id: "gemini", name: "Google Gemini",
                   baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                   keyPage: "https://aistudio.google.com/apikey", modelHint: "e.g. gemini-2.5-flash"),
        AIProvider(id: "ollama", name: "Ollama (on this Mac)", baseURL: "http://localhost:11434/v1",
                   keyPage: nil, modelHint: "e.g. llama3.2"),
        AIProvider(id: "lmstudio", name: "LM Studio (on this Mac)", baseURL: "http://localhost:1234/v1",
                   keyPage: nil, modelHint: "e.g. qwen/qwen3.5-9b"),
        AIProvider(id: "custom", name: "Other (OpenAI-compatible)", baseURL: "",
                   keyPage: nil, modelHint: "The model id your endpoint expects"),
    ]

    static func find(_ id: String?) -> AIProvider? { all.first { $0.id == id } }
    static func all(in slot: Slot) -> [AIProvider] { all.filter { $0.slot == slot } }
}
