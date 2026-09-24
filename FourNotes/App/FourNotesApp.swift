import AppKit
import SwiftUI

/// Quitting has to be a moment the app can react to. `.onDisappear` on a window
/// does not reliably run on Cmd+Q, so the document is flushed here instead —
/// and again when the app loses focus, so a crash costs at most the last edit.
///
/// Launch work lives here too, not in a window's `onAppear`: the edge dock
/// keeps the app running with no window open at all.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.jobs.start()
        if !AppModel.isTesting {
            EdgeDock.shared.install(model)
            EdgeStickies.shared.install(model)
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        let model = AppModel.shared
        model.jobs.stop()
        QuickTranscriber.shared.cancel()
        LocalServers.shared.stopLaunched()
        PendingWrites.flushAll()
        model.store.flush()
    }

    @MainActor
    func applicationDidResignActive(_ notification: Notification) {
        PendingWrites.flushAll()
        AppModel.shared.store.flush()
    }

    /// Clicking the app in the Dock brings its window back. It has to be
    /// done here: the edge dock is a window that's always on screen, so macOS
    /// reports the app as already showing one, and on its own neither macOS
    /// nor SwiftUI brought back a window that had been minimised or closed —
    /// clicking the icon did nothing.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Handled, or nothing to bring back yet: then SwiftUI makes a window.
        !EdgeDock.shared.revealMainWindow()
    }

    /// With the edge dock on, closing the window leaves the dock behind — the
    /// point of it. Without it, nothing benefits from staying open.
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !EdgeDock.shared.isEnabled
    }
}

@main
struct FourNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: Store
    @StateObject private var nav: Navigation
    @StateObject private var toasts: ToastCenter
    @StateObject private var assistant: Assistant
    @StateObject private var engine: AIEngine

    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue

    init() {
        let model = AppModel.shared
        _store = StateObject(wrappedValue: model.store)
        _nav = StateObject(wrappedValue: model.nav)
        _toasts = StateObject(wrappedValue: model.toasts)
        _engine = StateObject(wrappedValue: model.engine)
        _assistant = StateObject(wrappedValue: model.assistant)
    }

    private var theme: ThemeChoice { ThemeChoice(rawValue: themeRaw) ?? .system }

    var body: some Scene {
        WindowGroup(id: EdgeDock.mainWindowId) {
            PaletteProvider {
                RootView()
            }
            .environmentObject(store)
            .environmentObject(nav)
            .environmentObject(toasts)
            .environmentObject(assistant)
            .environmentObject(engine)
            .preferredColorScheme(theme.colorScheme)
            .background(OpenWindowCapture())
        }
        .defaultSize(width: 1180, height: 780)
        // No title bar. It held nothing but the app's name, and macOS 26 tints
        // it and draws a scroll-edge effect under it whenever a page scrolls
        // beneath — a band across the top that flickered in and out while
        // scrolling Finance, To-Do or Today. The traffic lights stay, and the
        // strip they sit in still drags the window.
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: store, nav: nav, assistant: assistant) }
    }
}

/// The native menu bar: the keyboard shortcuts the web app binds, plus the ones
/// a Mac app is expected to have.
struct AppCommands: Commands {
    let store: Store
    let nav: Navigation
    let assistant: Assistant

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { QuickCreate.note(store: store, nav: nav) }
                .keyboardShortcut("n", modifiers: .command)

            Button("New Task") { QuickCreate.task(store: store, nav: nav) }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Transaction") { QuickCreate.transaction(store: store, nav: nav) }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Button("New Sticky Note") { EdgeStickies.shared.stickNew() }
                .keyboardShortcut("n", modifiers: [.command, .control])
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Scan Receipt or Note…") { assistant.pickAndScan() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button(assistant.recording ? "Stop Recording" : "Record to Note") {
                assistant.recording ? assistant.stopRecording() : assistant.startRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { nav.present(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Go") {
            ForEach(Tab.allCases) { tab in
                Button(tab.title) { nav.tab = tab }
                    .keyboardShortcut(KeyEquivalent(Character("\(index(of: tab))")), modifiers: .command)
            }
            Divider()
            Button("Search or Quick Add…") { nav.present(.palette) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Open Edge Dock") { EdgeDock.shared.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
    }

    private func index(of tab: Tab) -> Int {
        (Tab.allCases.firstIndex(of: tab) ?? 0) + 1
    }
}
