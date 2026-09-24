import Foundation

// Edits that are waiting out a short debounce before they reach the store —
// the note being typed, a title mid-word. Quitting or switching away writes
// them first, so the last keystrokes aren't lost to the delay.

@MainActor
enum PendingWrites {
    private static var writes: [UUID: () -> Void] = [:]

    /// `write` will run when the debounce ends, or sooner if the app is leaving.
    static func hold(_ id: UUID, _ write: @escaping () -> Void) { writes[id] = write }

    /// It ran, or was dropped: nothing waiting any more.
    static func release(_ id: UUID) { writes[id] = nil }

    /// Runs everything still waiting. Called before the document is flushed.
    static func flushAll() {
        let waiting = writes
        writes = [:]
        for write in waiting.values { write() }
    }
}
