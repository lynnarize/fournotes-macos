import SwiftUI
import UniformTypeIdentifiers

// A board like Notion's: To Do -> Doing -> Done, with a task panel beside it.
// Ported from src/components/TodoView.tsx.

private let DONE_SHOWN = 30
/// Narrower than this and labels, titles and dates start breaking mid-word;
/// the board scrolls sideways instead, as the web app's does.
private let COLUMN_MIN: CGFloat = 250

extension BoardColumn {
    var label: String {
        switch self {
        case .todo: return "To Do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }

    func hue(_ p: Palette) -> Color {
        switch self {
        case .todo: return p.boardRed
        case .doing: return p.boardAmber
        case .done: return p.boardGreen
        }
    }

    func ink(_ p: Palette) -> Color {
        switch self {
        case .todo: return p.boardRedInk
        case .doing: return p.boardAmberInk
        case .done: return p.boardGreenInk
        }
    }
}

struct TodoView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter

    @State private var openId: String?
    /// The task "New" just made: removed again if it's closed while still empty.
    @State private var fresh: String?
    @State private var dragging: String?
    @State private var dropTarget: BoardColumn?
    @State private var showAllDone = false
    /// The open task fills the page instead of sitting beside the board.
    @State private var expanded = false
    @State private var cleanedUp = false
    @State private var boardWidth: CGFloat = 0

    private var live: [Todo] { store.liveTodos }
    private var openTodo: Todo? { live.first { $0.id == openId } }

    private func column(_ c: BoardColumn) -> [Todo] {
        let items = live.filter { $0.column == c }
        // Soonest first (overdue on top); undated tasks after dated ones, newest first.
        if c == .done {
            return items.sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
        }
        return items.sorted {
            let a = $0.dueAt ?? "~", b = $1.dueAt ?? "~"
            return a == b ? $0.createdAt > $1.createdAt : a < b
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if !(expanded && openTodo != nil) {
                VStack(alignment: .leading, spacing: 0) {
                    toolbar

                    if live.isEmpty {
                        EmptyStart(
                            title: "Nothing to do yet",
                            hint: "Press New, or ask the assistant — it understands dates, reminders and repeats.",
                            prompts: ["Remind me to pay rent every month on the 5th at 9am",
                                      "Call the dentist tomorrow at 10am"])
                    }

                    board
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }

            if let todo = openTodo {
                TaskPanel(todo: todo, isNew: fresh == todo.id, expanded: expanded,
                          onToggleExpand: { expanded.toggle() },
                          onClose: close, onMove: { move(todo.id, to: $0) })
                    // Without this the panel keeps its state between tasks: task
                    // A's reminder suggestion stays on screen for task B, and a
                    // new task's title field never takes focus.
                    .id(todo.id)
                    .frame(width: expanded ? nil : 440)
                    .frame(maxWidth: expanded ? .infinity : nil)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.screen, value: openId)
        .animation(Motion.screen, value: expanded)
        .onAppear(perform: cleanUpBlanks)
        .task(id: nav.focus) {
            guard let link = nav.consumeFocus([.todos]) else { return }
            if live.first(where: { $0.id == link.id })?.done == true { showAllDone = true }
            show(link.id)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Icon("todo", size: 16)
                Text("Board").font(FN.bodyMedium)
            }
            .foregroundStyle(p.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(p.hover, in: Capsule())

            Text("\(live.filter { !$0.done }.count) open")
                .font(FN.body)
                .foregroundStyle(p.faint)

            Spacer()

            PrimaryButton(title: "New", icon: "plus") { create(.todo) }
        }
        .padding(.bottom, 16)
    }

    /// The three columns share the width, never narrower than COLUMN_MIN;
    /// past that the row scrolls sideways. One layout for both cases: it used
    /// to switch between two (ViewThatFits), and a card could keep the narrow
    /// width it had while the task panel was open, its chips spilling out.
    private var board: some View {
        let spacing: CGFloat = 12
        let fits = (boardWidth - spacing * 2) / 3
        let width = max(COLUMN_MIN, fits.isFinite ? fits : COLUMN_MIN)
        let overflows = fits < COLUMN_MIN
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(BoardColumn.allCases) { col in
                    columnView(col).frame(width: width, alignment: .top)
                }
            }
            .padding(.bottom, overflows ? 10 : 0)
        }
        .scrollDisabled(!overflows)
        .scrollIndicators(overflows ? .automatic : .hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardWidth = $0 }
    }

    // MARK: - Column

    private func columnView(_ col: BoardColumn) -> some View {
        let items = column(col)
        let shown = col == .done && !showAllDone ? Array(items.prefix(DONE_SHOWN)) : items
        let hue = col.hue(p)
        let isDropTarget = dropTarget == col && dragging != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(col.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(p.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(p.mix(hue, p.boardLabelMix),
                                in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                Text("\(items.count)")
                    .font(FN.body).monospacedDigit()
                    .foregroundStyle(col.ink(p))
                    .fixedSize()
                Spacer()
                IconButton("plus", size: 18, box: 30, tone: col.ink(p),
                           help: "Add to \(col.label)") { create(col) }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            ForEach(shown) { todo in
                TodoCard(todo: todo, column: col, selected: openId == todo.id,
                         dragging: dragging == todo.id,
                         onOpen: { show(todo.id) },
                         onToggle: { move(todo.id, to: todo.done ? .todo : .done) })
                    .onDrag {
                        dragging = todo.id
                        return NSItemProvider(object: todo.id as NSString)
                    }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            .animation(Motion.list, value: items.map(\.id))

            if col == .done, items.count > shown.count {
                Button { showAllDone = true } label: {
                    Text("Show \(items.count - shown.count) older")
                        .font(FN.body)
                        .foregroundStyle(col.ink(p))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
            }

            Button { create(col) } label: {
                HStack(spacing: 8) {
                    Icon("plus", size: 16)
                    Text("New task").font(.system(size: 15)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(col.ink(p))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hue.opacity(0.28), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(p.mix(hue, p.boardColMix),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(hue.opacity(isDropTarget ? 0.6 : 0), lineWidth: 2))
        .motion(isDropTarget, Motion.quick)
        .onDrop(of: [.text], delegate: ColumnDrop(column: col, dragging: $dragging,
                                                  dropTarget: $dropTarget, move: move))
    }

    // MARK: - Actions

    /// Moves a task between columns; finishing one still logs its bill and
    /// schedules the next repeat.
    private func move(_ id: String, to: BoardColumn) {
        guard let t = live.first(where: { $0.id == id }), t.column != to else { return }
        if to == .done {
            let extra = store.toggleTodo(id, done: true)
            if !extra.isEmpty { toasts.push(extra.joined(separator: "\n")) }
            return
        }
        if t.done { store.toggleTodo(id, done: false) }
        store.updateTodo(id) { $0.doing = (to == .doing) }
    }

    /// A task made with "New" that was closed before anything was typed into it.
    private func isBlank(_ t: Todo) -> Bool {
        t.deletedAt == nil && t.title.trimmingCharacters(in: .whitespaces).isEmpty
            && (t.notes ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && t.dueAt == nil && t.remindAt == nil && t.bill == nil && t.rrule == nil && t.noteId == nil
    }

    private func dropFresh(except: String? = nil) {
        // A title typed a moment ago may still be waiting out its debounce:
        // write it first, or "Buy milk" + Esc deleted the task as blank.
        PendingWrites.flushAll()
        if let fresh, fresh != except, let t = live.first(where: { $0.id == fresh }), isBlank(t) {
            store.remove(.todos, t.id)
        }
        if fresh != except { fresh = nil }
    }

    private func show(_ id: String) {
        dropFresh(except: id)
        openId = id
    }

    private func close() {
        dropFresh()
        openId = nil
        expanded = false
    }

    private func create(_ column: BoardColumn) {
        dropFresh()
        let t = store.addTodo { $0.title = "" }
        switch column {
        case .doing: store.updateTodo(t.id) { $0.doing = true }
        case .done: store.updateTodo(t.id) { $0.done = true; $0.completedAt = DateKit.nowIso() }
        case .todo: break
        }
        fresh = t.id
        openId = t.id
    }

    /// Empty tasks left behind (e.g. by switching tabs) are cleaned up when To-Do opens.
    private func cleanUpBlanks() {
        guard !cleanedUp else { return }
        cleanedUp = true
        let cutoff = Date().addingTimeInterval(-10)
        for t in store.todos where isBlank(t) && (DateKit.date(t.updatedAt).map { $0 < cutoff } ?? false) {
            store.remove(.todos, t.id)
        }
    }
}

// MARK: - Drop target

private struct ColumnDrop: DropDelegate {
    let column: BoardColumn
    @Binding var dragging: String?
    @Binding var dropTarget: BoardColumn?
    let move: (String, BoardColumn) -> Void

    func dropEntered(info: DropInfo) { if dragging != nil { dropTarget = column } }
    func dropExited(info: DropInfo) { if dropTarget == column { dropTarget = nil } }
    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropTarget = nil }
        guard let id = dragging else { return false }
        move(id, column)
        return true
    }
}

// MARK: - Card

private struct TodoCard: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @State private var hovering = false

    let todo: Todo
    let column: BoardColumn
    let selected: Bool
    let dragging: Bool
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var note: Note? {
        todo.noteId.flatMap { id in store.liveNotes.first { $0.id == id } }
    }

    private var overdue: Bool {
        !todo.done && (DateKit.date(todo.dueAt).map { $0 < Date() } ?? false)
    }

    private var priorityDot: Color? {
        guard !todo.done, todo.priority != .medium else { return nil }
        return todo.priority == .high ? p.danger : p.faint
    }

    private var hasMeta: Bool {
        note != nil || todo.bill != nil || todo.rrule != nil || todo.dueAt != nil
            || (todo.remindAt != nil && !todo.done)
    }

    var body: some View {
        let hue = column.hue(p)
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(todo.done ? p.accent : p.faint, lineWidth: 1.5)
                        .background(Circle().fill(todo.done ? p.accent : .clear))
                        .frame(width: 20, height: 20)
                    if todo.done {
                        Icon("check", size: 12).foregroundStyle(.white)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .contentShape(Circle())
                .motion(todo.done, Motion.standard)
            }
            .buttonStyle(.fn)
            .accessibilityLabel(todo.done ? "Mark as not done" : "Mark as done")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(todo.title.isEmpty ? "New task" : todo.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(todo.done || todo.title.isEmpty ? p.faint : p.text)
                        .strikethrough(todo.done)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasMeta {
                        FlowLayout(spacing: 4, alignment: .leading) {
                            if let due = todo.dueAt {
                                Chip(tone: overdue ? p.danger : nil) {
                                    Icon("calendar", size: 11)
                                    Text((overdue ? "Overdue · " : "") + Fmt.due(due))
                                }
                            }
                            if let remind = todo.remindAt, !todo.done {
                                Chip(tone: nil) {
                                    Icon("bell", size: 11)
                                    if todo.dueAt == nil { Text(Fmt.due(remind)) }
                                }
                            }
                            if let rrule = todo.rrule {
                                Chip(tone: nil) {
                                    Icon("repeat", size: 11)
                                    Text(Recurrence.label(rrule).replacingOccurrences(of: "Every ", with: ""))
                                }
                            }
                            if let bill = todo.bill {
                                Chip(Money.format(bill.amount, bill.currency ?? store.settings.currency, compact: true))
                            }
                            if let note {
                                Chip(tone: nil) {
                                    Icon("link", size: 11)
                                    Text(note.title.isEmpty ? "Note" : note.title)
                                }
                                .frame(maxWidth: 176, alignment: .leading)
                            }
                        }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(Motion.standard, value: hasMeta)
            }
            .buttonStyle(.fn)

            if let priorityDot {
                Circle().fill(priorityDot).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(p.mix(hue, p.boardCardMix),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(selected ? p.accent : hue.opacity(hovering ? 0.3 : 0.14),
                    lineWidth: selected ? 2 : 1))
        .shadow(color: p.shadow, radius: hovering ? 5 : 2, y: 1)
        .opacity(dragging ? 0.4 : 1)
        .scaleEffect(dragging ? 0.97 : hovering ? 1.012 : 1)
        .motion(hovering || dragging || selected, Motion.quick)
        .motion(todo.done, Motion.standard)
        .flashes(nav.isFlashing(todo.id), palette: p)
        .onHover { hovering = $0 }
    }
}
