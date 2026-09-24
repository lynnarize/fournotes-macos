import AppKit
import Combine
import SwiftUI

// Sticky Edge: notes stuck to the edge dock's handle. This keeps which notes
// are stuck and what colour each is; the dock draws them, as part of its own
// shape (see "Sticky notes" in EdgeDock.swift).
//
// The note itself is an ordinary note; unsticking only takes it off the
// edge. Which notes are stuck is this Mac's business, not the document's:
// it's kept in UserDefaults, so the file the web app reads is unchanged.

@MainActor
final class EdgeStickies: ObservableObject {
    static let shared = EdgeStickies()

    /// In the order they were stuck, which is the order along the edge.
    @Published private(set) var placements: [StickyPlacement]

    private var model: AppModel?
    private var watching: AnyCancellable?
    private var editing: Set<String> = []
    private(set) var focusOnOpen: String?
    /// What was on the edge last time, so a keystroke in some note doesn't
    /// make the dock lay its tabs out again.
    private var lastShown: [String] = []

    private static let key = "fournotes.stickies"

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key) ?? Data()
        placements = (try? JSONDecoder().decode([StickyPlacement].self, from: data)) ?? []
    }

    func install(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // A turn later, so the store has finished changing when it's read.
        watching = model.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
        sync()
    }

    // MARK: - What's stuck

    /// The notes on the edge now: stuck, alive, and in the current space.
    var shownIds: [String] {
        guard let store = model?.store else { return [] }
        let live = Set(store.liveNotes.lazy.map(\.id))
        return placements.map(\.noteId).filter(live.contains)
    }

    func isStuck(_ noteId: String) -> Bool { placements.contains { $0.noteId == noteId } }

    func placement(_ noteId: String) -> StickyPlacement? { placements.first { $0.noteId == noteId } }

    func note(_ noteId: String) -> Note? { model?.store.liveNotes.first { $0.id == noteId } }

    // MARK: - Sticking and unsticking

    /// Sticks a note to the edge: it flies there from the pointer and lands
    /// in the island beside the handle. One that's already stuck opens.
    func stick(_ noteId: String, focus: Bool = false) {
        let dock = EdgeDock.shared
        guard !isStuck(noteId) else {
            dock.openSticky(noteId)
            return
        }
        let used = Set(placements.map(\.color))
        let color = StickyTint.allCases.first { !used.contains($0) }
            ?? StickyTint.allCases[placements.count % StickyTint.allCases.count]
        placements.append(StickyPlacement(noteId: noteId, color: color))
        save()
        if focus { focusOnOpen = noteId }
        lastShown = shownIds
        dock.receiveSticky(noteId, from: NSEvent.mouseLocation)
    }

    /// A new, empty quick note, stuck and ready to type in.
    func stickNew() {
        guard let store = model?.store else { return }
        let note = store.addNote { QuickNote.apply("", to: &$0) }
        stick(note.id, focus: true)
    }

    /// Takes a note off the edge and out of the island. One that was never
    /// written in goes too.
    func unstick(_ noteId: String) {
        guard isStuck(noteId) else { return }
        placements.removeAll { $0.noteId == noteId }
        save()
        if let store = model?.store, let note = note(noteId),
           note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.remove(.notes, noteId)
        }
        sync()
    }

    func toggle(_ noteId: String) {
        isStuck(noteId) ? unstick(noteId) : stick(noteId)
    }

    func unstickAll() {
        for id in placements.map(\.noteId) { unstick(id) }
    }

    func setColor(_ noteId: String, _ color: StickyTint) {
        guard let i = placements.firstIndex(where: { $0.noteId == noteId }) else { return }
        placements[i].color = color
        save()
    }

    /// Opens the note in the app's window.
    func openInApp(_ noteId: String) {
        EdgeDock.shared.showApp { $0.open(ChangeLink(kind: .notes, id: noteId)) }
    }

    // MARK: - Typing

    func consumeFocus(_ noteId: String) -> Bool {
        guard focusOnOpen == noteId else { return false }
        focusOnOpen = nil
        return true
    }

    func setEditing(_ noteId: String, _ on: Bool) {
        if on { editing.insert(noteId) } else { editing.remove(noteId) }
    }

    func isEditing(_ noteId: String?) -> Bool { noteId.map(editing.contains) ?? false }

    // MARK: - Keeping up with the notes

    /// A deleted note comes off the edge for good; one in another space only
    /// hides, and comes back with its space. The dock hears when what's on
    /// the edge changed.
    private func sync() {
        guard let store = model?.store, store.ready else { return }
        let gone = placements.filter { p in
            !store.all.notes.contains { $0.id == p.noteId && $0.deletedAt == nil }
        }
        if !gone.isEmpty {
            placements.removeAll { p in gone.contains { $0.noteId == p.noteId } }
            save()
        }
        let shown = shownIds
        guard shown != lastShown else { return }
        lastShown = shown
        EdgeDock.shared.stickiesChanged()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(placements) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
