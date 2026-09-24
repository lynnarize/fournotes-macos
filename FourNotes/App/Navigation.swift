import Combine
import SwiftUI

// Cross-view navigation: which tab is showing, which sheet is open, and the
// "jump to the thing the assistant just filed" plumbing.
// Replaces src/lib/nav.ts and src/lib/highlight.ts.

@MainActor
final class Navigation: ObservableObject {
    /// Opening a tab clears its "something new" dot.
    @Published var tab: Tab = .today {
        didSet { pulsing.remove(tab) }
    }
    /// A window shows one sheet at a time, so there is one place that says
    /// which. Three independent booleans meant ⌘, over an open palette silently
    /// did nothing and could not be reopened.
    enum Sheet: String, Identifiable, Equatable {
        case settings, palette, onboarding
        var id: String { rawValue }
    }

    @Published var sheet: Sheet?
    @Published var settingsSection: String?

    var showSettings: Bool { sheet == .settings }

    /// The row a view should reveal, once.
    ///
    /// Carries its own identity so two requests for the same row are still two
    /// requests. Views consume it with `.task(id:)` rather than `.onChange`,
    /// because switching tabs *creates* the destination view — and `.onChange`
    /// never fires on a value that was already set when the view appeared,
    /// which left every "Show" button in the app doing nothing.
    struct FocusRequest: Equatable, Identifiable {
        let id = UUID()
        var link: ChangeLink
    }

    @Published var focus: FocusRequest?
    /// Rows filed in the last few seconds, so they can flash.
    @Published private(set) var flashing: Set<String> = []
    /// Tabs with something new in them, so their sidebar row can pulse.
    @Published private(set) var pulsing: Set<Tab> = []

    /// Notes: which note the editor has open.
    @Published var selectedNoteId: String?

    /// The note editor fills the window: no sidebar, no note list, no title.
    /// Lives here because RootView owns the sidebar it has to hide.
    @Published var focusMode = false

    /// Text to put in the assistant's input and open it with — filled in, not
    /// sent, so the request can be reviewed first.
    @Published var assistantDraft: String?

    /// The day a brief has already been requested for. Lives here rather than
    /// on TodayView, which is destroyed and rebuilt on every tab switch — so
    /// the flag reset and another model call went out each time.
    var briefRequestedFor: String?

    func open(_ link: ChangeLink) {
        focusMode = false
        switch link.kind {
        case .notes:
            tab = .notes
            selectedNoteId = link.id
        case .todos: tab = .todo
        case .transactions, .budget: tab = .finance
        case .stickies: tab = .today
        }
        focus = FocusRequest(link: link)
    }

    /// Takes the pending request when it is meant for one of `kinds`, and clears
    /// it so it cannot be delivered twice.
    func consumeFocus(_ kinds: Set<ChangeLink.Kind>) -> ChangeLink? {
        guard let focus, kinds.contains(focus.link.kind) else { return nil }
        self.focus = nil
        return focus.link
    }

    func openSettings(section: String? = nil) {
        settingsSection = section
        present(.settings)
    }

    /// Shows a sheet, swapping out whatever is already up.
    ///
    /// Assigning over a presented sheet does nothing on macOS, and dismissing
    /// and presenting in the same runloop turn drops the new one — so a swap
    /// has to wait a turn. Every caller goes through here so neither mistake
    /// can come back.
    func present(_ next: Sheet) {
        guard sheet != nil else { sheet = next; return }
        sheet = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            sheet = next
        }
    }

    /// Flash the rows the assistant just created, and pulse the tabs they landed in.
    func markFiled(_ links: [ChangeLink]) {
        guard !links.isEmpty else { return }
        let ids = Set(links.map(\.id))
        flashing.formUnion(ids)

        let tabs = Set(links.compactMap { link -> Tab? in
            switch link.kind {
            case .notes: return .notes
            case .todos: return .todo
            case .transactions, .budget: return .finance
            case .stickies: return .today
            }
        })
        pulsing.formUnion(tabs.subtracting([tab]))

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            self?.flashing.subtract(ids)
        }
    }

    func clearPulse(_ tab: Tab) { pulsing.remove(tab) }

    /// The user went to look at what was filed: nothing there is news any more.
    func clearPulses(for links: [ChangeLink]) {
        for link in links {
            switch link.kind {
            case .notes: pulsing.remove(.notes)
            case .todos: pulsing.remove(.todo)
            case .transactions, .budget: pulsing.remove(.finance)
            case .stickies: pulsing.remove(.today)
            }
        }
    }

    func isFlashing(_ id: String) -> Bool { flashing.contains(id) }
}
