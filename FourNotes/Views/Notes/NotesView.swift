import SwiftUI

// Notes: a list of note cards beside a large editor.
// Ported from src/components/NotesView.tsx.

private let SORTS: [(id: String, label: String)] = [
    ("updated", "Last edited"),
    ("created", "Date created"),
    ("title", "Title (A–Z)"),
]

private let SOURCE_LABEL: [NoteSource: String] = [
    .manual: "", .chat: "From chat", .ocr: "Scanned", .recording: "Recording", .share: "Shared",
]

struct NotesView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation

    @AppStorage("fournotes.notesSort") private var sort = "updated"
    @AppStorage("fournotes.notesListHidden") private var listHidden = false

    @State private var query = ""
    @State private var searching = false
    @State private var cleanedUp = false
    @FocusState private var searchFocused: Bool

    private var liveNotes: [Note] { store.liveNotes }

    private var list: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            switch sort {
            case "created": return liveNotes.sorted { $0.createdAt > $1.createdAt }
            case "title":
                return liveNotes.sorted {
                    ($0.title.isEmpty ? "Untitled" : $0.title)
                        .localizedCaseInsensitiveCompare($1.title.isEmpty ? "Untitled" : $1.title) == .orderedAscending
                }
            default: return liveNotes.sorted { $0.updatedAt > $1.updatedAt }
            }
        }
        // Instant substring filter, then keyword ranking behind it.
        let substring = liveNotes.filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
        guard q.count >= 3 else { return substring }
        let ranked = Search.relevantNotes(for: q, in: liveNotes, openNoteId: nav.selectedNoteId, limit: 30)
        var out = ranked
        for n in substring where !out.contains(where: { $0.id == n.id }) { out.append(n) }
        return out
    }

    private var selected: Note? {
        if let id = nav.selectedNoteId, let n = liveNotes.first(where: { $0.id == id }) { return n }
        // A valid selection is held even when sorting or searching changes the
        // list. Only an id from another space or a deleted row falls through.
        return liveNotes.first
    }

    var body: some View {
        Group {
            if liveNotes.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 0) {
                    if !listHidden && !nav.focusMode {
                        listColumn
                            .frame(width: 330)
                            .background(p.bg)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            // Above the editor, whose text slides under it.
                            .zIndex(1)
                        Rectangle().fill(p.line).frame(width: 1)
                            .transition(.opacity)
                            .zIndex(1)
                    }
                    if let note = selected {
                        NoteEditorView(
                            note: note,
                            listHidden: listHidden,
                            onToggleList: { listHidden.toggle() },
                            focusMode: nav.focusMode,
                            onToggleFocus: { nav.focusMode.toggle() })
                            .id(note.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity.combined(with: .offset(x: 8)))
                    }
                }
                .frame(maxHeight: .infinity)
                .animation(Motion.screen, value: listHidden)
                .animation(Motion.screen, value: nav.focusMode)
                .animation(Motion.screen, value: selected?.id ?? "")
            }
        }
        .background(p.bg)
        .onAppear {
            cleanUpBlanks()
            if nav.selectedNoteId == nil { nav.selectedNoteId = list.first?.id }
        }
        .task(id: nav.focus) {
            guard let link = nav.consumeFocus([.notes]) else { return }
            query = ""
            searching = false
            nav.selectedNoteId = link.id
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Notes")
                .font(FN.title)
                .tracking(-0.4)
                .foregroundStyle(p.text)
            VStack(spacing: 16) {
                EmptyStart(
                    title: "No notes yet",
                    hint: "Start a note, photograph handwriting, record a voice note — or ask the assistant to write one.",
                    prompts: ["Note: weekend trip ideas",
                              "Summarize this: standup notes, ship Friday, Andi on QA"])
                PrimaryButton(title: "New note", icon: "noteAdd", action: newNote)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    // MARK: - List

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("Notes")
                    .font(FN.title)
                    .tracking(-0.4)
                    .foregroundStyle(p.text)
                Spacer()
                IconMenu("sort", size: 19, help: "Sort notes") {
                    SORTS.map { option in
                        .item(option.label, checked: sort == option.id) { sort = option.id }
                    }
                }
                IconButton("search", size: 18, box: 30, help: "Search notes") {
                    searching.toggle()
                    if !searching { query = "" } else { searchFocused = true }
                }
                .background(searching ? p.hover : .clear,
                            in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                .motion(searching, Motion.quick)
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            addNoteButton
                .padding(.bottom, 12)

            if searching {
                TextField("Search by words or meaning", text: $query)
                    .textFieldStyle(.plain)
                    .font(FN.body)
                    .focused($searchFocused)
                    .onExitCommand {
                        searching = false
                        query = ""
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(p.bg, in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                        .stroke(p.line, lineWidth: 1))
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }

            ScrollView {
                let rows = list
                let selectedID = selected?.id
                LazyVStack(spacing: 10) {
                    ForEach(rows) { note in
                        noteCard(note, isSelected: note.id == selectedID)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    if !query.isEmpty && rows.isEmpty {
                        Text("No matching notes.")
                            .font(FN.body).foregroundStyle(p.faint)
                            .padding(.vertical, 24)
                    }
                }
                .animation(Motion.list, value: rows.map(\.id))
                .padding(.bottom, 90)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 18)
        .animation(Motion.standard, value: searching)
    }

    private var addNoteButton: some View {
        HoverRow(cornerRadius: 10) { hovering in
            Button(action: newNote) {
                HStack(spacing: 12) {
                    Icon("plus", size: 18)
                    Text("Add new note").font(FN.font(14))
                    Spacer(minLength: 4)
                    Text("⌘N").font(FN.tiny).foregroundStyle(p.faint)
                }
                .foregroundStyle(hovering ? p.text : p.text.opacity(0.85))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .accessibilityLabel("New note")
        }
    }

    private static let cardDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let cardDateWithYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "19 APR", or "19 APR 2025" once it is not this year.
    private func cardDate(_ iso: String) -> String {
        guard let d = DateKit.date(iso) else { return "" }
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        return (sameYear ? Self.cardDate : Self.cardDateWithYear).string(from: d).uppercased()
    }

    private func noteCard(_ note: Note, isSelected: Bool) -> some View {
        let preview = NoteText.snippet(note.content)
        let linked = store.liveTodos.filter { $0.noteId == note.id }.count
            + store.liveTransactions.filter { $0.noteId == note.id }.count
        let tags = NoteText.tags(note.tags)
        let source = SOURCE_LABEL[note.source] ?? ""

        return Button { open(note.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(cardDate(note.updatedAt))
                    if !source.isEmpty {
                        Text("·")
                        Text(source.uppercased())
                    }
                    Spacer(minLength: 4)
                    if linked > 0 {
                        HStack(spacing: 2) {
                            Icon("link", size: 11)
                            Text("\(linked)")
                        }
                        .help("\(linked) linked item\(linked == 1 ? "" : "s")")
                    }
                }
                .font(FN.font(11, .medium))
                .tracking(0.8)
                .foregroundStyle(p.faint)
                .lineLimit(1)

                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(FN.font(15, isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? p.text : p.text.opacity(0.78))
                    .lineLimit(1)
                    .padding(.top, 8)

                Text(preview.isEmpty ? "No text yet" : preview)
                    .font(FN.body)
                    .foregroundStyle(isSelected ? p.muted : p.faint)
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6)

                if !tags.isEmpty {
                    tagRow(tags)
                        .padding(.top, 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isSelected ? p.hover : p.panel,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? p.faint.opacity(0.35) : .clear, lineWidth: 1))
            .motion(isSelected, Motion.quick)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .flashes(nav.isFlashing(note.id), palette: p)
        .contextMenu {
            Button(EdgeStickies.shared.isStuck(note.id) ? "Take off screen edge" : "Stick to screen edge") {
                EdgeStickies.shared.toggle(note.id)
            }
            Divider()
            Button("Delete note", role: .destructive) { store.remove(.notes, note.id) }
        }
    }

    /// As many tags as fit on one line (at most three), then "+N more", as
    /// outlined chips.
    private func tagRow(_ tags: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array((0...min(3, tags.count)).reversed()), id: \.self) { count in
                HStack(spacing: 6) {
                    ForEach(tags.prefix(count), id: \.self) { tag in
                        outlinedChip(tag.prefix(1).uppercased() + tag.dropFirst())
                    }
                    if tags.count > count { outlinedChip("+\(tags.count - count) more") }
                }
            }
        }
    }

    private func outlinedChip(_ text: String) -> some View {
        Text(text)
            .font(FN.font(11, .medium))
            .tracking(0.4)
            .foregroundStyle(p.muted)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(p.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(p.line, lineWidth: 1))
            .fixedSize()
    }

    // MARK: - Actions

    /// A note that was opened but never written in: no title, no text, no scan,
    /// nothing linked.
    private func isBlank(_ n: Note) -> Bool {
        n.deletedAt == nil
            && (n.title.trimmingCharacters(in: .whitespaces).isEmpty || n.title == "Untitled")
            && n.content.trimmingCharacters(in: .whitespaces).isEmpty
            && n.imageDataUrl == nil
            && n.imageFile == nil
            && !store.liveTodos.contains { $0.noteId == n.id }
            && !store.liveTransactions.contains { $0.noteId == n.id }
    }

    /// Leaving a note you never wrote in discards it, so "New note" doesn't pile up blanks.
    private func leave(_ nextId: String?) {
        // What was typed a moment ago may still be waiting out its debounce:
        // write it first, or a new note typed in and left at once was deleted
        // as blank, and its text saved into the deleted note.
        PendingWrites.flushAll()
        guard let current = nav.selectedNoteId, current != nextId,
              let note = liveNotes.first(where: { $0.id == current }), isBlank(note) else { return }
        store.remove(.notes, note.id)
    }

    private func open(_ id: String) {
        leave(id)
        nav.selectedNoteId = id
    }

    private func newNote() {
        query = ""
        searching = false
        leave(nil)
        // Empty, so the "Untitled" placeholder doesn't need deleting.
        let n = store.addNote { $0.title = "" }
        nav.selectedNoteId = n.id
    }

    /// Blanks left behind earlier (e.g. by switching tabs) are cleaned up when
    /// Notes opens — only ones older than a few seconds, never the open note.
    private func cleanUpBlanks() {
        guard !cleanedUp else { return }
        cleanedUp = true
        let cutoff = Date().addingTimeInterval(-10)
        for n in store.notes where n.id != nav.selectedNoteId && isBlank(n)
            && (DateKit.date(n.updatedAt).map { $0 < cutoff } ?? false) {
            store.remove(.notes, n.id)
        }
    }
}
