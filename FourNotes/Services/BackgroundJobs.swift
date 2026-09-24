import AppKit
import SwiftUI
import UserNotifications

// Runs while the app is open: reminders, the end-of-month review, the
// sample-data clean-up offer, and exchange rates for foreign transactions.
// Ported from src/components/BackgroundJobs.tsx, with real macOS notifications
// and a Dock badge in place of the web version's Notification API.

@MainActor
final class BackgroundJobs: ObservableObject {
    private unowned let store: Store
    private let toasts: ToastCenter
    private let engine: AIEngine

    private var timer: Timer?
    private var ranMonthlyReview = false
    private var offeredCleanup = false
    private var triedFX: Set<String> = []

    init(store: Store, toasts: ToastCenter, engine: AIEngine) {
        self.store = store
        self.toasts = toasts
        self.engine = engine
    }

    func start() {
        // Driven from a window's onAppear, so this can be called more than once.
        // Reassigning `timer` without invalidating left the old one running:
        // duplicate reminders that no longer belonged to anything.
        guard timer == nil else { return }
        requestNotificationPermission()
        tick()
        // 1) Reminders: check every 20 seconds (all spaces).
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task {
            await runMonthlyReview()
            await fetchMissingRates()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// True once `start()` has taken effect, so callers need not track it.
    var isRunning: Bool { timer != nil }

    // MARK: - Reminders

    private func tick() {
        guard store.ready else { return }
        let now = Date()
        for t in store.all.todos where t.deletedAt == nil {
            guard !t.done, t.reminded != true,
                  let at = DateKit.date(t.remindAt), at <= now else { continue }
            store.updateTodo(t.id) { $0.reminded = true }
            toasts.push("⏰ Reminder: \(t.title)")
            notify(title: "Four Notes reminder", body: t.title, id: t.id)
        }
        updateDockBadge()
        offerSampleCleanup()
        // A transaction in a new currency can arrive at any time; waiting for
        // the next launch meant counting it at face value in the meantime.
        Task { await fetchMissingRates() }
    }

    /// The Dock icon shows what is due today and still open.
    private func updateDockBadge() {
        let endToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
        let due = store.liveTodos.filter { todo in
            !todo.done && (DateKit.date(todo.dueAt).map { $0 <= endToday } ?? false)
        }.count
        NSApp.dockTile.badgeLabel = due > 0 ? "\(due)" : nil
    }

    private func requestNotificationPermission() {
        // The async form: a completion closure written here would be
        // main-actor-isolated and trap when the answer arrives on a background
        // queue, the same crash that stopped recording.
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    private func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - End-of-month review

    /// When a new month starts, summarise last month once.
    private func runMonthlyReview() async {
        guard store.ready, !ranMonthlyReview, engine.canSummarize else { return }
        ranMonthlyReview = true

        let cal = Calendar.current
        guard let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())),
              let lastDay = cal.date(byAdding: .day, value: -1, to: thisMonthStart) else { return }
        let prev = DateKit.localMonth(lastDay)

        if store.summaries.contains(where: { $0.month == prev && !AIText.looksLikeThinking($0.text) }) { return }

        let txs = store.liveTransactions.filter { $0.date.hasPrefix(prev) }
        guard !txs.isEmpty else { return }

        let cur = store.settings.currency
        let total = txs.reduce(0.0) { $0 + max(0, Insights.baseAmount($1, cur)) }
        do {
            let text = try await engine.monthlySummary(month: prev, currency: cur, transactions: txs)
            store.saveSummary(MonthlySummary(month: prev, total: total, currency: cur,
                                             byCategory: [:], text: text,
                                             createdAt: DateKit.nowIso()))
            toasts.push("📊 Your \(prev) spending review is ready in Finance")
        } catch {
            // Offline or no server: try again next launch.
            ranMonthlyReview = false
        }
    }

    // MARK: - Sample data

    /// Once the user has their own items, offer to remove the sample data.
    private func offerSampleCleanup() {
        guard store.ready, !offeredCleanup, store.hasSamples else { return }
        let own = store.all.notes.filter { $0.deletedAt == nil && $0.sample != true }.count
            + store.all.todos.filter { $0.deletedAt == nil && $0.sample != true }.count
            + store.all.transactions.filter { $0.deletedAt == nil && $0.sample != true }.count
        guard own >= 3 else { return }
        offeredCleanup = true
        toasts.push("You've added a few of your own items. Remove the sample data?",
                    action: Toast.Action(label: "Remove") { [weak self] in self?.store.clearSamples() })
    }

    // MARK: - Exchange rates

    /// Fetch exchange rates for foreign transactions that lack one.
    func fetchMissingRates() async {
        guard store.ready else { return }
        let base = store.settings.currency
        let missing = Set(store.all.transactions
            .filter { $0.deletedAt == nil && $0.currency != base && $0.fxRate == nil }
            .map(\.currency))

        for currency in missing {
            let key = "\(currency)>\(base)"
            guard !triedFX.contains(key) else { continue }
            // Held only while the request is out, so two passes don't both
            // fetch it. It used to stay after a success, so after switching
            // the base currency away and back, that pair was never fetched
            // again and its spending counted 1:1.
            triedFX.insert(key)
            defer { triedFX.remove(key) }
            guard let rate = try? await engine.fx(from: currency, to: base),
                  // The base changed while the rate was on its way: it's a
                  // rate to the wrong currency now.
                  store.settings.currency == base else { continue }
            for t in store.all.transactions where t.currency == currency && t.fxRate == nil {
                store.updateTransaction(t.id) { $0.fxRate = rate }
            }
        }
    }
}
