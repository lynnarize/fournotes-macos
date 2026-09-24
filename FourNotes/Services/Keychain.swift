import Foundation
import Security

// Bring your own API key. On the web these live in localStorage; on the Mac
// they belong in the Keychain, so they are never in the app's JSON document,
// never in a backup, and never synced. Ported from src/lib/byok.ts.

enum Keychain {
    enum Item: String, CaseIterable {
        case anthropicKey, anthropicModel, anthropicFastModel
        case openrouterKey, openrouterModel
        /// The OpenAI-compatible provider: which one, where, which model, and its key.
        case providerId, providerBaseURL, providerModel, providerKey
        /// The model server on this Mac (LM Studio, Ollama).
        case localProviderId, localProviderBaseURL, localProviderModel
        case voyageKey
        case sttKey, sttProvider

        var label: String {
            switch self {
            case .anthropicKey: return "Anthropic key"
            case .anthropicModel: return "Anthropic model"
            case .anthropicFastModel: return "Anthropic fast model"
            case .openrouterKey: return "OpenRouter key"
            case .openrouterModel: return "OpenRouter model"
            case .providerId: return "Provider"
            case .providerBaseURL: return "Provider address"
            case .providerModel: return "Provider model"
            case .providerKey: return "API key"
            case .localProviderId: return "Local model server"
            case .localProviderBaseURL: return "Local server address"
            case .localProviderModel: return "Local model"
            case .voyageKey: return "Voyage key"
            case .sttKey: return "Speech-to-text key"
            case .sttProvider: return "Speech-to-text provider"
            }
        }

        /// Only real secrets are masked in the UI.
        var isSecret: Bool {
            switch self {
            case .anthropicKey, .openrouterKey, .voyageKey, .sttKey, .providerKey: return true
            default: return false
            }
        }
    }

    private static let service = "com.fournotes.mac.keys"

    /// Printable ASCII only (header-safe), no spaces.
    static func isValid(_ v: String?) -> Bool {
        guard let v = v?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return true }
        return v.range(of: "^[\\x21-\\x7e]{16,400}$", options: .regularExpression) != nil
    }

    /// Under the unit tests the app's real Keychain is left alone: the test
    /// build is signed differently, so reading items the app saved raises a
    /// password prompt that stalls the whole run. The opt-in evaluations that
    /// need the user's key say so.
    private static let isolated: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil && env["FOURNOTES_EVAL_OPENROUTER"] == nil
    }()

    // Only secrets live in the Keychain. Which provider, which model and the
    // address are ordinary settings: kept in the Keychain, each was one more
    // item that could make macOS ask for the login password — after every
    // update of an app that isn't signed with a stable developer identity.

    private static func defaultsKey(_ item: Item) -> String { "fournotes.setting.\(item.rawValue)" }
    private static let migratedKey = "fournotes.settings.movedFromKeychain"

    /// Moves settings saved in the Keychain by earlier versions into the
    /// app's preferences, once.
    private static func migrateSettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        for item in Item.allCases where !item.isSecret {
            if let value = readKeychain(item), !value.isEmpty {
                defaults.set(value, forKey: defaultsKey(item))
            }
            deleteKeychain(item)
        }
    }

    static func read(_ item: Item) -> String? {
        if isolated { return nil }
        if !item.isSecret {
            migrateSettings()
            let value = UserDefaults.standard.string(forKey: defaultsKey(item))
            // sttProvider defaults to "openai", matching the web client.
            if item == .sttProvider, value?.isEmpty != false { return "openai" }
            return value
        }
        return readKeychain(item)
    }

    @discardableResult
    static func write(_ item: Item, _ value: String?) -> Bool {
        if isolated { return false }
        let trimmed = value?.trimmingCharacters(in: .whitespaces) ?? ""
        if !item.isSecret {
            migrateSettings()
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: defaultsKey(item))
            } else {
                UserDefaults.standard.set(trimmed, forKey: defaultsKey(item))
            }
            return true
        }
        deleteKeychain(item)
        guard !trimmed.isEmpty else { return true }
        var add = baseQuery(item)
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }

    private static func readKeychain(_ item: Item) -> String? {
        var query = baseQuery(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(_ item: Item) {
        SecItemDelete(baseQuery(item) as CFDictionary)
    }

    static func clearAll() {
        for item in Item.allCases { write(item, nil) }
    }

    static func mask(_ k: String?) -> String {
        guard let k, !k.isEmpty else { return "" }
        return k.count > 16 ? "\(k.prefix(7))…\(k.suffix(4))" : "••••••••"
    }
}
