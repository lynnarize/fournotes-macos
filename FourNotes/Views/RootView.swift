import SwiftUI

// The app shell: sidebar, the four views, and the chat dock.
// Ported from src/app/page.tsx.

struct RootView: View {
    @Environment(\.palette) private var p
    @Environment(\.colorScheme) private var scheme
    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var assistant: Assistant

    var body: some View {
        HStack(spacing: 0) {
            if !focused {
                SidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(1)
                Divider().overlay(p.line).zIndex(1)
            }
            // Clipped, so a pane sliding out to the left (the notes list in
            // focus mode) goes behind the sidebar instead of across it.
            main.clipped()
        }
        .animation(Motion.screen, value: focused)
        .background {
            // Today sits on the setup's soft light; the other tabs are plain.
            // Both reach up under the hidden title bar, which has no colour of
            // its own: `main` is clipped at the safe area, so without this the
            // strip above every page showed the window's white. The page
            // colour stays underneath so the fade to and from Today never
            // shows it either.
            ZStack {
                p.bg
                if nav.tab == .today {
                    CalmBackground.page(p, theme: ThemeChoice(rawValue: themeRaw) ?? .system, scheme: scheme)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .animation(Motion.screen, value: nav.tab == .today)
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
        .overlay(ToastStack().allowsHitTesting(false))
        // Search floats over the window instead (see paletteOverlay), and
        // setup covers it (above).
        .sheet(item: Binding(get: { nav.sheet == .palette || nav.sheet == .onboarding ? nil : nav.sheet },
                             set: { nav.sheet = $0 })) { sheet in
            switch sheet {
            case .settings: SettingsView()
            case .onboarding: EmptyView()
            case .palette: EmptyView()
            }
        }
        .task {
            // A brand new install starts on the setup wizard.
            if store.needsOnboarding, nav.sheet == nil { nav.present(.onboarding) }
        }
        .onChange(of: nav.tab) { _, tab in
            nav.clearPulse(tab)
            // Focus mode belongs to the note editor; any other tab brings the
            // app back.
            if tab != .notes { nav.focusMode = false }
        }
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
        // Today's soft light is drawn behind the whole window (below), so it
        // reaches up under the title bar; the page itself is clear.
        .background(nav.tab == .today ? Color.clear : p.bg)
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
            // Today is one page that fits the window: no scrolling. The
            // conversation opens over it rather than pushing it down.
            TodayView()
                .padding(.horizontal, 28)
                .frame(maxWidth: FN.maxContentWidth, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
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
                    .tracking(-0.4)
                    .foregroundStyle(p.text)
                if let space = store.spaceName {
                    Chip(tone: nil) {
                        Icon("users", size: 12)
                        Text(space)
                    }
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 20)
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
