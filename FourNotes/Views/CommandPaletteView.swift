import SwiftUI

// ⌘K: search everything and quick-add in one step.
//   t pay rent          -> task          n trip ideas   -> note
//   $ coffee 25k        -> expense       s call mom     -> quick note
//   ? how much on food  -> ask the assistant
// Ported from src/components/CommandPalette.tsx.

struct CommandPaletteView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var assistant: Assistant

    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue

    @State private var query = ""
    @State private var active = 0
    /// Where the pointer last was, so only a moving pointer selects a row.
    @State private var pointer: CGPoint?
    @FocusState private var focused: Bool

    private static let space = "palette"

    private struct Item: Identifiable {
        var id: String
        var group: String
        var icon: String
        var label: String
        var hint: String?
        var run: () -> Void
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Icon("search", size: 16).foregroundStyle(p.faint)
                TextField("Search, or: t task · n note · $ coffee 25k · s quick note · ? question",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(p.text)
                    .focused($focused)
                    .onSubmit { run(items.indices.contains(active) ? items[active] : nil) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().overlay(p.line)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            Text("No results")
                                .font(FN.body).foregroundStyle(p.faint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].group != item.group {
                                Text(item.group.uppercased())
                                    .font(FN.font(11, .medium))
                                    .tracking(0.5)
                                    .foregroundStyle(p.faint)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)
                            }
                            // Keyed by the item, not its position: the lazy stack
                            // keeps rows by this id, so an index id made a new
                            // query show the old list's rows under the new headers.
                            row(item, selected: index == active)
                                .id(item.id)
                                // Arrow keys scroll rows under a pointer resting on
                                // the list; with onHover the row that slid beneath
                                // it took the highlight back, and the keys stuck.
                                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                                    guard case .active(let point) = phase, point != pointer else { return }
                                    pointer = point
                                    active = index
                                }
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(Motion.quick, value: items.map(\.id))
                }
                .frame(maxHeight: 380)
                .onChange(of: active) { _, index in
                    guard items.indices.contains(index) else { return }
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .frame(width: 620)
        .background(p.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .onAppear {
            query = ""
            active = 0
        }
        .task {
            // When nothing in the window had focus, the first request is
            // dropped and focus goes to the first text field behind the
            // overlay (Today's quick note, Finance's search), which then took
            // the typing. Asking again once that has happened sticks.
            for _ in 0..<5 where !focused {
                focused = true
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        .onChange(of: query) { _, _ in
            active = 0
        }
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .handled }
            active = (active + 1) % items.count
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .handled }
            active = (active - 1 + items.count) % items.count
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        Button { run(item) } label: {
            HStack(spacing: 8) {
                Icon(item.icon, size: 14).foregroundStyle(p.muted)
                Text(item.label).font(FN.body).foregroundStyle(p.text).lineLimit(1)
                Spacer(minLength: 12)
                if let hint = item.hint, !hint.isEmpty {
                    Text(hint).font(FN.small).foregroundStyle(p.faint).lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? p.hover : .clear)
            .scaleEffect(selected ? 1.01 : 1)
            .motion(selected, Motion.quick)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
    }

    /// The palette floats over the window rather than being a sheet, so a
    /// click anywhere outside it can close it.
    private func close() {
        if nav.sheet == .palette { nav.sheet = nil }
    }

    private func run(_ item: Item?) {
        guard let item else { return }
        close()
        item.run()
    }

    // MARK: - Items

    private var items: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Item] = []

        if let match = q.firstMatch(of: /^(?i)(t|todo|task|n|note|\$|spent|s|sticky|\?|ask)\s+(.+)$/) {
            let kind = String(match.1).lowercased()
            let text = String(match.2).trimmingCharacters(in: .whitespaces)

            if ["t", "todo", "task"].contains(kind) {
                out.append(Item(id: "qa-task", group: "Quick add", icon: "todo",
                                label: "Add task “\(text)”", hint: nil) {
                    let t = store.addTodo { $0.title = text }
                    toasts.push("✅ \(t.title)")
                })
                out.append(Item(id: "qa-task-ai", group: "Quick add", icon: "sparkle",
                                label: "Let the assistant set the date & repeat", hint: text) {
                    Task { await assistant.send("Add a task: \(text)") }
                })
            } else if ["n", "note"].contains(kind) {
                out.append(Item(id: "qa-note", group: "Quick add", icon: "note",
                                label: "New note “\(text)”", hint: nil) {
                    let n = store.addNote { $0.title = text }
                    nav.open(ChangeLink(kind: .notes, id: n.id))
                })
            } else if ["$", "spent"].contains(kind) {
                let spend = Glance.spend(text)
                if let spend {
                    out.append(Item(id: "qa-spend", group: "Quick add", icon: "finance",
                                    label: "Log \(Money.format(abs(spend.amount), store.settings.currency)) "
                                        + "\(spend.amount < 0 ? "from" : "at") \(spend.merchant)",
                                    hint: spend.category) {
                        store.addTransaction {
                            $0.merchant = spend.merchant
                            $0.amount = spend.amount
                            $0.category = spend.category
                        }
                        toasts.push("💸 \(spend.merchant)")
                    })
                } else {
                    out.append(Item(id: "qa-spend-hint", group: "Quick add", icon: "finance",
                                    label: "Add an amount, e.g. “$ coffee 25k”", hint: nil) {})
                }
            } else if ["s", "sticky"].contains(kind) {
                out.append(Item(id: "qa-quick-note", group: "Quick add", icon: "note",
                                label: "Quick note “\(text)”", hint: nil) {
                    store.addNote { QuickNote.apply(text, to: &$0) }
                    toasts.push("📝 Quick note saved")
                })
            } else {
                out.append(Item(id: "qa-ask", group: "Ask", icon: "sparkle", label: "Ask: \(text)", hint: nil) {
                    Task { await assistant.send(text) }
                })
            }
            return out
        }

        if !q.isEmpty {
            let hits = Search.keyword(notes: store.liveNotes, todos: store.liveTodos,
                                      transactions: store.liveTransactions, query: q, limit: 8)
            for hit in hits {
                switch hit {
                case .note(let n, _):
                    out.append(Item(id: n.id, group: "Notes", icon: "note",
                                    label: n.title.isEmpty ? "Untitled" : n.title,
                                    hint: String(n.content.prefix(60))) {
                        nav.open(ChangeLink(kind: .notes, id: n.id))
                    })
                case .todo(let t, _):
                    out.append(Item(id: t.id, group: "Tasks", icon: "todo", label: t.title,
                                    hint: t.done ? "done" : Fmt.due(t.dueAt)) {
                        nav.open(ChangeLink(kind: .todos, id: t.id))
                    })
                case .transaction(let t, _):
                    out.append(Item(id: t.id, group: "Spending", icon: "finance", label: t.merchant,
                                    hint: "\(Money.format(t.amount, t.currency)) · \(t.date)") {
                        nav.open(ChangeLink(kind: .transactions, id: t.id))
                    })
                }
            }
            out.append(Item(id: "ask", group: "Ask", icon: "sparkle",
                            label: "Ask the assistant: “\(q)”", hint: nil) {
                Task { await assistant.send(q) }
            })
        }

        let isDark = (ThemeChoice(rawValue: themeRaw) ?? .system) == .dark
        var commands: [Item] = [
            Item(id: "go-today", group: "Go to", icon: "today", label: "Today", hint: "⌘1") { nav.tab = .today },
            Item(id: "go-notes", group: "Go to", icon: "note", label: "Notes", hint: "⌘2") { nav.tab = .notes },
            Item(id: "go-todo", group: "Go to", icon: "todo", label: "To-Do", hint: "⌘3") { nav.tab = .todo },
            Item(id: "go-finance", group: "Go to", icon: "finance", label: "Finance", hint: "⌘4") { nav.tab = .finance },
            Item(id: "new-note", group: "Create", icon: "plus", label: "New note", hint: "n …") {
                let n = store.addNote { $0.title = "" }
                nav.open(ChangeLink(kind: .notes, id: n.id))
            },
            Item(id: "scan", group: "Create", icon: "scan", label: "Scan receipt or note", hint: "⇧⌘I") {
                assistant.pickAndScan()
            },
            Item(id: "record", group: "Create", icon: "mic", label: "Record to note", hint: "⇧⌘R") {
                assistant.recording ? assistant.stopRecording() : assistant.startRecording()
            },
            Item(id: "theme", group: "Actions", icon: isDark ? "today" : "moon",
                 label: isDark ? "Switch to light mode" : "Switch to dark mode", hint: "theme") {
                themeRaw = (isDark ? ThemeChoice.light : ThemeChoice.dark).rawValue
            },
            Item(id: "settings", group: "Actions", icon: "settings",
                 label: "Settings, budgets & sync", hint: "⌘,") { nav.present(.settings) },
        ]

        let lower = q.lowercased()
        if !q.isEmpty {
            commands = commands.filter {
                $0.label.lowercased().contains(lower) || ($0.hint ?? "").lowercased().contains(lower)
            }
        }
        out.append(contentsOf: commands)
        return out
    }
}
