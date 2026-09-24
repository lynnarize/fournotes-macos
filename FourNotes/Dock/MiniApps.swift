import AppKit
import SwiftUI

// The drawer's mini apps. Each does one thing without opening the app, and
// each has a round button to carry on in the app when one thing isn't enough.

// MARK: - Quick note

struct NoteMini: View {
    @ObservedObject var dock: EdgeDock
    @ObservedObject private var stickies = EdgeStickies.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d
    /// Kept across closing the drawer — and quitting — so a click elsewhere
    /// never costs a half-written note.
    @AppStorage("fournotes.dock.noteDraft") private var text = ""
    @State private var showRecent = false
    @State private var saved: String?

    private var recent: [Note] {
        Array(store.liveNotes.filter(QuickNote.isQuick).sorted { $0.createdAt > $1.createdAt }.prefix(3))
    }

    var body: some View {
        DockCard(title: "Quick note", accessory: AnyView(
            DockRoundButton(icon: "arrowUpRight", help: "Open Notes") { dock.showApp { $0.tab = .notes } }
        )) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(FN.font(13))
                        .foregroundStyle(d.text)
                        .scrollContentBackground(.hidden)
                        .writingToolsBehavior(.disabled)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                    if text.isEmpty {
                        Text("Quick notes")
                            .font(FN.font(13))
                            .foregroundStyle(d.faint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 96)
                .background(d.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(d.line, lineWidth: 1))

                if let saved {
                    DockNotice(text: "Saved “\(saved)” to Notes")
                }

                if showRecent {
                    VStack(spacing: 2) {
                        if recent.isEmpty {
                            Text("Nothing jotted yet.")
                                .font(FN.font(12)).foregroundStyle(d.faint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(recent) { note in
                            DockRow {
                                dock.showApp { $0.open(ChangeLink(kind: .notes, id: note.id)) }
                            } label: {
                                HStack(spacing: 10) {
                                    DockBadgeIcon(icon: "note", tone: d.violet, size: 26)
                                    Text(note.title.isEmpty ? "Untitled" : note.title)
                                        .font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Fmt.relative(note.createdAt))
                                        .font(FN.font(11.5)).foregroundStyle(d.faint)
                                    let stuck = stickies.isStuck(note.id)
                                    Button { stickies.toggle(note.id) } label: {
                                        Icon("pin", size: 12, weight: 1.9)
                                            .foregroundStyle(stuck ? d.violet : d.faint)
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.fn)
                                    .help(stuck ? "Take off the screen edge" : "Stick to the screen edge")
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(Motion.standard, value: showRecent)
            .animation(Motion.standard, value: saved)
        } footer: {
            HStack(spacing: 8) {
                DockDisclosure(title: "Recent", open: showRecent) { showRecent.toggle() }
                Spacer()
                DockSecondaryButton(title: "Clear", disabled: text.isEmpty) { text = "" }
                DockSecondaryButton(title: "Stick", disabled: clean.isEmpty, action: stick)
                    .help("Save, and stick it to the screen edge")
                DockPrimaryButton(title: "Save", disabled: clean.isEmpty, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var clean: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Saves it as a quick note and sticks it to the edge: the drawer
    /// closes, and the note flies into a tab beside the handle.
    private func stick() {
        guard !clean.isEmpty else { return }
        let note = store.addNote { QuickNote.apply(clean, to: &$0) }
        text = ""
        stickies.stick(note.id)
    }

    private func save() {
        guard !clean.isEmpty else { return }
        let note = store.addNote { QuickNote.apply(clean, to: &$0) }
        text = ""
        saved = note.title
        Task {
            try? await Task.sleep(for: .seconds(3))
            if saved == note.title { saved = nil }
        }
    }
}

// MARK: - Today's tasks

struct TasksMini: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d
    @State private var mode = Mode.due
    @State private var draft = ""
    @State private var notice: String?

    enum Mode: Hashable { case due, anytime }

    var body: some View {
        let todos = store.liveTodos
        let due = Glance.dueByToday(todos)
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let overdue = due.filter { (DateKit.date($0.dueAt) ?? Date()) < startOfToday }
        let today = due.filter { (DateKit.date($0.dueAt) ?? Date()) >= startOfToday }
        let done = Glance.doneToday(todos)

        DockCard(title: "Today", accessory: AnyView(
            DockRoundButton(icon: "arrowUpRight", help: "Open To-Do") { dock.showApp { $0.tab = .todo } }
        )) {
            VStack(alignment: .leading, spacing: 14) {
                DockSegments(selection: $mode, options: [(.due, "Due"), (.anytime, "Anytime")])

                switch mode {
                case .due:
                    if !overdue.isEmpty {
                        group("Overdue", icon: "warning", tone: d.rose, rows: overdue)
                    }
                    if today.isEmpty && overdue.isEmpty && done.isEmpty {
                        empty("Nothing due today.")
                    } else if today.isEmpty && overdue.isEmpty {
                        group(done.count == 1 ? "Done for today" : "All \(done.count) done", icon: "check",
                              tone: d.teal, rows: Array(done.prefix(3)))
                    } else if !today.isEmpty || !done.isEmpty {
                        group("Due today", icon: "calendar", tone: d.sky, rows: today + done.prefix(3))
                    }
                case .anytime:
                    let anytime = Glance.anytime(todos)
                    if anytime.isEmpty {
                        empty("No undated tasks.")
                    } else {
                        group("No date", icon: "lines", tone: d.violet, rows: Array(anytime.prefix(6)),
                              more: anytime.count - 6)
                    }
                }

                DockField(placeholder: mode == .due ? "Add a task, like “call Budi Fri 9am”" : "Add a task",
                          text: $draft, icon: "plus", onSubmit: add)
                if let notice { DockNotice(text: notice) }
            }
            .animation(Motion.list, value: due.map(\.id) + done.map(\.id))
            .animation(Motion.standard, value: notice)
        }
    }

    private func group(_ title: String, icon: String, tone: Color, rows: [Todo], more: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DockBadgeIcon(icon: icon, tone: tone, size: 32)
                Text(title).font(FN.font(14, .medium)).foregroundStyle(d.text)
                Spacer()
                let open = rows.filter { !$0.done }.count + max(0, more)
                if open > 0 {
                    Text("\(open)").font(FN.font(12)).foregroundStyle(d.faint).monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { todo in row(todo) }
                if more > 0 {
                    Text("+\(more) more")
                        .font(FN.font(12)).foregroundStyle(d.faint)
                        .padding(.vertical, 4)
                }
            }
            .padding(.leading, 34)
            // The line down from the circle that ties the rows to it. A
            // background, so it is only as tall as the rows: a bare
            // Rectangle takes all the height it's offered.
            .background(alignment: .leading) {
                Rectangle().fill(d.line).frame(width: 1.5).padding(.leading, 15.25)
            }
        }
    }

    private func row(_ todo: Todo) -> some View {
        DockRow {
            let messages = store.toggleTodo(todo.id, done: !todo.done)
            if let first = messages.first { flash(first) }
        } label: {
            HStack(spacing: 10) {
                DockCheckbox(checked: todo.done)
                Text(todo.title.isEmpty ? "Untitled" : todo.title)
                    .font(FN.font(13))
                    .strikethrough(todo.done, color: d.muted)
                    .foregroundStyle(todo.done ? d.muted : d.text)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let due = DateKit.date(todo.dueAt), !todo.done, Self.hasTime(due) {
                    Text(Fmt.time(due)).font(FN.font(11.5)).foregroundStyle(d.faint).monospacedDigit()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel(todo.title)
        .accessibilityValue(todo.done ? "Done" : "Not done")
    }

    private func empty(_ text: String) -> some View {
        HStack(spacing: 10) {
            DockBadgeIcon(icon: "check", tone: d.teal, size: 32)
            Text(text).font(FN.font(13)).foregroundStyle(d.muted)
        }
    }

    /// End-of-day due dates are "today", not "23:59".
    private static func hasTime(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return !(c.hour == 23 && c.minute == 59) && !(c.hour == 0 && c.minute == 0)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let split = NaturalDate.splitTitle(text)
        let title = split?.title ?? text
        var due: Date? = split?.date
        if due == nil, mode == .due {
            due = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())
        }
        store.addTodo {
            $0.title = title
            $0.dueAt = due.map(DateKit.iso)
            // A time was named: remind then, as the assistant does.
            if let date = split?.date, date > Date() { $0.remindAt = DateKit.iso(date) }
        }
        draft = ""
        if let date = split?.date {
            flash("Added — due \(Fmt.due(DateKit.iso(date)))")
        } else {
            flash(mode == .due ? "Added for today" : "Added")
        }
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }
}

// MARK: - Transcribe

struct TranscribeMini: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var assistant: Assistant
    @ObservedObject private var t = QuickTranscriber.shared
    @Environment(\.dock) private var d
    @State private var notice: String?
    @State private var organizing = false

    var body: some View {
        DockCard(title: "Transcribe", accessory: AnyView(languageMenu), footerVisible: t.phase == .done) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RecordButton(phase: t.phase, level: t.levels.last ?? 0) {
                        t.isActive ? t.stop() : start()
                    }
                    // Organize clears the transcript when it's done; a new
                    // dictation started meanwhile would go with it.
                    .disabled(organizing)
                    Visualizer(levels: t.levels, live: t.phase == .listening, startedAt: t.startedAt,
                               status: status)
                }

                // Nothing to show until there are words: the card stays one row.
                if showsTranscript {
                    transcript
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }

                if case .failed(let message) = t.phase {
                    DockNotice(text: message, tone: d.rose, icon: "warning")
                    if let pane = Self.privacyPane(for: message) {
                        Button("Open System Settings") { NSWorkspace.shared.open(pane) }
                            .buttonStyle(.fn)
                            .font(FN.font(12, .medium))
                            .foregroundStyle(d.primary)
                    }
                }
                if let notice { DockNotice(text: notice) }
            }
            .animation(Motion.standard, value: t.phase)
            .animation(Motion.standard, value: notice)
        } footer: {
            HStack(spacing: 8) {
                // Icons for the two small actions, so four fit on one line.
                DockRoundButton(icon: "trash", help: "Discard", size: 32) { t.cancel() }
                    .disabled(organizing)
                DockRoundButton(icon: "copy", help: "Copy the text", size: 32) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.text, forType: .string)
                    flash("Copied")
                }
                Spacer(minLength: 4)
                DockSecondaryButton(title: organizing ? "Organizing…" : "Organize", icon: "sparkle",
                                    disabled: organizing || assistant.busy != nil) {
                    Task { await organize() }
                }
                .help("Let the assistant turn it into notes and tasks")
                DockPrimaryButton(title: "Save note", disabled: t.text.isEmpty || organizing, action: save)
            }
        }
    }

    private var showsTranscript: Bool {
        if !t.text.isEmpty { return true }
        switch t.phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    /// The privacy pane that would fix a refused permission.
    private static func privacyPane(for message: String) -> URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        if message.contains("Microphone") { return URL(string: base + "Privacy_Microphone") }
        if message.contains("Speech Recognition") { return URL(string: base + "Privacy_SpeechRecognition") }
        return nil
    }

    private var status: String {
        switch t.phase {
        case .idle: return "Ready"
        case .failed: return "Couldn't listen"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .finishing: return "Finishing…"
        case .done: return "Done"
        }
    }

    @ViewBuilder
    private var transcript: some View {
        Group {
            if t.phase == .done {
                TextEditor(text: $t.text)
                    .font(FN.font(13))
                    .foregroundStyle(d.text)
                    .scrollContentBackground(.hidden)
                    .writingToolsBehavior(.disabled)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
            } else if t.text.isEmpty {
                Text(t.phase == .listening ? "Go ahead — words appear as you speak."
                     : "Press record and talk. The words stay on this Mac.")
                    .font(FN.font(13))
                    .foregroundStyle(d.faint)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(t.text)
                            .font(FN.font(13))
                            .foregroundStyle(d.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("end")
                    }
                    .onChange(of: t.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .frame(height: 92)
        .background(d.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(d.line, lineWidth: 1))
    }

    private var languageMenu: some View {
        MenuButton(help: "Language to listen for", entries: {
            t.languages.map { language in
                .item(language.name, checked: language.id == t.localeId) { t.localeId = language.id }
            }
        }) {
            HStack(spacing: 5) {
                Text(t.languageName).lineLimit(1)
                Icon("chevronDown", size: 11)
            }
            .font(FN.font(12, .medium))
            .foregroundStyle(d.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(d.raised, in: Capsule())
        }
        .disabled(t.isActive)
        .frame(maxWidth: 170, alignment: .trailing)
    }

    private func start() {
        notice = nil
        t.start()
    }

    private func save() {
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addNote {
            QuickNote.apply(text, to: &$0)
            $0.source = .recording
            $0.tags.append("voice")
        }
        t.cancel()
        flash("Saved to Notes")
    }

    private func organize() async {
        let text = t.text
        organizing = true
        defer { organizing = false }
        guard let reply = await assistant.writeUp(text) else {
            flash("The assistant is busy. Try again in a moment.")
            return
        }
        if reply.isError {
            notice = reply.content
        } else {
            t.cancel()
            flash(reply.filed.isEmpty ? "Written up" : reply.filed.prefix(3).joined(separator: " · "))
        }
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if notice == text { notice = nil }
        }
    }
}

private struct RecordButton: View {
    @Environment(\.dock) private var d
    let phase: QuickTranscriber.Phase
    let level: Float
    let action: () -> Void

    private var live: Bool { phase == .listening || phase == .starting }

    var body: some View {
        Button(action: action) {
            ZStack {
                // A ring that breathes with the voice.
                Circle()
                    .stroke(d.rose.opacity(0.35), lineWidth: 3)
                    .scaleEffect(live ? 1 + CGFloat(level) * 0.28 : 1)
                    .opacity(live ? 1 : 0)
                Circle()
                    .fill(live ? d.rose : d.primary)
                Icon(live ? "stop" : "mic", size: 20, weight: 2)
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            .contentShape(Circle())
            .animation(.linear(duration: 0.08), value: level)
            .animation(Motion.standard, value: live)
        }
        .buttonStyle(.fn)
        .disabled(phase == .finishing)
        .help(live ? "Stop" : "Record")
        .accessibilityLabel(live ? "Stop dictation" : "Start dictation")
    }
}

/// Bars that scroll right to left as the level arrives — the newest on the right.
private struct Visualizer: View {
    @Environment(\.dock) private var d
    let levels: [Float]
    let live: Bool
    let startedAt: Date?
    let status: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let count = levels.count
                guard count > 0 else { return }
                let step = size.width / CGFloat(count)
                let barWidth = max(2, step * 0.5)
                let mid = size.height / 2 + 6
                for (i, level) in levels.enumerated() {
                    let height = max(3, CGFloat(level) * (size.height - 26))
                    let x = CGFloat(i) * step + (step - barWidth) / 2
                    let rect = CGRect(x: x, y: mid - height / 2, width: barWidth, height: height)
                    // Older bars fade, so the motion reads right to left.
                    let age = Double(i) / Double(max(1, count - 1))
                    let color = live ? (i % 2 == 0 ? d.primary : d.sky) : d.faint
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(color.opacity(live ? 0.35 + 0.65 * age : 0.5)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 6) {
                if live {
                    Circle().fill(d.rose).frame(width: 6, height: 6)
                }
                Text(status)
                Spacer()
                if let startedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(startedAt)))
                            .monospacedDigit()
                    }
                }
            }
            .font(FN.font(11.5, .medium))
            .foregroundStyle(d.muted)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .frame(height: 66)
        .frame(maxWidth: .infinity)
        .background(d.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(d.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(status)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Spend

struct SpendMini: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d
    @State private var draft = ""
    @State private var notice: String?

    private var currency: String { store.settings.currency }

    var body: some View {
        let spend = Glance.spend(draft)
        let txs = store.liveTransactions
        let today = DateKit.localDate()
        let month = DateKit.localMonth()

        DockCard(title: "Spend", accessory: AnyView(
            DockRoundButton(icon: "clipboard", help: "Paste a payment notification", action: paste)
        )) {
            VStack(alignment: .leading, spacing: 12) {
                DockField(placeholder: "coffee 25k, or paste a payment message",
                          text: $draft, icon: "wallet", onSubmit: add)

                if let spend {
                    HStack(spacing: 10) {
                        DockBadgeIcon(icon: categoryIcon(spend.category), tone: d.tone(forCategory: spend.category))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spend.merchant).font(FN.font(13, .medium)).foregroundStyle(d.text).lineLimit(1)
                            Text(spend.category).font(FN.font(11.5)).foregroundStyle(d.muted)
                        }
                        Spacer(minLength: 6)
                        Text((spend.amount < 0 ? "+" : "") + Money.format(abs(spend.amount), currency))
                            .font(FN.font(13, .semibold)).monospacedDigit()
                            .foregroundStyle(spend.amount < 0 ? d.teal : d.text)
                        DockPrimaryButton(title: "Add", action: add)
                    }
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if spend == nil, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    DockNotice(text: "Add an amount, like 25k", tone: d.muted, icon: "info")
                }
                if let notice { DockNotice(text: notice) }

                HStack(spacing: 8) {
                    stat("Today", FinanceMath.spend(txs.filter { $0.date == today }, currency))
                    stat("This month", FinanceMath.spend(txs.filter { $0.date.hasPrefix(month) }, currency))
                }

                VStack(spacing: 2) {
                    ForEach(recent(txs)) { tx in
                        DockRow {
                            dock.showApp { $0.open(ChangeLink(kind: .transactions, id: tx.id)) }
                        } label: {
                            HStack(spacing: 10) {
                                DockBadgeIcon(icon: categoryIcon(tx.category),
                                              tone: d.tone(forCategory: tx.category), size: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tx.merchant).font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                                    Text("\(tx.category) · \(Fmt.relative(tx.createdAt))")
                                        .font(FN.font(11.5)).foregroundStyle(d.faint).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Text((tx.amount < 0 ? "+" : "") + Money.format(abs(tx.amount), tx.currency))
                                    .font(FN.font(12.5, .medium)).monospacedDigit()
                                    .foregroundStyle(tx.amount < 0 ? d.teal : d.text)
                            }
                        }
                    }
                }
            }
            .animation(Motion.standard, value: spend)
            .animation(Motion.standard, value: notice)
        }
    }

    private func recent(_ txs: [Transaction]) -> [Transaction] {
        Array(txs.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }.prefix(3))
    }

    private func stat(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FN.font(11.5)).foregroundStyle(d.muted)
            Text(amount == 0 ? "Nothing yet" : Money.format(amount, currency, compact: true))
                .font(FN.font(15, .semibold)).monospacedDigit()
                .foregroundStyle(amount == 0 ? d.faint : d.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(d.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            flash("The clipboard has no text.")
            return
        }
        draft = String(text.prefix(400))
        if Glance.spend(draft) == nil { flash("No amount found in what was copied.") }
    }

    private func add() {
        guard let spend = Glance.spend(draft) else { return }
        store.addTransaction {
            $0.merchant = spend.merchant
            $0.amount = spend.amount
            $0.category = spend.category
        }
        draft = ""
        flash("Logged \(Money.format(abs(spend.amount), currency)) · \(spend.merchant)")
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }
}

// MARK: - Coming up

struct BillsMini: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d
    @State private var notice: String?

    var body: some View {
        let currency = store.settings.currency
        let items = Glance.upcoming(todos: store.liveTodos, transactions: store.liveTransactions,
                                    currency: currency, limit: 4)
        DockCard(title: "Coming up", accessory: AnyView(
            DockRoundButton(icon: "arrowUpRight", help: "Open Finance") { dock.showApp { $0.tab = .finance } }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                if items.isEmpty {
                    HStack(spacing: 10) {
                        DockBadgeIcon(icon: "check", tone: d.teal, size: 32)
                        Text("Nothing due in the next five weeks.")
                            .font(FN.font(13)).foregroundStyle(d.muted)
                    }
                }
                ForEach(items) { item in row(item) }
                if let notice { DockNotice(text: notice).padding(.top, 6) }
            }
            .animation(Motion.list, value: items.map(\.id))
            .animation(Motion.standard, value: notice)
        }
    }

    private func row(_ item: Glance.Payment) -> some View {
        let days = FinanceMath.daysFromToday(item.date)
        return HStack(spacing: 10) {
            DockBadgeIcon(icon: categoryIcon(item.category), tone: d.tone(forCategory: item.category))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(FN.font(13, .medium)).foregroundStyle(d.text).lineLimit(1)
                Text("\(item.subscription == nil ? item.sub : "Likely") · \(FinanceMath.inDays(days))")
                    .font(FN.font(11.5)).foregroundStyle(days < 0 ? d.rose : d.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Money.format(item.amount, item.currency, compact: true))
                .font(FN.font(13, .semibold)).monospacedDigit().foregroundStyle(d.text)
                .fixedSize()
            if let todoId = item.todoId {
                if days < 0 { DockTag(text: "Overdue", tone: d.rose) }
                DockRoundButton(icon: "check", help: "Mark paid and log the payment") {
                    store.toggleTodo(todoId, done: true)
                    flash("Marked paid · \(item.title)")
                }
            }
        }
        .padding(.vertical, 6)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }
}

// MARK: - Ask

struct AskMini: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var assistant: Assistant
    @Environment(\.dock) private var d
    @State private var draft = ""
    /// The question sent from here, so the reply shown is its answer — not
    /// whatever the main window's chat said last.
    @State private var askedId: UUID?
    /// Sent, not yet seen in the conversation.
    @State private var pending: (text: String, after: Int)?

    private static let suggestions = ["What's due this week?", "Food spend this month?", "Remind me to stretch at 4pm"]

    var body: some View {
        DockCard(title: "Ask", accessory: AnyView(
            DockRoundButton(icon: "arrowUpRight", help: "Continue in the app") {
                let text = draft
                dock.showApp { $0.assistantDraft = text }
            }
        )) {
            VStack(alignment: .leading, spacing: 12) {
                if let busy = assistant.busy, waiting {
                    // Animated only while the drawer is open: it's drawn,
                    // hidden, while closed.
                    if dock.isOpen { TypingDots(label: busy) } else { Text(busy).font(FN.font(12.5)) }
                } else if let reply {
                    replyView(reply)
                } else {
                    Text("Ask about your notes, tasks and money — or tell it to add something.")
                        .font(FN.font(12.5)).foregroundStyle(d.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowChips(items: Self.suggestions) { draft = $0 }
                }

                HStack(spacing: 8) {
                    DockField(placeholder: "Ask or tell Four Notes…", text: $draft, icon: "sparkle", onSubmit: send)
                    Button(action: send) {
                        Icon("send", size: 15, weight: 2)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(d.primary, in: Circle())
                            .opacity(canSend ? 1 : 0.45)
                    }
                    .buttonStyle(.fn)
                    .disabled(!canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
            }
            .animation(Motion.standard, value: assistant.busy)
            .animation(Motion.standard, value: reply?.id)
            .onChange(of: assistant.messages.count) { _, count in track(count) }
        }
    }

    /// Waiting on a question sent from here.
    private var waiting: Bool { (pending != nil || askedId != nil) && reply == nil }

    private func track(_ count: Int) {
        if let pending {
            if let question = assistant.messages.dropFirst(min(pending.after, count))
                .first(where: { $0.role == .user && $0.content == pending.text }) {
                askedId = question.id
                self.pending = nil
            } else if count < pending.after {
                self.pending = nil
            }
        }
        // Cleared elsewhere: the question is gone, and so is its answer.
        if let askedId, !assistant.messages.contains(where: { $0.id == askedId }) { self.askedId = nil }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && assistant.busy == nil
    }

    /// The reply to the question asked from here: what the assistant said
    /// after it, before anyone asked anything else.
    private var reply: UIMessage? {
        guard let askedId, let index = assistant.messages.firstIndex(where: { $0.id == askedId }) else { return nil }
        return assistant.messages[(index + 1)...].prefix { $0.role != .user }.last { $0.role == .assistant }
    }

    private func replyView(_ reply: UIMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(LocalizedStringKey(reply.content))
                    .font(FN.font(13))
                    .foregroundStyle(reply.isError ? d.rose : d.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(reply.filed.prefix(3).enumerated()), id: \.offset) { index, filed in
                let link = index < reply.links.count ? reply.links[index] : nil
                DockRow {
                    if let link { dock.showApp { $0.open(link) } }
                } label: {
                    HStack(spacing: 8) {
                        Icon("check", size: 12, weight: 2.2).foregroundStyle(d.teal)
                        Text(filed).font(FN.font(12.5)).foregroundStyle(d.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if link != nil { Text("Show").font(FN.font(12)).foregroundStyle(d.primary) }
                    }
                }
            }
            if let who = reply.answererName {
                Text("Answered by \(who)").font(FN.font(11)).foregroundStyle(d.faint)
            }
        }
        .padding(12)
        .background(d.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, assistant.busy == nil else { return }
        draft = ""
        askedId = nil
        pending = (text, assistant.messages.count)
        Task { await assistant.send(text) }
    }

}

/// Suggestion chips, wrapped onto as many lines as they need.
private struct FlowChips: View {
    @Environment(\.dock) private var d
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6, alignment: .leading) {
            ForEach(items, id: \.self) { item in
                Button { pick(item) } label: {
                    Text(item)
                        .font(FN.font(12, .medium))
                        .foregroundStyle(d.text)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(d.raised, in: Capsule())
                        .overlay(Capsule().stroke(d.line, lineWidth: 1))
                }
                .buttonStyle(.fn)
            }
        }
    }
}

// MARK: - A tappable row

/// A full-width row that highlights under the pointer.
struct DockRow<Label: View>: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(hovering ? d.raised.opacity(0.7) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
    }
}
