import AppKit
import SwiftUI

// A task opened beside the board, in the same card as the Notes editor.
// Ported from the TaskPanel part of src/components/TodoView.tsx.

struct TaskPanel: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter

    let todo: Todo
    let isNew: Bool
    var expanded = false
    var onToggleExpand: () -> Void = {}
    let onClose: () -> Void
    let onMove: (BoardColumn) -> Void

    @State private var suggestion: (at: String, reason: String)?
    @FocusState private var titleFocused: Bool
    @FocusState private var detailsFocused: Bool

    private var note: Note? {
        todo.noteId.flatMap { id in store.liveNotes.first { $0.id == id } }
    }

    private var rule: Recurrence.Rule? { Recurrence.parse(todo.rrule) }

    private var autoSuggestion: (at: String, reason: String)? {
        guard !todo.done, todo.remindAt == nil else { return nil }
        return Insights.suggestReminder(todo, store.liveTodos)
    }

    private var shownSuggestion: (at: String, reason: String)? { suggestion ?? autoSuggestion }

    private var created: String {
        guard let d = DateKit.date(todo.createdAt) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    properties
                    Divider().overlay(p.line).padding(.vertical, 24)
                    details
                    if let rrule = todo.rrule {
                        Text("\(Recurrence.label(rrule)) · completing it schedules the next one")
                            .font(FN.small)
                            .foregroundStyle(p.muted)
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, expanded ? 48 : 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: expanded ? 760 : .infinity)
                .frame(maxWidth: .infinity)
            }
        }
        .background(p.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 1))
        .shadow(color: p.shadow, radius: 10, y: 3)
        .frame(maxHeight: expanded ? .infinity : 760)
        .onAppear { if isNew { titleFocused = true } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            IconButton("collapseRight", size: 20, box: 30, help: "Close task", action: onClose)
            IconButton(expanded ? "shrink" : "expand", size: 18, box: 30,
                       help: expanded ? "Back to side panel" : "Open full width", action: onToggleExpand)

            Rectangle().fill(p.line).frame(width: 1, height: 22).padding(.horizontal, 4)

            HStack(spacing: 4) {
                Text("To-Do").foregroundStyle(p.muted)
                Icon("chevron", size: 12).foregroundStyle(p.muted)
                Text(todo.title.isEmpty ? "New task" : todo.title).foregroundStyle(p.text)
            }
            .font(FN.body)
            .lineLimit(1)

            Spacer()

            IconMenu("more", size: 20, help: "More actions") {
                [
                    .item("Add to Google Calendar") { openURL(Calendars.googleURL(todo)) },
                    .item("Apple / Outlook (.ics)…") { Calendars.exportIcs(todo, toasts: toasts) },
                    .divider,
                    .item("Delete task", destructive: true) {
                        store.remove(.todos, todo.id)
                        toasts.push("Task deleted")
                        onClose()
                    },
                ]
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    // MARK: - Title and details

    private var title: some View {
        CommittedField(placeholder: "New task", value: todo.title,
                       font: FN.serif(30), axis: .vertical) { value in
            store.updateTodo(todo.id) { $0.title = value.replacingOccurrences(of: "\n", with: " ") }
        }
        .tracking(-0.6)
        .foregroundStyle(todo.done ? p.faint : p.text)
        .strikethrough(todo.done)
        .focused($titleFocused)
        .padding(.bottom, 20)
    }

    private var details: some View {
        CommittedField(placeholder: "Add details, links or steps…", value: todo.notes ?? "",
                       font: .system(size: 15), axis: .vertical, minHeight: 110) { value in
            store.updateTodo(todo.id) { $0.notes = value.isEmpty ? nil : value }
        }
        .lineSpacing(3)
        .focused($detailsFocused)
    }

    // MARK: - Properties

    private var properties: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 2) {
            prop("status", "Status") {
                HStack(spacing: 4) {
                    ForEach(BoardColumn.allCases) { col in
                        Button { onMove(col) } label: {
                            Text(col.label)
                                .font(FN.body)
                                .fontWeight(todo.column == col ? .medium : .regular)
                                .foregroundStyle(todo.column == col ? p.text : p.faint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(todo.column == col ? p.mix(col.hue(p), p.boardLabelMix) : .clear,
                                            in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.fn)
                    }
                }
                .motion(todo.column, Motion.quick)
            }

            prop("calendar", "Date") {
                OptionalDateField(value: todo.dueAt) { iso in
                    store.updateTodo(todo.id) {
                        $0.dueAt = iso
                        $0.rrule = recurrenceAnchored(to: iso)
                    }
                }
            }

            prop("bell", "Alarm") {
                VStack(alignment: .leading, spacing: 6) {
                    OptionalDateField(value: todo.remindAt) { iso in
                        suggestion = nil
                        store.updateTodo(todo.id) { $0.remindAt = iso; $0.reminded = false }
                    }
                    if let s = shownSuggestion {
                        HStack(spacing: 8) {
                            Icon("sparkle", size: 12)
                            Text("\(Fmt.due(s.at)) · \(s.reason)")
                                .font(FN.small)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Use") {
                                store.updateTodo(todo.id) { $0.remindAt = s.at; $0.reminded = false }
                                suggestion = nil
                            }
                            .buttonStyle(.fn)
                            .font(FN.font(12, .medium))
                            .foregroundStyle(p.accent)
                        }
                        .foregroundStyle(p.text)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(p.stickyBlue, in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                        .transition(.opacity.combined(with: .offset(y: -6)))
                    } else if !todo.done && todo.remindAt == nil {
                        Button("✨ Suggest a time") {
                            if let s = Insights.suggestReminder(todo, store.liveTodos) {
                                suggestion = s
                            } else {
                                toasts.push("Complete a few tasks first so the app can learn when you usually get things done.")
                            }
                        }
                        .buttonStyle(.fn)
                        .font(FN.small)
                        .foregroundStyle(p.accent)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .animation(Motion.standard, value: shownSuggestion?.at ?? "none")
            }

            prop("repeat", "Repeat") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { rule?.freq.rawValue ?? "" },
                        set: { raw in
                            store.updateTodo(todo.id) {
                                $0.rrule = raw.isEmpty ? nil
                                    : recurrence(freq: Freq(rawValue: raw) ?? .MONTHLY,
                                                 interval: rule?.interval ?? 1)
                            }
                        })) {
                            Text("Doesn't repeat").tag("")
                            Text("Daily").tag("DAILY")
                            Text("Weekly").tag("WEEKLY")
                            Text("Monthly").tag("MONTHLY")
                            Text("Yearly").tag("YEARLY")
                        }
                        .labelsHidden()
                        .fixedSize()

                    if let rule {
                        Text("every").font(FN.body).foregroundStyle(p.muted)
                        Stepper(value: Binding(
                            get: { rule.interval },
                            set: { newValue in
                                store.updateTodo(todo.id) {
                                    $0.rrule = recurrence(freq: rule.freq,
                                                          interval: max(1, newValue))
                                }
                            }
                        ), in: 1...99) {
                            Text("\(rule.interval)").font(FN.body).monospacedDigit()
                        }
                        .transition(.opacity.combined(with: .offset(x: -6)))
                    }
                }
                .animation(Motion.standard, value: rule != nil)
            }

            prop("flag", "Priority") {
                Picker("", selection: Binding(
                    get: { todo.priority },
                    set: { value in store.updateTodo(todo.id) { $0.priority = value } })) {
                        Text("High").tag(Priority.high)
                        Text("Medium").tag(Priority.medium)
                        Text("Low").tag(Priority.low)
                    }
                    .labelsHidden()
                    .fixedSize()
            }

            prop("bill", "Bill") {
                HStack(spacing: 8) {
                    AmountField(value: todo.bill?.amount ?? 0, currency: store.settings.currency,
                                placeholder: "Empty", alignment: .leading, emptyIsZero: true) { amount in
                        store.updateTodo(todo.id) {
                            $0.bill = amount > 0
                                ? Bill(amount: amount,
                                       currency: todo.bill?.currency,
                                       category: todo.bill?.category ?? "Bills & Utilities")
                                : nil
                        }
                    }
                    .font(FN.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(width: 130)
                    .background(p.hover.opacity(0.6),
                                in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
                    .help("Logs the spending when the task is done")

                    if let bill = todo.bill {
                        Picker("", selection: Binding(
                            get: { bill.category },
                            set: { category in
                                store.updateTodo(todo.id) { $0.bill?.category = category }
                            })) {
                                ForEach(store.categories.filter { $0 != "Income" }, id: \.self) { c in
                                    Text(c).tag(c)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .transition(.opacity.combined(with: .offset(x: -6)))
                    }
                }
                .animation(Motion.standard, value: todo.bill != nil)
            }

            prop("link", "Note") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(
                        get: { todo.noteId ?? "" },
                        set: { id in store.updateTodo(todo.id) { $0.noteId = id.isEmpty ? nil : id } })) {
                            Text("Empty").tag("")
                            ForEach(store.liveNotes) { n in
                                Text(n.title.isEmpty ? "Untitled" : n.title).tag(n.id)
                            }
                        }
                        .labelsHidden()

                    if let note {
                        Button("Open") { nav.open(ChangeLink(kind: .notes, id: note.id)) }
                            .buttonStyle(.fn)
                            .font(FN.small)
                            .foregroundStyle(p.accent)
                            .transition(.opacity.combined(with: .offset(x: -5)))
                    }
                }
                .animation(Motion.standard, value: note != nil)
            }

            prop("clock", "Created") {
                Text(created).font(FN.body).foregroundStyle(p.text)
            }
        }
    }

    /// Rebuild the rule from its frequency and interval while keeping a
    /// month-end date anchored to the task's actual due date.
    private func recurrence(freq: Freq, interval: Int) -> String? {
        let base = Recurrence.make(freq, interval)
        let anchor = DateKit.date(todo.dueAt) ?? DateKit.date(todo.remindAt)
        if freq == .MONTHLY || freq == .YEARLY, let anchor {
            return Recurrence.normalised(base, anchoredTo: anchor)
        }
        guard rule?.freq == freq else { return base }
        return Recurrence.make(freq, interval, monthDay: rule?.monthDay)
    }

    private func recurrenceAnchored(to iso: String?) -> String? {
        guard let rule else { return nil }
        let base = Recurrence.make(rule.freq, rule.interval)
        guard let date = DateKit.date(iso) else {
            return Recurrence.make(rule.freq, rule.interval, monthDay: rule.monthDay)
        }
        return Recurrence.normalised(base, anchoredTo: date)
    }

    /// One property row: icon and name on the left, the value on the right.
    private func prop<Content: View>(_ icon: String, _ label: String,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            HStack(spacing: 10) {
                Icon(icon, size: 17)
                Text(label).lineLimit(1)
            }
            .font(FN.body)
            .foregroundStyle(p.muted)
            .frame(width: 128, alignment: .leading)
            .frame(minHeight: 36)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 36)
        }
    }

    private func openURL(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A date-and-time field that can be empty, matching `<input type="datetime-local">`.
struct OptionalDateField: View {
    @Environment(\.palette) private var p
    let value: String?
    let onChange: (String?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let date = DateKit.date(value) {
                DatePicker("", selection: Binding(
                    get: { date },
                    set: { onChange(DateKit.iso($0)) }),
                    displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Button { onChange(nil) } label: {
                    Icon("x", size: 12).foregroundStyle(p.faint)
                }
                .buttonStyle(.fn)
                .help("Clear")
                .transition(.opacity.combined(with: .offset(x: -5)))
            } else {
                Button("Empty") { onChange(DateKit.iso(defaultDate)) }
                    .buttonStyle(.fn)
                    .font(FN.body)
                    .foregroundStyle(p.faint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .transition(.opacity.combined(with: .offset(x: 5)))
            }
        }
        .animation(Motion.standard, value: value != nil)
    }

    /// A sensible first pick: the next full hour.
    private var defaultDate: Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }
}

// MARK: - Calendar export

enum Calendars {
    private static func stamp(_ iso: String) -> String {
        guard let d = DateKit.date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    private static func window(_ todo: Todo) -> (start: String, end: String) {
        let start = todo.dueAt ?? todo.remindAt ?? DateKit.nowIso()
        let end = DateKit.date(start).map { DateKit.iso($0.addingTimeInterval(1800)) } ?? start
        return (start, end)
    }

    /// Opens Google Calendar prefilled — works without OAuth.
    static func googleURL(_ todo: Todo) -> URL? {
        let (start, end) = window(todo)
        var c = URLComponents(string: "https://calendar.google.com/calendar/render")
        var items = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: todo.title),
            URLQueryItem(name: "details", value: todo.notes ?? "Created with Four Notes"),
            URLQueryItem(name: "dates", value: "\(stamp(start))/\(stamp(end))"),
        ]
        if let rrule = todo.rrule {
            let body = rrule.replacingOccurrences(of: "^RRULE:", with: "",
                                                  options: [.regularExpression, .caseInsensitive])
            items.append(URLQueryItem(name: "recur", value: "RRULE:\(body)"))
        }
        c?.queryItems = items
        return c?.url
    }

    /// .ics file for Apple Calendar / Outlook, with a built-in alarm.
    @MainActor
    static func exportIcs(_ todo: Todo, toasts: ToastCenter) {
        let (start, end) = window(todo)
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ",", with: "\\,")
                .replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: "\n", with: "\\n")
        }
        var lines = [
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Four Notes//EN", "BEGIN:VEVENT",
            "UID:\(todo.id)@fournotes", "DTSTAMP:\(stamp(DateKit.nowIso()))",
            "DTSTART:\(stamp(start))", "DTEND:\(stamp(end))", "SUMMARY:\(esc(todo.title))",
            "DESCRIPTION:\(esc(todo.notes ?? ""))",
        ]
        if let rrule = todo.rrule {
            lines.append("RRULE:" + rrule.replacingOccurrences(
                of: "^RRULE:", with: "", options: [.regularExpression, .caseInsensitive]))
        }
        lines += ["BEGIN:VALARM", "TRIGGER:-PT10M", "ACTION:DISPLAY",
                  "DESCRIPTION:\(esc(todo.title))", "END:VALARM", "END:VEVENT", "END:VCALENDAR"]

        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(todo.title.prefix(40)) + ".ics"
        panel.allowedContentTypes = [.calendarEvent]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try lines.joined(separator: "\r\n").write(to: url, atomically: true, encoding: .utf8)
            toasts.push("Saved \(url.lastPathComponent)")
        } catch {
            toasts.push("Could not save: \(error.localizedDescription)", tone: .error)
        }
    }
}
