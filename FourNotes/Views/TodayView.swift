import Combine
import SwiftUI

// Daily brief: today's tasks, yesterday's spending, quick notes, heads-up
// alerts (budgets, subscriptions, money owed) and a 3-line AI summary.
// Ported from src/components/TodayView.tsx.

struct TodayView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var engine: AIEngine
    @ObservedObject private var stickies = EdgeStickies.shared
    @Environment(\.colorScheme) private var scheme
    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    /// One short paragraph, or point by point. Set in Settings → Today.
    @AppStorage(BriefStyle.storageKey) private var briefStyleRaw = BriefStyle.paragraph.rawValue

    @State private var loading = false
    @State private var draft = ""
    /// The window is too narrow for the greeting and the notes side by side.
    @State private var narrow = false
    /// A short window: smaller type, fewer lines, so the page still fits.
    @State private var compact = false
    /// Why the brief couldn't be written, after Refresh was pressed.
    @State private var briefError: String?
    @State private var now = Date()

    /// A `let` in a View struct is rebuilt on every render, so a publisher
    /// created here resubscribed constantly and its 60-second countdown never
    /// completed — the greeting never rolled over from "Good morning".
    /// `.task` owns the loop instead, tied to the view's lifetime.

    private var currency: String { store.settings.currency }
    private var today: String { DateKit.localDate() }
    private var yesterday: String {
        DateKit.localDate(Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    }

    // MARK: - Derived data

    private var tasks: [Todo] { Glance.dueByToday(store.liveTodos) }

    private var focus: [Todo] {
        guard tasks.isEmpty else { return [] }
        return Array(store.liveTodos.filter { !$0.done && $0.dueAt == nil && $0.priority == .high }.prefix(3))
    }

    private var yesterdaySpend: [Transaction] {
        store.liveTransactions.filter { $0.date == yesterday && $0.amount > 0 }
    }

    private var yesterdayTotal: Double {
        yesterdaySpend.reduce(0) { $0 + Insights.myShare($1, currency) }
    }

    /// Quick notes (they replaced stickies): newest first; today's go into the brief.
    private var quickNotes: [Note] {
        store.liveNotes.filter(QuickNote.isQuick).sorted { $0.createdAt > $1.createdAt }
    }

    private var alerts: [String] {
        var out: [String] = []
        let live = store.liveTransactions
        let month = DateKit.localMonth()
        for b in Insights.budgetStatus(live.filter { $0.date.hasPrefix(month) }, store.settings) where b.ratio >= 0.8 {
            out.append("\(b.category) budget \(Int((b.ratio * 100).rounded()))% used "
                       + "(\(Money.format(b.spent, currency, compact: true)) of \(Money.format(b.limit, currency, compact: true)))")
        }
        let weekAhead = Date().addingTimeInterval(7 * 86_400)
        for s in Insights.detectSubscriptions(live) {
            if let next = DateKit.date(s.nextDate), next <= weekAhead {
                out.append("\(s.merchant) will likely charge \(Money.format(s.amount, s.currency)) around \(Fmt.dayMonth(next))")
            }
        }
        for owed in Insights.owedToMe(live, currency).prefix(3) {
            out.append("\(owed.name) still owes you \(Money.format(owed.amount, currency))")
        }
        return out
    }

    /// A brief written by a model thinking out loud is treated as missing, so it's rewritten.
    private var brief: DailyBrief? {
        store.brief(for: today).flatMap { AIText.looksLikeThinking($0.text) ? nil : $0 }
    }

    private var isEmptyApp: Bool {
        store.liveTodos.isEmpty && store.liveTransactions.isEmpty && store.liveNotes.isEmpty
    }

    private var briefStyle: BriefStyle { BriefStyle(rawValue: briefStyleRaw) ?? .paragraph }

    // MARK: - Body

    var body: some View {
        // Computed once per render and handed down: each of these walks the
        // whole transaction list, and `alerts` walks it three times.
        let alerts = alerts
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            // Side by side when there's room; in a narrow window the notes
            // go under the greeting rather than squeezing it until
            // "afternoon" breaks in the middle.
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                                : AnyLayout(HStackLayout(alignment: .center, spacing: 56))
            layout {
                greetingBlock(alerts)
                    .frame(maxWidth: .infinity, alignment: .leading)
                quickNotesStack
                    .frame(width: 340)
            }
            .frame(maxWidth: 1060)
            Spacer(minLength: 20)
            // The assistant, in the middle of the page. Drawn last, so the
            // conversation it opens sits over everything above it.
            ChatDock(minimized: false, hero: true)
                .padding(.bottom, compact ? 14 : 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: Bool.self, of: { $0.size.width < 820 }) { narrow = $0 }
        .onGeometryChange(for: Bool.self, of: { $0.size.height < 700 }) { compact = $0 }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
        // Written again whenever what it's written from changes — a task
        // done, a quick note, yesterday's spending — each time Today is open.
        .task(id: "\(briefBasis)|\(briefStyleRaw)") { await autoWriteBrief(briefBasis) }
        .onAppear(perform: migrateStickies)
    }

    // MARK: - Greeting + brief

    private var firstName: String? {
        store.settings.name?.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces).first.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var briefLines: [String] {
        (brief?.text ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func serif(_ text: String) -> some View {
        Text(text)
            .font(FN.serif(compact ? 36 : 46))
            .minimumScaleFactor(0.75)
            .tracking(-0.8)
            .foregroundStyle(p.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The greeting, then one list: the written brief, what's due (tick it
    /// off right here), and anything that needs a look — what used to be
    /// four separate sections.
    private func greetingBlock(_ alerts: [String]) -> some View {
        let rows = tasks + focus
        return VStack(alignment: .leading, spacing: 0) {
            serif("Hello\(firstName.map { " \($0)" } ?? "")!")
            serif("\(Fmt.greeting(now)).")

            if briefStyle == .paragraph {
                paragraph(alerts)
                    .frame(maxWidth: 580, alignment: .leading)
                    .padding(.top, 22)
                    .transition(.opacity)
            } else {
                pointByPoint(alerts, rows: rows)
                    .transition(.opacity)
            }

            HStack(spacing: 16) {
                if briefStyle == .points {
                    Button { Task { await writeBrief(asked: true) } } label: {
                        HStack(spacing: 6) {
                            Icon("sparkle", size: 14)
                            Text(loading ? "Writing…" : (brief != nil ? "Refresh brief" : "Write today's brief"))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.fn)
                    .disabled(loading)
                    .opacity(loading ? 0.4 : 1)
                    .motion(loading, Motion.quick)
                }

                Button { nav.tab = .finance } label: {
                    HStack(spacing: 6) {
                        Icon("wallet", size: 14)
                        Text(yesterdayTotal > 0 ? "\(Money.format(yesterdayTotal, currency, compact: true)) yesterday"
                             : "Finance")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
            }
            .font(FN.body)
            .foregroundStyle(p.faint)
            .padding(.top, compact ? 10 : 18)

            if let briefError, briefStyle == .points {
                Text(briefError)
                    .font(FN.small)
                    .foregroundStyle(p.muted)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
    }

    /// The written brief, what's due and anything that needs a look, a row each.
    private func pointByPoint(_ alerts: [String], rows: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if briefLines.isEmpty {
                briefRow(glyph: "✳︎", text: loading ? "Reading your day…"
                         : isEmptyApp ? "Nothing here yet. Tell the assistant below what you need."
                         : "Your daily brief will appear here.")
                if brief == nil, !yesterdaySpend.isEmpty {
                    briefRow(glyph: "💸", text: "\(Money.format(yesterdayTotal, currency)) spent yesterday")
                }
            } else {
                ForEach(Array(briefLines.prefix(3).enumerated()), id: \.offset) { _, line in
                    let split = Self.leadingEmoji(line)
                    briefRow(glyph: split.glyph, text: split.text)
                }
            }

            ForEach(rows.prefix(compact ? 2 : 3)) { todo in
                taskRow(todo)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            let shownRows = compact ? 2 : 3
            if rows.count > shownRows {
                moreLink("\(rows.count - shownRows) more due", go: { nav.tab = .todo })
            }

            // Only what the written brief didn't already say.
            ForEach(freshAlerts(alerts).prefix(compact ? 1 : 2), id: \.self) { alert in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Icon("warning", size: 15).foregroundStyle(p.boardAmber).frame(width: 22)
                    Text(alert)
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .offset(y: 5)))
            }
        }
        .font(.system(size: 16))
        .lineSpacing(3)
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.top, 22)
        .animation(Motion.list, value: briefLines)
        .animation(Motion.list, value: rows.map(\.id))
        .animation(Motion.list, value: alerts)
    }

    // MARK: - The brief as one paragraph

    /// Today in a few sentences, the phrases worth a closer look underlined.
    /// Clicking one goes to where the details are.
    private func paragraph(_ alerts: [String]) -> some View {
        let pieces = BriefParagraph.compose(paragraphInput(alerts))
        return Text(attributed(pieces))
            .font(.system(size: compact ? 16 : 17))
            .lineSpacing(compact ? 4 : 6)
            .foregroundStyle(p.muted)
            .tint(p.text)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let target = BriefParagraph.target(url) else { return .discarded }
                follow(target)
                return .handled
            })
            .animation(Motion.standard, value: pieces)
    }

    private func attributed(_ pieces: [BriefParagraph.Piece]) -> AttributedString {
        var out = AttributedString()
        for piece in pieces {
            var run = AttributedString(piece.text)
            if let target = piece.target, let url = BriefParagraph.url(target) {
                run.link = url
                run.foregroundColor = p.text
                run.underlineStyle = Text.LineStyle(pattern: .solid, color: p.faint.opacity(0.8))
            }
            out += run
        }
        return out
    }

    private func paragraphInput(_ alerts: [String]) -> BriefParagraph.Input {
        let item = { (t: Todo) in BriefParagraph.Item(id: t.id, title: t.title, due: DateKit.date(t.dueAt)) }
        return BriefParagraph.Input(
            now: now,
            due: tasks.map(item),
            focus: focus.map(item),
            yesterday: yesterdaySpend.map { .init(category: $0.category, amount: Insights.myShare($0, currency)) },
            currency: currency,
            alerts: alerts,
            notesToday: quickNotes
                .filter { DateKit.date($0.createdAt).map(DateKit.localDate) == today }
                .map { .init(id: $0.id, title: $0.title) })
    }

    private func follow(_ target: BriefParagraph.Target) {
        switch target {
        case .todos: nav.tab = .todo
        case .todo(let id): nav.open(ChangeLink(kind: .todos, id: id))
        case .finance: nav.tab = .finance
        case .notes: nav.tab = .notes
        case .note(let id): nav.open(ChangeLink(kind: .notes, id: id))
        }
    }

    private func freshAlerts(_ alerts: [String]) -> [String] {
        let said = briefLines.map { $0.lowercased() }
        return alerts.filter { alert in
            let key = String(alert.lowercased().prefix(18))
            return !said.contains { $0.contains(key) }
        }
    }

    private func briefRow(glyph: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(glyph).frame(width: 22)
            Text(text)
                .foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moreLink(_ title: String, go: @escaping () -> Void) -> some View {
        Button(action: go) {
            Text("\(title) →").font(FN.font(13)).foregroundStyle(p.faint)
        }
        .buttonStyle(.fn)
        .padding(.leading, 34)
    }

    /// "☀️ Andi still owes you…" → ("☀️", "Andi still owes you…"), so the
    /// glyphs line up in a column; "•" when a line has none.
    static func leadingEmoji(_ line: String) -> (glyph: String, text: String) {
        guard let first = line.first,
              first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation
                  || ($0.properties.isEmoji && $0.value > 0x238C) }) else {
            return ("•", line)
        }
        return (String(first), String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private func taskRow(_ todo: Todo) -> some View {
        let overdue = DateKit.date(todo.dueAt).map { $0 < Date() } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                let extra = store.toggleTodo(todo.id, done: true)
                toasts.push((["☑️ \(todo.title)"] + extra).joined(separator: "\n"))
            } label: {
                Circle()
                    .strokeBorder(overdue ? p.danger.opacity(0.8) : p.faint, lineWidth: 1.5)
                    .frame(width: 15, height: 15)
                    .frame(width: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            .accessibilityLabel("Complete \(todo.title)")

            Button { nav.open(ChangeLink(kind: .todos, id: todo.id)) } label: {
                HStack(spacing: 8) {
                    Text(todo.title).foregroundStyle(p.text).lineLimit(1)
                    if let due = DateKit.date(todo.dueAt) {
                        Text(Calendar.current.isDateInToday(due) ? Fmt.time(due) : Fmt.dayMonth(due))
                            .monospacedDigit()
                            .foregroundStyle(overdue ? p.danger : p.faint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
        }
        .flashes(nav.isFlashing(todo.id), palette: p)
    }

    // MARK: - Quick notes

    private var cardFill: Color {
        if scheme == .dark { return p.panel }
        return themeRaw == ThemeChoice.paper.rawValue ? .hex(0xFFFCF3) : .white
    }

    /// Quick notes as a loose stack of paper cards beside the greeting, the
    /// newest on top, with a blank one to write on.
    private var quickNotesStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Icon("noteAdd", size: 16).foregroundStyle(p.faint)
                TextField("Quick notes", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(p.text)
                    .lineLimit(1...5)
                    .onSubmit(saveQuick)
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(p.faint)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(p.line, style: StrokeStyle(lineWidth: 1, dash: draft.isEmpty ? [4, 4] : [])))
            .motion(draft.isEmpty, Motion.quick)

            ForEach(Array(quickNotes.prefix(narrow || compact ? 1 : 3).enumerated()), id: \.element.id) { index, note in
                noteCard(note)
                    .offset(x: [22, 4, 30][index])
                    .transition(.opacity.combined(with: .offset(y: -8)))
            }
            .animation(Motion.list, value: quickNotes.prefix(3).map(\.id))

            if quickNotes.count > (narrow || compact ? 1 : 3) {
                moreLink("All notes", go: { nav.tab = .notes })
                    .padding(.leading, -8)
            }
        }
    }

    private func noteCard(_ note: Note) -> some View {
        HoverRow(cornerRadius: 14) { hovering in
            HStack(spacing: 12) {
                Button { nav.open(ChangeLink(kind: .notes, id: note.id)) } label: {
                    HStack(spacing: 12) {
                        Icon("note", size: 14, weight: 1.9)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(p.finA, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(FN.font(14, .semibold)).foregroundStyle(p.text).lineLimit(1)
                            Text(ago(note.createdAt))
                                .font(FN.font(12)).foregroundStyle(p.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fn)

                let stuck = stickies.isStuck(note.id)
                IconButton("pin", size: 13, box: 24, tone: stuck ? p.accent : nil,
                           help: stuck ? "Take off the screen edge" : "Stick to the screen edge") {
                    stickies.toggle(note.id)
                }
                .opacity(hovering || stuck ? 1 : 0)
                .motion(hovering, Motion.quick)

                IconButton("x", size: 13, box: 24, help: "Delete “\(note.title)”") {
                    store.remove(.notes, note.id)
                }
                .opacity(hovering ? 1 : 0)
                .motion(hovering, Motion.quick)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(p.line, lineWidth: 1))
        .shadow(color: p.shadow, radius: 12, y: 5)
        .frame(width: 310)
        .flashes(nav.isFlashing(note.id), palette: p)
    }

    // MARK: - Actions

    private func saveQuick() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addNote { QuickNote.apply(text, to: &$0) }
        draft = ""
        toasts.push("📝 Quick note saved")
    }

    /// What the brief is written from, as a short fingerprint.
    private var briefBasis: String {
        let parts = [
            today,
            tasks.prefix(15).map { "\($0.title)|\($0.dueAt ?? "")" }.joined(separator: ";"),
            "\(yesterdaySpend.count)|\(Int(yesterdaySpend.reduce(0) { $0 + $1.amount }))",
            quickNotes.filter { DateKit.date($0.createdAt).map(DateKit.localDate) == today }
                .prefix(5).map(\.content).joined(separator: ";"),
            alerts.joined(separator: ";"),
        ]
        return Fingerprint.of(parts.joined(separator: "#"))
    }

    /// Rewrites the brief when today's data has changed since it was written.
    private func autoWriteBrief(_ basis: String) async {
        // The paragraph is written from the data itself; no model to call.
        guard briefStyle == .points, engine.canSummarize, brief?.basis != basis,
              nav.briefRequestedFor != basis else { return }
        // Let a burst of edits settle; a newer change cancels this one.
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        nav.briefRequestedFor = basis
        await writeBrief(asked: false)
    }

    /// `asked`: Refresh was pressed. The automatic rewrite — every time Today
    /// opens after something changed — fails quietly: it used to put up an
    /// error each time, when a free cloud model was busy or rate limited.
    private func writeBrief(asked: Bool) async {
        let basis = briefBasis
        guard !loading else { return }
        loading = true
        defer { loading = false }

        let now = Date()
        let input = BriefInput(
            now: DateKit.iso(now),
            timezone: TimeZone.current.identifier,
            currency: currency,
            name: store.settings.name,
            tasksToday: tasks.prefix(15).map {
                .init(title: $0.title, dueAt: $0.dueAt,
                      overdue: DateKit.date($0.dueAt).map { $0 < now } ?? false)
            },
            yesterdaySpend: yesterdaySpend.prefix(30).map {
                .init(merchant: $0.merchant, amount: Insights.myShare($0, currency), category: $0.category)
            },
            stickies: quickNotes
                .filter { DateKit.date($0.createdAt).map(DateKit.localDate) == today }
                .prefix(5).map(\.content),
            alerts: alerts)

        do {
            let text = try await engine.dailyBrief(input)
            store.saveBrief(DailyBrief(date: today, text: text, basis: basis))
            withAnimation(Motion.standard) { briefError = nil }
        } catch {
            guard asked else { return }
            withAnimation(Motion.standard) {
                briefError = "Couldn't write the brief: \(AIEngine.reason(error)). The last one is still shown."
            }
        }
    }

    /// Stickies are gone: any left from before become quick notes, once.
    private func migrateStickies() {
        let left = store.stickies.filter { $0.deletedAt == nil }
        guard !left.isEmpty else { return }
        for sticky in left {
            if !sticky.text.trimmingCharacters(in: .whitespaces).isEmpty {
                store.addNote {
                    QuickNote.apply(sticky.text, to: &$0)
                    // Keep the sample flag, so "Remove sample data" still removes it.
                    $0.sample = sticky.sample
                }
            }
            store.remove(.stickies, sticky.id)
        }
    }

    private func ago(_ iso: String) -> String {
        guard let date = DateKit.date(iso) else { return "" }
        let mins = Int((Date().timeIntervalSince(date) / 60).rounded())
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m" }
        let h = Int((Double(mins) / 60).rounded())
        if h < 24 { return "\(h)h" }
        let d = Int((Double(h) / 24).rounded())
        return d < 7 ? "\(d)d" : Fmt.dayMonth(date)
    }
}

// MARK: - Flash highlight

extension View {
    /// The brief accent wash used when the assistant files something.
    func flashes(_ on: Bool, palette: Palette) -> some View {
        flash(on, palette: palette)
    }
}
