import Foundation

// The tool (function) schemas given to the model, loaded from tools.json —
// which is generated from src/lib/ai/tools.ts, so the two apps describe the
// same tools with the same wording.

enum AITools {
    private struct Loaded {
        var actions: [[String: Any]]
        var capture: [String: Any]
    }

    // Read once from the app bundle at first use and never mutated after.
    nonisolated(unsafe) private static let loaded: Loaded = {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let actions = json["actions"] as? [[String: Any]],
              let capture = json["capture"] as? [String: Any] else {
            NSLog("Four Notes: tools.json is missing from the app bundle")
            return Loaded(actions: [], capture: [:])
        }
        return Loaded(actions: actions, capture: capture)
    }()

    static var actionTools: [[String: Any]] { loaded.actions }
    static var captureTool: [String: Any] { loaded.capture }

    /// The tool list with a cache breakpoint on the last entry: the definitions
    /// are identical on every request, so Claude can cache them.
    nonisolated(unsafe) static let cachedActionTools: [[String: Any]] = {
        var tools = loaded.actions
        guard !tools.isEmpty else { return tools }
        tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
        return tools
    }()

    /// Turns raw `tool_use` inputs into validated app actions. Anything the app
    /// does not recognise is dropped rather than failing the whole reply — the
    /// same rule as validateActions() in the web app.
    static func decodeActions(_ raw: [[String: Any]]) -> [AIAction] {
        // Per item, not per batch: one unreadable action used to discard every
        // action the model produced, while the reply still said it had saved
        // them.
        raw.compactMap { item in
            let clean = sanitised(item)
            // JSONSerialization raises an Objective-C exception on a non-finite
            // number — one that `try?` cannot catch and that takes the process
            // with it. Ask first.
            guard JSONSerialization.isValidJSONObject(clean),
                  let data = try? JSONSerialization.data(withJSONObject: clean) else { return nil }
            return try? JSONDecoder().decode(AIAction.self, from: data)
        }
    }

    /// Replaces values JSON cannot represent. A model that answers `NaN` for an
    /// amount should cost that field, not the reply and not the process.
    private static func sanitised(_ value: Any) -> Any {
        switch value {
        case let number as Double:
            return number.isFinite ? number : 0
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? number : NSNumber(value: 0)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(sanitised)
        case let array as [Any]:
            return array.map(sanitised)
        default:
            return value
        }
    }
}
