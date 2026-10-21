import SwiftUI
import UniformTypeIdentifiers

// A board (To do, Doing, Done) with the open task in a panel beside it, as on the web
// (src/components/TodoView.tsx). Columns are neutral; colour marks only real status
// (due soon, overdue), always with words. Filters narrow the board; they never change
// a task.

private let DONE_SHOWN = 30
/// Narrower than this and labels, titles and dates start breaking mid-word;
/// the board scrolls sideways instead, as the web app's does.
private let COLUMN_MIN: CGFloat = 250

/// What the board shows: everything, or one kind of task.
private enum BoardFilter: String, CaseIterable {
    case all, week, repeating, bills, linked

    var label: String {
        switch self {
        case .all: return "All"
        case .week: return "Due this week"
        case .repeating: return "Repeating"
        case .bills: return "Bills"
        case .linked: return "Linked to a note"
        }
    }

    func test(_ t: Todo) -> Bool {
        switch self {
        case .all: return true
        case .week: return DateKit.date(t.dueAt).map { $0 < Date().addingTimeInterval(7 * 86_400) } ?? false
        case .repeating: return t.rrule != nil
        case .bills: return t.bill != nil
        case .linked: return t.noteId != nil
        }
    }
}

extension BoardColumn {
    var empty: String {
        switch self {
        case .todo: return "Nothing to do"
        case .doing: return "Nothing in progress"
        case .done: return "Nothing done yet"
        }
    }

    var hint: String {
        switch self {
        case .todo: return "Add a task, or drag one back here."
        case .doing: return "Drag a task here when you start it."
        case .done: return "Finished tasks land here."
        }
    }

