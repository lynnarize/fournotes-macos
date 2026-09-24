import Foundation

// Errors from any model the app calls, and the note editor's writing jobs.

enum APIError: LocalizedError {
    case notConfigured
    case offline
    case server(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI provider is set up. Add one in Settings → AI & API keys."
        case .offline:
            return "You're offline. This needs internet; it will work again once you reconnect."
        case .server(let message):
            return message
        case .badResponse:
            return "The AI provider sent something this app could not read."
        }
    }
}

/// The note editor's AI menu.
enum WriteTask: String, CaseIterable {
    case summarize, improve, fix, shorter, `continue`
    var label: String {
        switch self {
        case .summarize: return "Summarize"
        case .improve: return "Improve writing"
        case .fix: return "Fix spelling & grammar"
        case .shorter: return "Make shorter"
        case .continue: return "Continue writing"
        }
    }
}
