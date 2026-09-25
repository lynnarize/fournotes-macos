import AppKit
import Combine
import Foundation

// "Sync with Google Drive": when to sync, and what Settings shows about it.
// Ported from the web app's src/components/googleSync.tsx. Syncs on connect
// and launch, when the app comes to the front, a few seconds after an edit,
// and every two minutes.

@MainActor
final class GoogleSync: ObservableObject {
    enum Status: Equatable { case idle, syncing, synced, offline, error }

    @Published private(set) var account: GoogleAuth.Account?
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastSynced: Date?
    @Published private(set) var message: String?
    @Published private(set) var connecting = false

    private let store: Store
    private let toasts: ToastCenter
    private let auth = GoogleAuth.shared
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var pending: Task<Void, Never>?
    private var running = false
    private var again = false

    private static let cursorKey = "fournotes.google.cursor"
    private static let lastSyncedKey = "fournotes.google.lastSynced"
    private static let nameFilledKey = "fournotes.google.nameFilled"

    init(store: Store, toasts: ToastCenter) {
        self.store = store
        self.toasts = toasts
        account = auth.account
        lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
    }

    /// False when this build has no Google client ID.
    var isAvailable: Bool { GoogleAuth.clientId != nil }

    func start() {
        guard !AppModel.isTesting, cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.schedule(after: .milliseconds(300)) }
            .store(in: &cancellables)
        // Local edits → sync a few seconds later, so quick edits go together.
        store.$all.dropFirst()
            .debounce(for: .seconds(4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule(after: .zero) }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule(after: .zero) }
        }
        schedule(after: .zero)
    }

    // MARK: - Connect

    func connect() async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        do {
            let signedIn = try await auth.signIn()
            if signedIn.email != account?.email { UserDefaults.standard.removeObject(forKey: Self.cursorKey) }
            account = signedIn
            message = nil
            fillName(from: signedIn)
            toasts.push("Connected to Google\(signedIn.email.map { " as \($0)" } ?? ""). Syncing now.")
            await sync()
        } catch GoogleAuth.AuthError.cancelled {
            // The user closed the sign-in page; nothing to say.
        } catch {
            toasts.push(error.localizedDescription, tone: .error)
        }
    }

    /// Disconnects this Mac. The data stays here; with `deleteCopy`, the file
    /// in Drive goes too, which other devices will notice as a fresh start.
    func disconnect(deleteCopy: Bool) async {
        pending?.cancel()
        var deleted = false
        if deleteCopy {
            let drive = GoogleDrive { [auth] force in try await auth.token(force: force) }
            do {
                for file in try await drive.list() {
                    do { try await drive.delete(file.id) } catch DriveError.notFound {}
                }
                deleted = true
            } catch {
                toasts.push("Couldn't delete the copy in Google Drive: \(error.localizedDescription)", tone: .error)
            }
        }
        await auth.signOut()
        UserDefaults.standard.removeObject(forKey: Self.cursorKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
        account = nil
        lastSynced = nil
        status = .idle
        message = nil
        toasts.push(deleted
                    ? "Disconnected, and the copy in Google Drive was deleted."
                    : "Disconnected from Google. Your data stays on this Mac.")
    }

    /// First name from the Google account, once per account, only while "Your name" is empty.
    private func fillName(from account: GoogleAuth.Account) {
        guard let name = account.name, let email = account.email,
              UserDefaults.standard.string(forKey: Self.nameFilledKey) != email else { return }
        UserDefaults.standard.set(email, forKey: Self.nameFilledKey)
        if (store.settings.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            store.updateSettings { $0.name = name }
        }
    }

    // MARK: - Sync

    func syncNow() { schedule(after: .zero) }

    private func schedule(after delay: Duration) {
        guard account != nil else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            // Its own task: a later schedule() cancels only the wait, never a
            // sync already talking to Drive.
            Task { @MainActor in await self?.sync() }
        }
    }

    private func sync() async {
        guard let current = account, store.ready, !store.saveBlocked else { return }
        guard Connectivity.shared.isOnline else { status = .offline; return }
        if running { again = true; return }
        running = true
        status = .syncing
        defer {
            running = false
            if again {
                again = false
                schedule(after: .milliseconds(500))
            }
        }

        let drive = GoogleDrive { [auth] force in try await auth.token(force: force) }
        do {
            let cursor = try await DriveSync.run(drive: drive, local: store.all, cursor: loadCursor()) { remote in
                store.applySync(remote)
            }
            // Disconnected, or another account, while this was running: don't keep its cursor.
            guard account?.email == current.email else { return }
            saveCursor(cursor)
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: Self.lastSyncedKey)
            message = nil
            status = .synced
        } catch GoogleAuth.AuthError.notConnected(let reason) {
            account = nil
            UserDefaults.standard.removeObject(forKey: Self.cursorKey)
            message = reason
            status = .idle
        } catch DriveError.offline {
            status = .offline
        } catch {
            message = error.localizedDescription
            status = .error
        }
    }

    private func loadCursor() -> SyncCursor {
        guard let data = UserDefaults.standard.data(forKey: Self.cursorKey),
              let cursor = try? JSONDecoder().decode(SyncCursor.self, from: data) else { return SyncCursor() }
        return cursor
    }

    private func saveCursor(_ cursor: SyncCursor) {
        UserDefaults.standard.set(try? JSONEncoder().encode(cursor), forKey: Self.cursorKey)
    }
}
