import Combine
import Foundation

// State, persistence, sample data and the AI-action applier.
// Ported from src/lib/store.tsx. The app always saves locally first (instant
// UI, works offline); cloud sync runs on top of it.

@MainActor
final class Store: ObservableObject {
    /// Unfiltered data (all spaces), for sync and export.
    @Published private(set) var all = AppData()
    @Published private(set) var ready = false
    /// Set when a brand new install should see the first-run setup.
    @Published var needsOnboarding = false

    private let persistence: Persistence
    private var saveCancellable: AnyCancellable?

    /// Raised when a save could not be completed, so the UI can say so instead
    /// of letting a session's work quietly disappear.
    @Published var saveFailure: String?
    /// Rows the last load could not read. The original file is kept beside the
    /// document; this is what tells the user about it.
    @Published var skippedRows = 0

    init(persistence: Persistence = .shared) {
        self.persistence = persistence
        load()
        // `throttle` rather than `debounce`: debounce restarts its timer on every
        // change, so typing without a pause never reached a save at all. This
        // writes at most once a second, and always writes the latest value.
        saveCancellable = $all
            .dropFirst()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] data in
                guard let self, self.ready, !self.saveBlocked else { return }
                // The failure arrives from the persistence queue, so it has to
                // hop back before touching published state.
                self.persistence.save(data) { [weak self] error in
                    Task { @MainActor in self?.saveFailure = error.errorDescription }
                }
            }
    }

    private func load() {
        switch persistence.loadResult() {
        case .loaded(var loaded):
            // Documents written by the web app — or by an older build of this
            // one — carry their images inline. Move them out once.
            let moved = Attachments.extractInlineImages(&loaded)
            all = loaded
            skippedRows = loaded.skippedRows
            ready = true
            if moved > 0 { flush() }
        case .missing:
            // Brand new install: offer the first-run setup.
            needsOnboarding = true
            ready = true
        case .unreadable(let reason):
            // Not a new install: saving now would write an empty document
            // over the real one. Stay read-only and say so.
            saveBlocked = true
            saveFailure = reason + " Four Notes won't save until this is fixed, so nothing is overwritten."
            ready = true
        }
    }

    /// The document on disk could not be read, so nothing may be saved over it.
    private(set) var saveBlocked = false

    /// Write immediately and wait for it. Called on the way out, before an
    /// export, and before a sync push — anywhere the process might not survive
    /// long enough for the throttled save to land.
    @discardableResult
    func flush() -> Bool {
        guard !saveBlocked else { return false }
        var saved = true
        do {
            try persistence.saveNow(all)
        } catch let error as Persistence.SaveError {
            saveFailure = error.errorDescription
            saved = false
        } catch {
            saveFailure = error.localizedDescription
            saved = false
        }
        persistence.waitForPendingWrites()
        return saved
    }

    // MARK: - Space-filtered views (what the UI reads)

    var settings: AppSettings { all.settings }
    var spaces: [Space] { all.spaces }
    var currentSpaceId: String? { all.currentSpaceId }
    var summaries: [MonthlySummary] { all.summaries }
    var briefs: [DailyBrief] { all.briefs }

    private func inSpace<T: BaseItem>(_ xs: [T]) -> [T] {
        xs.filter { ($0.spaceId ?? nil) == all.currentSpaceId }
    }

    var notes: [Note] { inSpace(all.notes) }
    var todos: [Todo] { inSpace(all.todos) }
    var transactions: [Transaction] { inSpace(all.transactions) }
    var stickies: [Sticky] { inSpace(all.stickies) }

    /// Live rows only: the lists the views actually render.
    var liveNotes: [Note] { notes.filter { $0.deletedAt == nil } }
    var liveTodos: [Todo] { todos.filter { $0.deletedAt == nil } }
    var liveTransactions: [Transaction] { transactions.filter { $0.deletedAt == nil } }

    var spaceName: String? { spaces.first { $0.id == currentSpaceId }?.name }

    /// All categories in use (built-in + custom), in a stable order.
    var categories: [String] { Store.categories(of: all.settings) }

    /// True while the optional sample data is loaded.
    var hasSamples: Bool {
        all.notes.contains { $0.sample == true } || all.todos.contains { $0.sample == true }
            || all.transactions.contains { $0.sample == true } || all.stickies.contains { $0.sample == true }
    }

    // MARK: - Create

    private func stamp() -> (id: String, createdAt: String, updatedAt: String) {
        let t = DateKit.nowIso()
        return (DateKit.uid(), t, t)
    }

    @discardableResult
    func addNote(_ build: (inout Note) -> Void = { _ in }) -> Note {
        let s = stamp()
        var n = Note(id: s.id, createdAt: s.createdAt, updatedAt: s.updatedAt, spaceId: currentSpaceId)
        build(&n)
        all.notes.insert(n, at: 0)
        return n
    }

    @discardableResult
    func addTodo(_ build: (inout Todo) -> Void = { _ in }) -> Todo {
        let s = stamp()
        var t = Todo(id: s.id, createdAt: s.createdAt, updatedAt: s.updatedAt, spaceId: currentSpaceId)
        build(&t)
        all.todos.insert(t, at: 0)
        return t
    }

    @discardableResult
    func addTransaction(_ build: (inout Transaction) -> Void = { _ in }) -> Transaction {
        let s = stamp()
        var t = Transaction(id: s.id, createdAt: s.createdAt, updatedAt: s.updatedAt,
                            spaceId: currentSpaceId, currency: all.settings.currency,
                            date: DateKit.localDate())
        build(&t)
        all.transactions.insert(t, at: 0)
        return t
    }

    @discardableResult
    func addSticky(_ build: (inout Sticky) -> Void = { _ in }) -> Sticky {
        let s = stamp()
        var x = Sticky(id: s.id, createdAt: s.createdAt, updatedAt: s.updatedAt, spaceId: currentSpaceId)
        build(&x)
        all.stickies.append(x)
        return x
    }

    // MARK: - Update

    func updateNote(_ id: String, _ patch: (inout Note) -> Void) {
        guard let i = all.notes.firstIndex(where: { $0.id == id }) else { return }
        patch(&all.notes[i])
        all.notes[i].updatedAt = DateKit.nowIso()
    }

    func updateTodo(_ id: String, _ patch: (inout Todo) -> Void) {
        guard let i = all.todos.firstIndex(where: { $0.id == id }) else { return }
        patch(&all.todos[i])
        all.todos[i].updatedAt = DateKit.nowIso()
    }

    func updateTransaction(_ id: String, _ patch: (inout Transaction) -> Void) {
        guard let i = all.transactions.firstIndex(where: { $0.id == id }) else { return }
        patch(&all.transactions[i])
        all.transactions[i].updatedAt = DateKit.nowIso()
    }

    func updateSticky(_ id: String, _ patch: (inout Sticky) -> Void) {
        guard let i = all.stickies.firstIndex(where: { $0.id == id }) else { return }
        patch(&all.stickies[i])
        all.stickies[i].updatedAt = DateKit.nowIso()
    }

    /// Soft delete keeps a tombstone so sync can propagate deletions.
    func remove(_ kind: ListKind, _ id: String) {
        let now = DateKit.nowIso()
        switch kind {
        case .notes: updateNote(id) { $0.deletedAt = now }
        case .todos: updateTodo(id) { $0.deletedAt = now }
        case .transactions: updateTransaction(id) { $0.deletedAt = now }
        case .stickies: updateSticky(id) { $0.deletedAt = now }
        }
    }

    /// Complete / reopen. Completing a recurring task schedules the next one; bills log a transaction.
    @discardableResult
    func toggleTodo(_ id: String, done: Bool) -> [String] {
        guard let t = all.todos.first(where: { $0.id == id }), t.done != done else { return [] }
        var out: [String] = []
        let completedAt = DateKit.nowIso()
        updateTodo(id) {
            $0.done = done
            $0.completedAt = done ? completedAt : nil
        }
        guard done else {
            // Unticking takes back what ticking did. Ticked, unticked and
            // ticked again used to log the bill twice and schedule next month
            // twice.
            undoCompletion(of: t)
            return out
        }

        if let bill = t.bill, bill.amount > 0 {
            addTransaction {
                $0.merchant = t.title
                $0.amount = bill.amount
                $0.currency = bill.currency ?? all.settings.currency
                $0.category = bill.category
                $0.date = DateKit.localDate()
                $0.noteId = t.noteId
                $0.spaceId = t.spaceId
            }
            out.append("💸 Logged bill: \(t.title)")
        }
        if let rrule = t.rrule, !rrule.isEmpty {
            let base = t.dueAt ?? t.remindAt ?? DateKit.nowIso()
            // Roll forward: completing a task that was due months ago must not
            // schedule the next one in the past.
            let nextDue = t.dueAt.map { Recurrence.nextAfterCompleting($0, rrule) }
            let nextRemind = t.remindAt.map { Recurrence.nextAfterCompleting($0, rrule) }
            // Already scheduled (by an earlier tick): not again.
            let scheduled = all.todos.contains {
                $0.deletedAt == nil && !$0.done && $0.id != t.id && $0.title == t.title
                    && $0.rrule == rrule && $0.dueAt == nextDue && $0.remindAt == nextRemind
            }
            if !scheduled {
                addTodo {
                    $0.title = t.title
                    $0.notes = t.notes
                    $0.priority = t.priority
                    $0.source = t.source
                    $0.rrule = rrule
                    $0.bill = t.bill
                    $0.noteId = t.noteId
                    $0.spaceId = t.spaceId
                    $0.dueAt = nextDue ?? (t.remindAt != nil ? nil
                        : Recurrence.nextAfterCompleting(base, rrule))
                    $0.remindAt = nextRemind
                    $0.reminded = false
                }
                out.append("🔁 Next: \(t.title)")
            }
        }
        return out
    }

    /// What completing `t` did — the bill it logged and the next repeat it
    /// scheduled — removed again, when they were made at that moment and the
    /// next repeat hasn't been touched since.
    private func undoCompletion(of t: Todo) {
        guard let completed = t.completedAt.flatMap(DateKit.date) else { return }
        func madeThen(_ iso: String) -> Bool {
            DateKit.date(iso).map { abs($0.timeIntervalSince(completed)) < 5 } ?? false
        }
        if let bill = t.bill {
            for tx in all.transactions where tx.deletedAt == nil && tx.merchant == t.title
                && tx.amount == bill.amount && madeThen(tx.createdAt) {
                remove(.transactions, tx.id)
            }
        }
        if let rrule = t.rrule {
            for next in all.todos where next.deletedAt == nil && next.id != t.id && !next.done
                && next.title == t.title && next.rrule == rrule
                && madeThen(next.createdAt) && next.updatedAt == next.createdAt {
                remove(.todos, next.id)
            }
        }
    }

    // MARK: - Settings, budgets, categories

    func updateSettings(_ patch: (inout AppSettings) -> Void) {
        patch(&all.settings)
        all.settings.updatedAt = DateKit.nowIso()
    }

    func setBudget(_ category: String, _ amount: Double?) {
        updateSettings {
            if let amount, Money.isValidAmount(amount), amount > 0 {
                $0.budgets[category] = amount
            } else {
                $0.budgets[category] = nil
            }
        }
    }

    /// Apply settings from another device when they are newer. Does not bump timestamps.
    func mergeSettings(_ remote: AppSettings?) {
        guard let remote else { return }
        let localAt = all.settings.updatedAt
        if let remoteAt = remote.updatedAt {
            if let localAt, remoteAt <= localAt { return }
        } else if localAt != nil {
            // An older backup without settings timestamps cannot supersede a
            // local document whose settings already carry one.
            return
        }
        all.settings.currency = remote.currency
        all.settings.budgets = remote.budgets
        all.settings.categories = remote.categories ?? all.settings.categories
        all.settings.name = remote.name ?? all.settings.name
        all.settings.voiceReplies = remote.voiceReplies
        all.settings.updatedAt = remote.updatedAt
    }

    /// Returns the created name, or nil when it's empty or a duplicate.
    @discardableResult
    func addCategory(_ name: String) -> String? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).prefix(40))
        guard !clean.isEmpty,
              !categories.contains(where: { $0.lowercased() == clean.lowercased() }) else { return nil }
        updateSettings { $0.categories = ($0.categories ?? []) + [clean] }
        return clean
    }

    func removeCategory(_ name: String) {
        updateSettings {
            $0.categories = ($0.categories ?? []).filter { $0 != name }
            $0.budgets = $0.budgets.filter { $0.key != name }
        }
    }

    // MARK: - Summaries and briefs

    func saveSummary(_ s: MonthlySummary) {
        all.summaries = [s] + all.summaries.filter { $0.month != s.month }
    }

    func saveBrief(_ b: DailyBrief) {
        all.briefs = Array(([b] + all.briefs.filter { $0.date != b.date }).prefix(14))
    }

    func brief(for date: String) -> DailyBrief? { all.briefs.first { $0.date == date } }

    // MARK: - Spaces

    func setSpaces(_ spaces: [Space]) {
        let current = spaces.contains { $0.id == all.currentSpaceId } ? all.currentSpaceId : nil
        guard current != all.currentSpaceId || spaces != all.spaces else { return }
        all.spaces = spaces
        all.currentSpaceId = current
    }

    func switchSpace(_ id: String?) { all.currentSpaceId = id }

    // MARK: - Sync merge

    /// Merge rows pulled from the cloud; newer updatedAt wins. Does not bump timestamps.
    /// `keeping` combines a local row with the newer incoming one, for fields
    /// that never leave this Mac.
    func mergeRemote<T: BaseItem>(_ keyPath: WritableKeyPath<AppData, [T]>, _ rows: [T], reversed: Bool = false,
                                  keeping: ((_ local: T, _ incoming: T) -> T)? = nil) {
        guard !rows.isEmpty else { return }
        var byId = Dictionary(all[keyPath: keyPath].map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        var changed = false
        for r in rows {
            if let local = byId[r.id] {
                if r.updatedAt <= local.updatedAt { continue }
                byId[r.id] = keeping?(local, r) ?? r
            } else {
                byId[r.id] = r
            }
            changed = true
        }
        guard changed else { return }
        let list = byId.values.sorted { $0.createdAt > $1.createdAt }
        all[keyPath: keyPath] = reversed ? list.reversed() : list
    }

    /// Merge what Google Drive had. Scans are not synced, so a newer row from
    /// another device keeps this Mac's image.
    func applySync(_ remote: AppData) {
        mergeRemote(\.notes, remote.notes) { local, incoming in
            var note = incoming
            if note.imageFile == nil && note.imageDataUrl == nil {
                note.imageFile = local.imageFile
                note.imageDataUrl = local.imageDataUrl
            }
            return note
        }
        mergeRemote(\.todos, remote.todos)
        mergeRemote(\.transactions, remote.transactions) { local, incoming in
            var transaction = incoming
            if transaction.imageFile == nil && transaction.imageDataUrl == nil {
                transaction.imageFile = local.imageFile
                transaction.imageDataUrl = local.imageDataUrl
            }
            return transaction
        }
        mergeRemote(\.stickies, remote.stickies, reversed: true)
        // Settings without a timestamp have never been changed on the other
        // device; applying them would reset this Mac's currency to the default.
        if remote.settings.updatedAt != nil { mergeSettings(remote.settings) }
    }

    // MARK: - Sample data

    func loadSamples() {
        guard !hasSamples else { return }
        let s = Samples.build(currency: all.settings.currency)
        all.notes = s.notes + all.notes
        all.todos = s.todos + all.todos
        all.transactions = s.transactions + all.transactions
        all.stickies = all.stickies + s.stickies
        if all.settings.budgets.isEmpty {
            updateSettings { $0.budgets = Samples.budgets }
        }
    }

    func clearSamples() {
        all.notes = all.notes.filter { $0.sample != true }
        all.todos = all.todos.filter { $0.sample != true }
        all.transactions = all.transactions.filter { $0.sample != true }
        all.stickies = all.stickies.filter { $0.sample != true }
        // Only clear budgets the sample set added, never ones the user changed.
        updateSettings { s in
            for (category, value) in Samples.budgets where s.budgets[category] == value {
                s.budgets[category] = nil
            }
        }
    }

    /// Restoring a backup or erasing everything is a deliberate fresh start:
    /// saving may go ahead, even over a document that could not be read.
    func resumeSaving() {
        guard saveBlocked else { return }
        saveBlocked = false
        saveFailure = nil
    }

    func eraseEverything() {
        resumeSaving()
        all = AppData()
        if flush() { Attachments.removeOrphans(keeping: all) }
    }

    // MARK: - Static helpers

    /// Built-in categories plus the user's own, in a stable order.
    nonisolated static func categories(of settings: AppSettings) -> [String] {
        let custom = (settings.categories ?? []).filter { !EXPENSE_CATEGORIES.contains($0) }
        return EXPENSE_CATEGORIES.filter { $0 != "Other" } + custom + ["Other"]
    }

    /// Map a category coming from the AI onto one the user actually has.
    nonisolated static func matchCategory(_ name: String?, _ categories: [String]) -> String {
        guard let name else { return "Other" }
        if categories.contains(name) { return name }
        let target = name.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.first { $0.lowercased() == target } ?? "Other"
    }
}