    var label: String {
        switch self {
        case .todo: return "To do"
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
    @State private var filter: BoardFilter = .all

    private var live: [Todo] { store.liveTodos }
    private var openTodo: Todo? { live.first { $0.id == openId } }

    private func column(_ c: BoardColumn) -> [Todo] {
        let items = live.filter { $0.column == c && filter.test($0) }
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

    /// "2 open, 1 done this week", New, and the filters.
    private var toolbar: some View {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let doneThisWeek = live.filter { $0.done && (DateKit.date($0.completedAt).map { $0 >= weekAgo } ?? false) }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("\(live.filter { !$0.done }.count) open, \(doneThisWeek) done this week")
                    .font(FN.font(14))
                    .monospacedDigit()
                    .foregroundStyle(p.textSecondary)
                Spacer()
                PrimaryButton(title: "New", icon: "plus") { create(.todo) }
            }
            if !live.isEmpty {
                HStack(spacing: 8) {
                    ForEach(BoardFilter.allCases, id: \.self) { f in
                        PillButton(title: f.label, selected: filter == f) {
                            withAnimation(Motion.standard) { filter = f }
                        }
                    }
                }
            }
        }
        .padding(.top, -8)
        .padding(.bottom, 20)
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
        let isDropTarget = dropTarget == col && dragging != nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(col.label)
                    .font(FN.font(13.5, .medium))
                    .foregroundStyle(p.foreground)
                    .lineLimit(1)
                    .fixedSize()
                Text("\(items.count)")
                    .font(FN.font(13)).monospacedDigit()
                    .foregroundStyle(p.textMuted)
                    .fixedSize()
                    .contentTransition(.numericText())
                Spacer()
                IconButton("plus", size: 16, box: 30, help: "Add to \(col.label)") { create(col) }
            }
            .padding(.leading, 12)
            .padding(.trailing, 2)
            .frame(height: 40)

            if shown.isEmpty {
                VStack(spacing: 4) {
                    Text(filter == .all ? col.empty : "Nothing here")
                        .font(FN.font(13.5, .medium))
                        .foregroundStyle(p.foreground)
                    Text(filter == .all ? col.hint : "No tasks in this column match the filter.")
                        .font(FN.font(12.5))
                        .foregroundStyle(p.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
                .overlay(RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
                    .strokeBorder(p.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .transition(.opacity)
            }

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
                GhostButton(action: { showAllDone = true }) {
                    Text("Show \(items.count - shown.count) older").frame(maxWidth: .infinity)
                }
            }

            Button { create(col) } label: {
                NewTaskRow()
            }
            .buttonStyle(.fn)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(isDropTarget ? p.accent.mixed(with: p.surfaceMuted, ratio: 0.95) : p.surfaceMuted,
                    in: RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous)
            .strokeBorder(p.accent.opacity(isDropTarget ? 1 : 0), lineWidth: 1.5))
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

    /// Status, said in words: overdue, or due within a day.
    private var status: (text: String, tone: Color, subtle: Color)? {
        guard !todo.done, let due = DateKit.date(todo.dueAt) else { return nil }
        if due < Date() { return ("Overdue", p.danger, p.dangerSubtle) }
        if due < Date().addingTimeInterval(86_400) { return ("Due soon", p.warning, p.warningSubtle) }
        return nil
    }

    private var hasMeta: Bool {
        note != nil || todo.rrule != nil || todo.dueAt != nil
            || (todo.remindAt != nil && !todo.done) || (todo.priority == .high && !todo.done)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(todo.done ? p.accent : (hovering ? p.textMuted : p.borderStrong), lineWidth: 1.5)
                        .background(Circle().fill(todo.done ? p.accent : .clear))
                        .frame(width: 18, height: 18)
                    if todo.done {
                        Icon("check", size: 11, weight: 2.4).foregroundStyle(p.accentForeground)
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .padding(.top, 1)
                .contentShape(Circle().inset(by: -6))
                .motion(todo.done, Motion.standard)
            }
            .buttonStyle(.fn)
            .accessibilityLabel(todo.done ? "Mark as not done" : "Mark as done")

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(todo.title.isEmpty ? "New task" : todo.title)
                            .font(FN.font(13.5))
                            .foregroundStyle(todo.done || todo.title.isEmpty ? p.textMuted : p.foreground)
                            .strikethrough(todo.done)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let bill = todo.bill {
                            Text(Money.format(bill.amount, bill.currency ?? store.settings.currency))
                                .font(FN.font(12.5))
                                .monospacedDigit()
                                .foregroundStyle(p.textSecondary)
                        }
                    }

                    if hasMeta || status != nil {
                        FlowLayout(spacing: 6, alignment: .leading) {
                            if let status {
                                HStack(spacing: 5) {
                                    Circle().fill(status.tone).frame(width: 6, height: 6)
                                    Text(status.text)
                                }
                                .font(FN.font(11.5, .medium))
                                .foregroundStyle(status.tone)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(status.subtle, in: Capsule())
                            }
                            if let due = todo.dueAt { meta("calendar", Fmt.due(due)) }
                            if let remind = todo.remindAt, !todo.done {
                                meta("bell", todo.dueAt == nil ? Fmt.due(remind) : nil)
                            }
                            if let rrule = todo.rrule {
                                meta("repeat", Recurrence.label(rrule).replacingOccurrences(of: "Every ", with: ""))
                            }
                            if let note { meta("link", note.title.isEmpty ? "Note" : note.title).frame(maxWidth: 176, alignment: .leading) }
                            if todo.priority == .high && !todo.done { meta(nil, "High priority") }
                        }
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(Motion.standard, value: hasMeta)
            }
            .buttonStyle(.fn)
        }
        .padding(14)
        .background(p.surface, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
            .strokeBorder(selected ? p.accent : (hovering ? p.borderStrong : p.border), lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: FN.radiusControl + 3, style: .continuous)
            .fill(selected ? p.accentSubtle : .clear).padding(-3))
        .opacity(dragging ? 0.4 : 1)
        .scaleEffect(dragging ? 0.97 : 1)
        .motion(hovering || dragging || selected, Motion.quick)
        .motion(todo.done, Motion.standard)
        .flashes(nav.isFlashing(todo.id), palette: p)
        .onHover { hovering = $0 }
    }

    /// One piece of the line under the title: an icon and a few words.
    private func meta(_ icon: String?, _ text: String?) -> some View {
        HStack(spacing: 4) {
            if let icon { Icon(icon, size: 12) }
            if let text { Text(text).lineLimit(1) }
        }
        .font(FN.font(12.5))
        .foregroundStyle(p.textMuted)
        .frame(height: 20)
    }
}

/// "+ New task" at the foot of a column: plain until hovered.
private struct NewTaskRow: View {
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Icon("plus", size: 15)
            Text("New task").font(FN.font(13.5)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(hovering ? p.foreground : p.textMuted)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(hovering ? p.hover : .clear, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
    }
}
