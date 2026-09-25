import Foundation

// The app's long-lived objects, made once.
//
// They used to be created by the window scene, which was fine while the
// window was the only thing on screen. The edge dock lives outside it and
// outlives it — close the window and the dock stays — so both take the same
// instances from here. A second Store would write the same file twice.

@MainActor
final class AppModel {
    static let shared = AppModel()

    let store: Store
    let nav: Navigation
    let toasts: ToastCenter
    let engine: AIEngine
    let assistant: Assistant
    let jobs: BackgroundJobs
    let sync: GoogleSync

    private init() {
        store = Store()
        nav = Navigation()
        toasts = ToastCenter()
        engine = AIEngine()
        assistant = Assistant(store: store, nav: nav, toasts: toasts, engine: engine)
        jobs = BackgroundJobs(store: store, toasts: toasts, engine: engine)
        sync = GoogleSync(store: store, toasts: toasts)
    }

    /// True inside the unit tests' host app, which should not put anything
    /// on the screen edge.
    nonisolated static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
