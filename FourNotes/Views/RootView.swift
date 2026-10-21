import SwiftUI

// The app shell: sidebar, the four views, and the chat dock.
// Ported from src/app/page.tsx.

struct RootView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var assistant: Assistant
    @ObservedObject private var updates = UpdateCheck.shared

    var body: some View {
        HStack(spacing: 0) {
            if !focused {
                SidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
                Rectangle().fill(p.border).frame(width: 1).zIndex(1)
            }
            // Clipped, so a pane sliding out to the left (the notes list in
            // focus mode) goes behind the sidebar instead of across it.
            main.clipped()
        }
        .animation(Motion.screen, value: focused)
        // The page colour reaches up under the hidden title bar, which has no colour of
        // its own: `main` is clipped at the safe area, so without this the strip above
        // every page showed the window's white. As on the web, no wash behind Today.
        .background(p.bg.ignoresSafeArea())
        // Pages scroll to the top edge cleanly, with no blur or fade laid over
        // the first lines.
        .scrollEdgeEffectHidden(true, for: .top)
        .frame(minWidth: 900, minHeight: 600)
        .overlay { paletteOverlay }
        .animation(Motion.quick, value: nav.sheet == .palette)
        // First-run setup takes the whole window, not a sheet.
        .overlay {
            if nav.sheet == .onboarding {
                OnboardingView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(Motion.screen, value: nav.sheet == .onboarding)
        // Search floats over the window instead (see paletteOverlay), and
        // setup covers it (above).
        .fnSheet(item: Binding(get: { nav.sheet == .palette || nav.sheet == .onboarding ? nil : nav.sheet },
                               set: { nav.sheet = $0 })) { sheet in
            switch sheet {
            case .settings: SettingsView()
            case .update: UpdateSheet()
            case .onboarding: EmptyView()
            case .palette: EmptyView()
            }
        }
        // Menus and dialogs, drawn in the web app's style over the window.
        // Toasts stay above them, as on the web.
        .popupHost()
        .overlay(ToastStack().allowsHitTesting(false))
        .task {
            // A brand new install starts on the setup wizard.
            if store.needsOnboarding, nav.sheet == nil { nav.present(.onboarding) }
            // A release found on an earlier day is offered again a little after launch.
            try? await Task.sleep(for: .seconds(4))
            offerUpdate()
        }
        // …and one the daily check finds while the app is open.
        .onChange(of: updates.available?.version) { _, _ in offerUpdate() }
        .onChange(of: nav.tab) { _, tab in
            nav.clearPulse(tab)
            // Focus mode belongs to the note editor; any other tab brings the
            // app back.
            if tab != .notes { nav.focusMode = false }
        }
    }

    /// The update pop-up, once a launch, never over another sheet or the first-run setup.
    private func offerUpdate() {
        guard updates.shouldPrompt, nav.sheet == nil, !store.needsOnboarding else { return }
        updates.didPrompt()
        nav.present(.update)
    }

    /// Search and quick add, over a dimmed window. A sheet on macOS ignores
    /// clicks outside it; this closes on one, as Spotlight does.
    @ViewBuilder
    private var paletteOverlay: some View {
        if nav.sheet == .palette {
            ZStack(alignment: .top) {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.sheet = nil }
                    .accessibilityLabel("Close search")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                CommandPaletteView()
                    .padding(.top, 90)
                    .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            }
        }
    }

    /// The note editor has the whole window.
    private var focused: Bool { nav.focusMode && nav.tab == .notes }

    private var main: some View {
        ZStack(alignment: .bottom) {
            content
                .id(nav.tab)
                .transition(.opacity.combined(with: .offset(y: 8)))
                .animation(Motion.screen, value: nav.tab)
            // Today has the assistant in the middle of its page; everywhere
            // else it's a round button in the corner.
            if nav.tab != .today {
                ChatDock(minimized: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(p.bg)
        .entrance(delay: 0.03)
    }

    @ViewBuilder
    private var content: some View {
        // Notes fills the window (its list and editor scroll on their own);
        // other tabs scroll the page.
        if nav.tab == .notes {
            // Notes is a pair of panes running edge to edge — list, then
            // editor — with its title inside the list, as in the reference.
            NotesView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if nav.tab == .today, store.ready {
            // Today scrolls itself: the page beside its cards, the conversation
            // opening as a card in the page.
            TodayView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    tabContent
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 90)
                .frame(maxWidth: FN.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Every tab: same width, same side padding, same title position.
    /// Today's big greeting stands in for the title.
    @ViewBuilder
    private var header: some View {
        if nav.tab != .today {
            HStack(spacing: 12) {
                Text(nav.tab.title)
                    .font(FN.title)
                    .tracking(FN.displayTracking(34))
                    .foregroundStyle(p.foreground)
                if let space = store.spaceName {
                    Chip(tone: nil) {
                        Icon("users", size: 12)
                        Text(space)
                    }
                }
            }
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        if !store.ready {
            Text("Loading…").font(FN.body).foregroundStyle(p.muted)
        } else {
            switch nav.tab {
            case .today: TodayView()
            case .notes: EmptyView()
            case .todo: TodoView()
            case .finance: FinanceView()
            }
        }
    }
}
