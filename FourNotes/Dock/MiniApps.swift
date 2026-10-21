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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 9)
                    if text.isEmpty {
                        Text("Jot something down")
                            .font(FN.font(13))
                            .foregroundStyle(d.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 84)
                .background(d.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(d.hair, lineWidth: 1))

                if let saved {
                    DockNotice(text: "Saved “\(saved)” to Notes")
                }

                if showRecent {
                    VStack(alignment: .leading, spacing: 0) {
                        if recent.isEmpty {
                            Text("Nothing jotted yet.")
                                .font(FN.font(12)).foregroundStyle(d.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DockList(items: recent) { note in
                            DockRow {
                                dock.showApp { $0.open(ChangeLink(kind: .notes, id: note.id)) }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(note.title.isEmpty ? "Untitled" : note.title)
                                        .font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Fmt.relative(note.createdAt))
                                        .font(FN.font(11.5)).foregroundStyle(d.muted)
                                    let stuck = stickies.isStuck(note.id)
                                    Button { stickies.toggle(note.id) } label: {
                                        Icon("pin", size: 12, weight: 1.9)
                                            .foregroundStyle(stuck ? d.accent : d.muted)
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
            HStack(spacing: 6) {
                DockDisclosure(title: "Recent", open: showRecent) { showRecent.toggle() }
                    .padding(.leading, -8)
                Spacer()
                if !text.isEmpty {
                    DockPlainButton(title: "Clear") { text = "" }
                        .transition(.opacity)
                }
                DockSecondaryButton(title: "Stick", icon: "pin", disabled: clean.isEmpty, action: stick)
                    .help("Save, and stick it to the screen edge")
                DockPrimaryButton(title: "Save", disabled: clean.isEmpty, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .animation(Motion.quick, value: text.isEmpty)
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
            VStack(alignment: .leading, spacing: 10) {
                DockSegments(selection: $mode, options: [(.due, "Due"), (.anytime, "Anytime")])

                switch mode {
                case .due:
                    if !overdue.isEmpty {
                        group("Overdue", tone: d.danger, rows: overdue)
                    }
                    if today.isEmpty && overdue.isEmpty && done.isEmpty {
                        empty("Nothing due today.")
                    } else if today.isEmpty && overdue.isEmpty {
                        group(done.count == 1 ? "Done for today" : "All \(done.count) done",
                              rows: Array(done.prefix(3)))
                    } else if !today.isEmpty || !done.isEmpty {
                        group("Due today", rows: today + done.prefix(3))
                    }
                case .anytime:
                    let anytime = Glance.anytime(todos)
                    if anytime.isEmpty {
                        empty("No undated tasks.")
                    } else {
                        group("No date", rows: Array(anytime.prefix(6)), more: anytime.count - 6)
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

    /// A small label and its count over the rows — red for what's overdue.
    private func group(_ title: String, tone: Color? = nil, rows: [Todo], more: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                let open = rows.filter { !$0.done }.count + max(0, more)
                if open > 0 { Text("\(open)").monospacedDigit() }
            }
            .font(FN.font(11))
            .foregroundStyle(tone ?? d.muted)
            .padding(.bottom, 2)

            DockList(items: rows) { todo in row(todo) }
            if more > 0 {
                Text("+\(more) more")
                    .font(FN.font(12)).foregroundStyle(d.muted)
                    .padding(.vertical, 4)
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
                    Text(Fmt.time(due)).font(FN.font(12)).foregroundStyle(d.muted).monospacedDigit()
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityLabel(todo.title)
        .accessibilityValue(todo.done ? "Done" : "Not done")
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(FN.font(13)).foregroundStyle(d.secondary)
            .frame(minHeight: 30)
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
        DockCard(title: "Transcribe", accessory: AnyView(accessory), footerVisible: showsActions, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RecordButton(phase: t.phase) {
                        t.isActive ? t.stop() : start()
                    }
                    // Organize clears the transcript when it's done; a new
                    // dictation started meanwhile would go with it.
                    .disabled(organizing)
                    if t.phase == .listening {
                        LevelMeter(levels: t.levels, status: status)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status).font(FN.font(13, .medium)).foregroundStyle(d.text)
                            Text(helper)
                                .font(FN.font(12)).foregroundStyle(d.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // Nothing to show until there are words: the card stays one row.
                if showsTranscript {
                    transcript
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }

                if case .failed(let message) = t.phase {
                    DockNotice(text: message, tone: d.danger, icon: "warning")
                    if let pane = Self.privacyPane(for: message) {
                        Button("Open System Settings") { NSWorkspace.shared.open(pane) }
                            .buttonStyle(.fn)
                            .font(FN.font(12, .medium))
                            .foregroundStyle(d.text)
                            .underline()
                    }
                }
                if let notice { DockNotice(text: notice) }
            }
            .animation(Motion.standard, value: t.phase)
            .animation(Motion.standard, value: notice)
        } footer: {
            HStack(spacing: 6) {
                // Icons for the two small actions, so four fit on one line.
                DockRoundButton(icon: "trash", help: "Discard", size: 28, look: .bordered) { t.cancel() }
                    .disabled(organizing)
                DockRoundButton(icon: "copy", help: "Copy the text", size: 28, look: .bordered) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(t.text, forType: .string)
                    flash("Copied")
                }
                .disabled(t.text.isEmpty)
                Spacer(minLength: 4)
                // Saving and organizing wait for the last words to arrive.
                DockSecondaryButton(title: organizing ? "Organizing…" : "Organize", icon: "sparkle",
                                    disabled: organizing || assistant.busy != nil || t.phase != .done) {
                    Task { await organize() }
                }
                .help("Let the assistant turn it into notes and tasks")
                DockPrimaryButton(title: "Save note", disabled: t.text.isEmpty || organizing || t.phase != .done,
                                  action: save)
            }
        }
    }

    /// While listening: what's being said, and what can be done with it.
    private var showsActions: Bool { t.phase == .done || t.phase == .listening }

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

    private var helper: String {
        switch t.phase {
        case .idle: return "Press record and talk. The words stay on this Mac."
        case .failed: return "Press record to try again."
        case .starting: return "Getting the microphone ready."
        case .listening: return "Words appear as you speak."
        case .finishing: return "Catching the last words."
        case .done: return "Edit it if you like, then save it as a note."
        }
    }

    /// The language to listen for — or, while listening, how long it has.
    @ViewBuilder
    private var accessory: some View {
        if t.phase == .listening, let startedAt = t.startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                HStack(spacing: 6) {
                    Circle().fill(d.danger).frame(width: 7, height: 7)
                    Text("Listening \(Self.clock(context.date.timeIntervalSince(startedAt)))")
                        .monospacedDigit()
                }
                .font(FN.font(12))
                .foregroundStyle(d.danger)
            }
        } else {
            languageMenu
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
                    .lineSpacing(3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
            } else if t.text.isEmpty {
                Text(t.phase == .listening ? "Go ahead — words appear as you speak."
                     : "Press record and talk. The words stay on this Mac.")
                    .font(FN.font(13))
                    .foregroundStyle(d.muted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(t.text)
                            .font(FN.font(13))
                            .lineSpacing(3)
                            .foregroundStyle(d.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .id("end")
                    }
                    .onChange(of: t.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .frame(height: 84)
        .background(d.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(d.hair, lineWidth: 1))
    }

    private var languageMenu: some View {
        MenuButton(help: "Language to listen for", entries: {
            t.languages.map { language in
                .item(language.name, checked: language.id == t.localeId) { t.localeId = language.id }
            }
        }) {
            DockMenuLabel(title: t.languageName)
        }
        .disabled(t.isActive)
        .frame(maxWidth: 170, alignment: .trailing)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
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

/// Record: a red dot on the card's colour. Listening: a red stop button.
private struct RecordButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let phase: QuickTranscriber.Phase
    let action: () -> Void

    private var live: Bool { phase == .listening || phase == .starting }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(live ? d.danger : hovering ? d.fill : d.card)
                    .overlay(Circle().strokeBorder(live ? .clear : d.hair, lineWidth: 1))
                if live {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.white)
                        .frame(width: 12, height: 12)
                } else {
                    Circle().fill(d.danger).frame(width: 14, height: 14)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .animation(Motion.standard, value: live)
        }
        .buttonStyle(.fn)
        .disabled(phase == .finishing)
        .onHover { hovering = $0 }
        .help(live ? "Stop" : "Record")
        .accessibilityLabel(live ? "Stop dictation" : "Start dictation")
    }
}

/// The input level as bars, the newest on the right, the older ones fading.
private struct LevelMeter: View {
    @Environment(\.dock) private var d
    let levels: [Float]
    let status: String

    var body: some View {
        Canvas { context, size in
            let bar: CGFloat = 3, step: CGFloat = 6
            let fits = max(1, Int((size.width + step - bar) / step))
            let shown = Array(levels.suffix(fits))
            for (i, level) in shown.enumerated() {
                let height = max(4, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: bar, height: height)
                let age = Double(i) / Double(max(1, shown.count - 1))
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2),
                             with: .color(d.danger.opacity(0.5 + 0.5 * age)))
            }
        }
        .frame(height: 32)
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(status)
    }
}

// MARK: - Spend

struct SpendMini: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d
    @State private var draft = ""
    @State private var notice: String?
    /// The spending just logged, offered back for a few seconds.
    @State private var logged: Logged?

    private struct Logged: Equatable {
        var id: String
        var text: String
    }

    private var currency: String { store.settings.currency }

    var body: some View {
        let spend = Glance.spend(draft)
        let txs = store.liveTransactions
        let today = DateKit.localDate()
        let month = DateKit.localMonth()

        DockCard(title: "Spend", accessory: AnyView(
            DockRoundButton(icon: "clipboard", help: "Paste a payment notification", action: paste)
        )) {
            VStack(alignment: .leading, spacing: 10) {
                DockField(placeholder: "coffee 25k, or paste a payment message",
                          text: $draft, onSubmit: add)

                if let spend {
                    HStack(spacing: 10) {
                        DockDot(tone: d.tone(forCategory: spend.category))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spend.merchant).font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                            Text(spend.category).font(FN.font(11)).foregroundStyle(d.muted)
                        }
                        Spacer(minLength: 6)
                        Text((spend.amount < 0 ? "+" : "") + Money.format(abs(spend.amount), currency))
                            .font(FN.font(13)).monospacedDigit()
                            .foregroundStyle(spend.amount < 0 ? d.success : d.text)
                        DockPrimaryButton(title: "Add", action: add)
                    }
                    .transition(.opacity.combined(with: .offset(y: -4)))
                }
                if spend == nil, !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    DockNotice(text: "Add an amount, like 25k", tone: d.muted, icon: "info")
                }
                if let logged { confirmation(logged) }
                if let notice { DockNotice(text: notice, tone: d.muted, icon: "info") }

                HStack(spacing: 0) {
                    stat("Today", FinanceMath.spend(txs.filter { $0.date == today }, currency))
                    Rectangle().fill(d.hair).frame(width: 1)
                    stat("This month", FinanceMath.spend(txs.filter { $0.date.hasPrefix(month) }, currency))
                }
                .fixedSize(horizontal: false, vertical: true)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(d.hair, lineWidth: 1))

                DockList(items: recent(txs)) { tx in
                    DockRow(minHeight: 36, highlighted: tx.id == logged?.id) {
                        dock.showApp { $0.open(ChangeLink(kind: .transactions, id: tx.id)) }
                    } label: {
                        HStack(spacing: 10) {
                            DockDot(tone: d.tone(forCategory: tx.category))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tx.merchant).font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                                Text("\(tx.category) · \(Fmt.relative(tx.createdAt))")
                                    .font(FN.font(11)).foregroundStyle(d.muted).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text((tx.amount < 0 ? "+" : "") + Money.format(abs(tx.amount), tx.currency))
                                .font(FN.font(13)).monospacedDigit()
                                .foregroundStyle(tx.amount < 0 ? d.success : d.text)
                        }
                    }
                }
            }
            .animation(Motion.standard, value: spend)
            .animation(Motion.standard, value: notice)
            .animation(Motion.standard, value: logged)
        }
    }

    /// "Logged Rp 25,000 · Kopi Kenangan", on a green wash, with an undo.
    private func confirmation(_ logged: Logged) -> some View {
        HStack(spacing: 8) {
            Icon("check", size: 14, weight: 2).foregroundStyle(d.success)
            Text(logged.text)
                .font(FN.font(13)).monospacedDigit()
                .foregroundStyle(d.text).lineLimit(1)
            Spacer(minLength: 4)
            DockPlainButton(title: "Undo", height: 24) { undo(logged) }
                .help("Take this spending back out")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 32)
        .background(d.successSubtle, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func recent(_ txs: [Transaction]) -> [Transaction] {
        Array(txs.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }.prefix(3))
    }

    /// Two figures side by side in one hairline box.
    private func stat(_ label: String, _ amount: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FN.font(11)).foregroundStyle(d.muted)
            Text(amount == 0 ? "Nothing yet" : Money.format(amount, currency, compact: true))
                .font(FN.font(13, .medium)).monospacedDigit()
                .foregroundStyle(amount == 0 ? d.muted : d.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        let tx = store.addTransaction {
            $0.merchant = spend.merchant
            $0.amount = spend.amount
            $0.category = spend.category
        }
        draft = ""
        let next = Logged(id: tx.id, text: "Logged \(Money.format(abs(spend.amount), currency)) · \(spend.merchant)")
        logged = next
        Task {
            try? await Task.sleep(for: .seconds(6))
            if logged == next { logged = nil }
        }
    }

    private func undo(_ entry: Logged) {
        store.remove(.transactions, entry.id)
        logged = nil
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
        ), spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("Nothing due in the next five weeks.")
                        .font(FN.font(13)).foregroundStyle(d.secondary)
                        .frame(minHeight: 30)
                }
                DockList(items: items) { item in row(item) }
                if let notice { DockNotice(text: notice).padding(.top, 6) }
            }
            .animation(Motion.list, value: items.map(\.id))
            .animation(Motion.standard, value: notice)
        }
    }

    private func row(_ item: Glance.Payment) -> some View {
        let days = FinanceMath.daysFromToday(item.date)
        let amount = Money.format(item.amount, item.currency, compact: true)
        // "Rp 350,000 · Monthly · in 3 days"; a detected one is only likely.
        let detail = item.subscription != nil
            ? ["Likely \(amount)", FinanceMath.inDays(days)]
            : [amount, item.sub == "Bill" ? nil : item.sub, FinanceMath.inDays(days)].compactMap { $0 }
        return HStack(spacing: 10) {
            dateBlock(item.date)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(FN.font(13)).foregroundStyle(d.text).lineLimit(1)
                Text(detail.joined(separator: " · "))
                    .font(FN.font(11)).monospacedDigit().foregroundStyle(d.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let todoId = item.todoId {
                if days < 0 { DockTag(text: "Overdue", tone: d.danger) }
                DockRoundButton(icon: "check", help: "Mark paid and log the payment", size: 26, look: .bordered) {
                    store.toggleTodo(todoId, done: true)
                    flash("Marked paid · \(item.title)")
                }
            } else if let subscription = item.subscription {
                DockSecondaryButton(title: "Track", small: true) {
                    if store.trackSubscription(subscription) { flash("Tracking · \(subscription.merchant), monthly") }
                }
                .help("Track it as a monthly bill")
            }
        }
        .frame(minHeight: 44)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    /// "Oct" over "24".
    private func dateBlock(_ day: String) -> some View {
        let date = DateKit.date(day)
        return VStack(spacing: 0) {
            Text(date.map { Self.month.string(from: $0) } ?? "")
                .font(FN.font(10)).foregroundStyle(d.muted)
            Text(date.map { "\(Calendar.current.component(.day, from: $0))" } ?? "")
                .font(FN.font(15, .medium)).monospacedDigit().foregroundStyle(d.text)
        }
        .frame(width: 30)
        .accessibilityElement(children: .combine)
    }

    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM"
        return f
    }()

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
    @EnvironmentObject private var engine: AIEngine
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
            let thinking = assistant.busy != nil && waiting
            let answered = thinking || reply != nil
            VStack(alignment: .leading, spacing: 10) {
                if answered, let question { questionBubble(question) }
                if let busy = assistant.busy, thinking {
                    // Animated only while the drawer is open: it's drawn,
                    // hidden, while closed.
                    if dock.isOpen { TypingDots(label: busy) } else { Text(busy).font(FN.font(12.5)) }
                } else if let reply {
                    replyView(reply)
                }
                // In one place whatever is shown above it, so it keeps the
                // keyboard from the question to the follow-up.
                composer(compact: answered)
                if !answered {
                    FlowChips(items: Self.suggestions) { draft = $0 }
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

    /// What was asked from here, while it's being answered and after.
    private var question: String? {
        if let askedId, let message = assistant.messages.first(where: { $0.id == askedId }) { return message.content }
        return pending?.text
    }

    /// The reply to the question asked from here: what the assistant said
    /// after it, before anyone asked anything else.
    private var reply: UIMessage? {
        guard let askedId, let index = assistant.messages.firstIndex(where: { $0.id == askedId }) else { return nil }
        return assistant.messages[(index + 1)...].prefix { $0.role != .user }.last { $0.role == .assistant }
    }

    // MARK: Composer

    /// Where a question is typed. Before anything is asked, a small composer
    /// with the model it goes to; after, one line for a follow-up.
    private func composer(compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                field(compact ? "Ask a follow-up" : "Ask or tell Four Notes")
                if compact { sendButton }
            }
            .padding(.leading, 6)
            .frame(height: compact ? 26 : 30)
            if !compact {
                HStack(spacing: 4) {
                    modelMenu
                    Spacer()
                    sendButton
                }
            }
        }
        .padding(compact ? 4 : 6)
        .background(compact ? .clear : d.card, in: shape)
        .overlay(shape.strokeBorder(d.hair, lineWidth: 1))
    }

    private func field(_ placeholder: String) -> some View {
        TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(d.muted))
            .textFieldStyle(.plain)
            .font(FN.font(13))
            .foregroundStyle(d.text)
            .frame(height: 26)
            .onSubmit(send)
    }

    /// Round, and quiet until there's something to send.
    private var sendButton: some View {
        Button(action: send) {
            Icon("arrowUp", size: 13, weight: 2)
                .foregroundStyle(canSend ? d.onAccent : d.muted)
                .frame(width: 26, height: 26)
                .background(canSend ? d.accent : d.fill, in: Circle())
                .contentShape(Circle())
                .animation(Motion.quick, value: canSend)
        }
        .buttonStyle(.fn)
        .disabled(!canSend)
        .help("Send")
        .accessibilityLabel("Send")
    }

    /// Who answers first: this Mac or the cloud, as in Settings.
    private var modelMenu: some View {
        let onMac = engine.chatRunsOnDevice
        return MenuButton(help: "Which model answers first", entries: {
            AIEngine.Priority.allCases.map { priority in
                .item(priority.label, checked: engine.priority == priority) { engine.priority = priority }
            }
        }) {
            DockMenuLabel(title: onMac ? "On this Mac" : engine.chatAnswererName ?? "Not set up",
                          icon: onMac ? "monitor" : "cloud", height: 26)
        }
    }

    // MARK: The answer

    private func questionBubble(_ text: String) -> some View {
        Text(text)
            .font(FN.font(13))
            .foregroundStyle(d.text)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(d.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
    }

    private func replyView(_ reply: UIMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(LocalizedStringKey(reply.content))
                    .font(FN.font(13))
                    .lineSpacing(3)
                    .foregroundStyle(reply.isError ? d.danger : d.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)

            // The pages a web answer drew on, numbered as it cites them.
            if !reply.sources.isEmpty {
                FlowLayout(spacing: 6, alignment: .leading) {
                    ForEach(Array(reply.sources.enumerated()), id: \.offset) { index, source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                HStack(spacing: 5) {
                                    Text("\(index + 1)").monospacedDigit().foregroundStyle(d.muted)
                                    Text(source.title.isEmpty ? (url.host() ?? source.url) : source.title)
                                        .foregroundStyle(d.secondary).lineLimit(1)
                                }
                                .font(FN.font(12))
                                .padding(.leading, 7)
                                .padding(.trailing, 9)
                                .frame(height: 24)
                                .overlay(Capsule().strokeBorder(d.hair, lineWidth: 1))
                                .frame(maxWidth: 220, alignment: .leading)
                            }
                            .buttonStyle(.fn)
                            .help(source.url)
                        }
                    }
                }
            }

            // What it filed, each with a way to it.
            if !reply.filed.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(reply.filed.prefix(3).enumerated()), id: \.offset) { index, filed in
                        let link = index < reply.links.count ? reply.links[index] : nil
                        HStack(spacing: 8) {
                            Icon("check", size: 12, weight: 2.2).foregroundStyle(d.success)
                            Text(filed).font(FN.font(12.5)).foregroundStyle(d.text).lineLimit(1)
                            Spacer(minLength: 4)
                            if let link {
                                DockPlainButton(title: "Show", height: 24) { dock.showApp { $0.open(link) } }
                            }
                        }
                        .frame(minHeight: 28)
                    }
                }
            }

            HStack(spacing: 4) {
                DockRoundButton(icon: "copy", help: "Copy the answer", size: 26) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reply.content, forType: .string)
                }
                if let model = modelLine(reply) {
                    Text(model)
                        .font(FN.font(11)).foregroundStyle(d.muted).lineLimit(1)
                        .help(reply.origin == .onDeviceFallback
                              ? "The cloud model didn’t answer, so this Mac replied. Nothing left this Mac." : "")
                }
            }
            .padding(.leading, -4)
        }
    }

    /// "Apple Intelligence, on this Mac" — or the cloud model that answered.
    private func modelLine(_ reply: UIMessage) -> String? {
        switch reply.origin {
        case .onDevice, .onDeviceFallback:
            return "\(reply.answererName ?? "Apple Intelligence"), on this Mac"
        case .cloud:
            return reply.answererName.map { "\($0), in the cloud" }
        }
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

/// Suggestion capsules, wrapped onto as many lines as they need.
private struct FlowChips: View {
    @Environment(\.dock) private var d
    let items: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6, alignment: .leading) {
            ForEach(items, id: \.self) { item in
                FlowChip(title: item) { pick(item) }
            }
        }
    }
}

private struct FlowChip: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FN.font(12))
                .foregroundStyle(hovering ? d.text : d.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(hovering ? d.fill : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(d.hair, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
    }
}

// MARK: - A tappable row

/// A full-width row that highlights under the pointer. Its highlight reaches
/// a little past the card's content on each side, so the text stays in line.
struct DockRow<Label: View>: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    var minHeight: CGFloat = 34
    /// Picked out: the one just added.
    var highlighted = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .padding(.horizontal, 6)
                .background(highlighted ? d.accentSubtle : hovering ? d.fill : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .padding(.horizontal, -6)
    }
}
