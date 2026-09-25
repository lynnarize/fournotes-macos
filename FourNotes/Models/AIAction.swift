import Foundation

// Actions the AI can ask the client to apply (src/lib/types.ts).
// The server returns actions; the store applies them.

enum AIAction: Equatable {
    case createNote(title: String, content: String, tags: [String], ref: String?)
    case createTodo(title: String, notes: String?, dueAt: String?, remindAt: String?,
                    priority: Priority?, status: String?, rrule: String?, bill: Bill?, noteRef: String?)
    case addTransaction(merchant: String, amount: Double, currency: String?, category: String,
                        date: String, items: [LineItem], splitWith: [String], noteRef: String?)
    case createSticky(text: String, color: StickyColor?)
    case completeTodo(titleContains: String)
    case startTodo(titleContains: String)
    case setBudget(category: String, amount: Double)
    case splitTransaction(merchantContains: String, people: [String], includeMe: Bool?)
}

extension AIAction: Decodable {
    /// An amount the app can actually store. A non-finite value used to break
    /// saving permanently, and anything past the bound traps on conversion.
    private static func amount(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double {
        if let value = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil,
           Money.isValidAmount(value) { return value }
        if let text = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil,
           let parsed = Money.parse(text) { return parsed }
        return 0
    }

    private enum CodingKeys: String, CodingKey {
        case type, title, content, tags, ref, notes, dueAt, remindAt, priority, status,
             rrule, bill, noteRef, merchant, amount, currency, category, date, items,
             splitWith, text, color, titleContains, merchantContains, people, includeMe
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "create_note":
            self = .createNote(
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled",
                content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
                tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
                ref: try c.decodeIfPresent(String.self, forKey: .ref))
        case "create_todo":
            self = .createTodo(
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "New task",
                notes: try c.decodeIfPresent(String.self, forKey: .notes),
                dueAt: try c.decodeIfPresent(String.self, forKey: .dueAt),
                remindAt: try c.decodeIfPresent(String.self, forKey: .remindAt),
                priority: (try? c.decodeIfPresent(Priority.self, forKey: .priority)) ?? nil,
                status: try c.decodeIfPresent(String.self, forKey: .status),
                rrule: try c.decodeIfPresent(String.self, forKey: .rrule),
                bill: (try? c.decodeIfPresent(Bill.self, forKey: .bill)) ?? nil,
                noteRef: try c.decodeIfPresent(String.self, forKey: .noteRef))
        case "add_transaction":
            self = .addTransaction(
                merchant: try c.decodeIfPresent(String.self, forKey: .merchant) ?? "Unknown",
                amount: AIAction.amount(c, .amount),
                currency: try c.decodeIfPresent(String.self, forKey: .currency),
                category: try c.decodeIfPresent(String.self, forKey: .category) ?? "Other",
                date: try c.decodeIfPresent(String.self, forKey: .date) ?? DateKit.localDate(),
                items: ((try? c.decodeIfPresent([LineItem].self, forKey: .items)) ?? nil) ?? [],
                splitWith: try c.decodeIfPresent([String].self, forKey: .splitWith) ?? [],
                noteRef: try c.decodeIfPresent(String.self, forKey: .noteRef))
        case "create_sticky":
            self = .createSticky(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                color: (try? c.decodeIfPresent(StickyColor.self, forKey: .color)) ?? nil)
        case "complete_todo":
            self = .completeTodo(titleContains: try c.decodeIfPresent(String.self, forKey: .titleContains) ?? "")
        case "start_todo":
            self = .startTodo(titleContains: try c.decodeIfPresent(String.self, forKey: .titleContains) ?? "")
        case "set_budget":
            self = .setBudget(
                category: try c.decodeIfPresent(String.self, forKey: .category) ?? "Other",
                amount: AIAction.amount(c, .amount))
        case "split_transaction":
            self = .splitTransaction(
                merchantContains: try c.decodeIfPresent(String.self, forKey: .merchantContains) ?? "",
                people: try c.decodeIfPresent([String].self, forKey: .people) ?? [],
                includeMe: try c.decodeIfPresent(Bool.self, forKey: .includeMe))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown action \(type)")
        }
    }
}

/// Where a chat reply came from, so the chat can say so without writing it
/// into the reply — text in the reply is read back to the model as history.
enum ReplyOrigin: Equatable {
    /// Claude or another provider, called directly.
    case cloud
    /// Apple Intelligence on this Mac, by choice.
    case onDevice
    /// Apple Intelligence on this Mac because the server didn't answer.
    case onDeviceFallback
}

/// A reply worked out with a web search, and the pages it drew on.
struct WebAnswer: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        var title: String
        var url: String
    }
    var text: String
    var sources: [Source]
}

struct ChatResponse: Decodable {
    var reply: String
    var actions: [AIAction]
    var demo: Bool?
    /// Tools the model called that the app could not turn into an action. The
    /// reply will claim they were saved, so the user has to be told otherwise.
    var droppedActions = 0
    /// Which model answered. Set by the app, never by the model; the server's
    /// JSON doesn't carry it.
    var answeredBy: ReplyOrigin = .cloud
    /// "Claude", "OpenRouter", "LM Studio", "Apple Intelligence".
    var answererName: String?
    /// Set when the first choice failed and another model answered.
    var fallbackNote: String?
    /// The assistant declined (code, or anything harmful; see Guard): no other
    /// model should be offered the question.
    var refused = false

    init(reply: String, actions: [AIAction], demo: Bool? = nil, droppedActions: Int = 0) {
        self.reply = reply; self.actions = actions; self.demo = demo
        self.droppedActions = droppedActions
    }

    private enum CodingKeys: String, CodingKey { case reply, actions, demo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo)
        // Skip actions the Mac build does not know rather than failing the whole reply.
        var list: [AIAction] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .actions) {
            while !arr.isAtEnd {
                if let a = try? arr.decode(AIAction.self) { list.append(a) }
                else { _ = try? arr.decode(AnyIgnored.self) }
            }
        }
        actions = list
    }
}

struct CaptureResult: Decodable {
    enum Kind: String, Decodable { case receipt, handwritten_note, todo_list, other }
    var kind: Kind
    var reply: String
    var actions: [AIAction]
    var demo: Bool?

    init(kind: Kind, reply: String, actions: [AIAction], demo: Bool? = nil) {
        self.kind = kind; self.reply = reply; self.actions = actions; self.demo = demo
    }

    private enum CodingKeys: String, CodingKey { case kind, reply, actions, demo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .other
        reply = try c.decodeIfPresent(String.self, forKey: .reply) ?? ""
        demo = try c.decodeIfPresent(Bool.self, forKey: .demo)
        var list: [AIAction] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .actions) {
            while !arr.isAtEnd {
                if let a = try? arr.decode(AIAction.self) { list.append(a) }
                else { _ = try? arr.decode(AnyIgnored.self) }
            }
        }
        actions = list
    }
}

private struct AnyIgnored: Decodable {
    init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer() }
}
