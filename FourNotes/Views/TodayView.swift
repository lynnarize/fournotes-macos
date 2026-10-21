import Combine
import SwiftUI

// Today, as on the web (src/components/TodayView.tsx): the date and a greeting, the
// brief (one short paragraph written from your data, or the written brief point by
// point, see Settings → Today), and the assistant under it. Beside them, at a glance:
// what's due (tick it off right here), what you've spent today, and quick notes.
// Sending to the assistant opens the conversation as a card where the brief was.

struct TodayView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var engine: AIEngine
    /// One short paragraph, or point by point. Set in Settings → Today.
    @AppStorage(BriefStyle.storageKey) private var briefStyleRaw = BriefStyle.paragraph.rawValue

    @State private var loading = false
    /// The window is too narrow for the page and the cards side by side.
    @State private var narrow = false
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

    /// The next week's tasks, after today.
    private var upcoming: [Todo] {
        let start = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
        let end = start.addingTimeInterval(7 * 86_400)
        return Array(store.liveTodos
            .filter { !$0.done && (DateKit.date($0.dueAt).map { $0 > start && $0 <= end } ?? false) }
            .sorted { ($0.dueAt ?? "") < ($1.dueAt ?? "") }
            .prefix(2))
    }

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
        ScrollView {
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 32))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
            layout {
                mainColumn(alerts)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 16) {
                    DueTodayCard(tasks: tasks, upcoming: upcoming, focus: focus)
                    SpentTodayCard(yesterdayTotal: yesterdayTotal)
                    QuickNotesCard(quickNotes: quickNotes)
                }
                .frame(width: narrow ? nil : 340)
                .frame(maxWidth: narrow ? .infinity : nil)
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 36)
            .padding(.top, nav.todayChat ? 32 : 64)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: Bool.self, of: { $0.size.width < 920 }) { narrow = $0 }
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

    /// The date, the greeting, the brief (until a conversation takes its place), and
    /// the assistant.
    private func mainColumn(_ alerts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.dateLine(now))
                    .font(FN.font(14))
                    .foregroundStyle(p.textSecondary)
                Text("\(Fmt.greeting(now))\(firstName.map { ", \($0)" } ?? "")")
                    .font(FN.display(52))
                    .tracking(FN.displayTracking(52))
                    .foregroundStyle(p.foreground)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            if !nav.todayChat {
                VStack(alignment: .leading, spacing: 14) {
                    if isEmptyApp {
                        emptyPrompt
                    } else if briefStyle == .paragraph {
                        paragraph(alerts)
                    } else {
                        pointByPoint(alerts)
                    }
                    if !isEmptyApp { briefControls }
                    if let briefError, briefStyle == .points {
                        Text(briefError)
                            .font(FN.font(13))
                            .foregroundStyle(p.textSecondary)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            ChatDock(minimized: false, hero: true)
                .padding(.top, nav.todayChat ? 0 : 12)
        }
    }

    /// "Wednesday, October 21".
    private static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    private var emptyPrompt: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nothing here yet. Tell the assistant what you need: a note, a task, or something you spent. Or look around with some sample data first.")
                .font(FN.font(18))
                .lineSpacing(7)
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecondaryButton(title: "Explore with sample data") { store.loadSamples() }
        }
    }

    /// Refresh (point by point), and how the brief reads.
    private var briefControls: some View {
        HStack(spacing: 4) {
            if briefStyle == .points {
                QuietButton(icon: "refresh", title: loading ? "Writing…" : (brief != nil ? "Refresh brief" : "Write today's brief")) {
                    Task { await writeBrief(asked: true) }
                }
                .disabled(loading)
            }
            MenuButton(help: "How the brief reads") {
                BriefStyle.allCases.map { style in
                    .item(style.label, checked: style == briefStyle) {
                        withAnimation(Motion.standard) { briefStyleRaw = style.rawValue }
                    }
                }
            } label: {
                QuietLabel(title: briefStyle.label, trailingIcon: "chevronDown")
            }
        }
        .padding(.leading, -10)
    }

    /// The written brief, and anything that needs a look, a row each.
    private func pointByPoint(_ alerts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if briefLines.isEmpty {
                briefRow(icon: "calendarCheck", text: loading ? "Reading your day…" : "Your daily brief will appear here.")
                if !yesterdaySpend.isEmpty {
                    briefRow(icon: "wallet", text: "\(Money.format(yesterdayTotal, currency)) spent yesterday")
                }
            } else {
                ForEach(Array(briefLines.prefix(3).enumerated()), id: \.offset) { _, line in
                    let split = Self.leadingEmoji(line)
                    briefRow(glyph: split.glyph, text: split.text)
                }
            }
            // Only what the written brief didn't already say.
            ForEach(freshAlerts(alerts).prefix(2), id: \.self) { alert in
                briefRow(icon: "warning", text: alert, tone: p.warning)
                    .transition(.opacity.combined(with: .offset(y: 5)))
            }
        }
        .font(FN.font(17))
        .lineSpacing(6)
        .animation(Motion.list, value: briefLines)
        .animation(Motion.list, value: alerts)
    }

    // MARK: - The brief as one paragraph

    /// Today in a few sentences, the phrases worth a closer look underlined.
    /// Clicking one goes to where the details are.
    private func paragraph(_ alerts: [String]) -> some View {
        let pieces = BriefParagraph.compose(paragraphInput(alerts))
        return Text(attributed(pieces))
            .font(FN.font(18))
            .lineSpacing(7)
            .foregroundStyle(p.textSecondary)
            .tint(p.foreground)
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
                run.foregroundColor = p.foreground
                run.underlineStyle = Text.LineStyle(pattern: .solid, color: p.borderStrong)
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

    private func briefRow(glyph: String? = nil, icon: String? = nil, text: String, tone: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let icon {
                    Icon(icon, size: 16).foregroundStyle(tone ?? p.foreground)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                } else {
                    Text(glyph ?? "•")
                }
            }
            .frame(width: 22)
            Text(text)
                .foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: - Actions

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

}

// MARK: - Flash highlight

extension View {
    /// The brief accent wash used when the assistant files something.
    func flashes(_ on: Bool, palette: Palette) -> some View {
        flash(on, palette: palette)
    }
}
