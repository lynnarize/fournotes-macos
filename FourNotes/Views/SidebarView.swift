import SwiftUI

// The fixed sidebar: who and where you are, search, the four tabs, quick
// capture and settings. The tabs are cards, the open one raised; everything
// else is a flat row.
// Laid out after the reference design; the content is still that of
// src/components/Sidebar.tsx.

struct SidebarView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var assistant: Assistant
    @ObservedObject private var servers = LocalServers.shared
    @ObservedObject private var updates = UpdateCheck.shared

    private var counts: [Tab: Int] {
        let month = DateKit.localMonth()
        let endToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
        return [
            .today: store.liveTodos.filter { !$0.done && (DateKit.date($0.dueAt).map { $0 <= endToday } ?? false) }.count,
            .notes: store.liveNotes.count,
            .todo: store.liveTodos.filter { !$0.done }.count,
            .finance: store.liveTransactions.filter { $0.date.hasPrefix(month) }.count,
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileCard
                .padding(.bottom, 6)

            searchCard

            let counts = counts
            VStack(spacing: 6) {
                ForEach(Tab.allCases) { tab in
                    TabRow(tab: tab, count: counts[tab] ?? 0, entries: { entries(for: tab) })
                }
            }
            .padding(.top, 28)

            Spacer(minLength: 16)

            // A local model server holds a model in memory until it's stopped.
            ForEach(servers.running) { kind in
                ServerRunningRow(kind: kind)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }

            // Capture, side by side.
            HStack(spacing: 6) {
                CaptureButton(icon: "scan", title: "Scan", help: "Scan a receipt, note or e-wallet screenshot",
                              disabled: assistant.busy != nil) {
                    assistant.pickAndScan()
                }
                CaptureButton(icon: assistant.recording ? "stop" : "mic",
                              title: assistant.recording ? "Stop" : "Record",
                              help: assistant.recording ? "Stop recording" : "Record a voice note",
                              tone: assistant.recording ? p.danger : nil,
                              disabled: assistant.busy != nil && !assistant.recording) {
                    assistant.recording ? assistant.stopRecording() : assistant.startRecording()
                }
            }
            .padding(.bottom, 8)

            // Where your data is kept in step, as the web sidebar shows it.
            if AppModel.shared.sync.isAvailable {
                SyncStatusRow(sync: AppModel.shared.sync)
                    .padding(.bottom, 2)
            }

            SidebarCard(icon: "settings", title: "Settings",
                        badge: updates.hasUnseenUpdate ? "A new version is available" : nil) {
                // With a new version waiting, open where it can be downloaded.
                if updates.hasUnseenUpdate { nav.openSettings(section: "about") } else { nav.present(.settings) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 256, alignment: .leading)
        .background(p.panel)
        .animation(Motion.standard, value: servers.running)
        .entrance()
        .task { servers.startWatching() }
        .onDisappear { servers.stopWatching() }
    }

    // MARK: - Who and where

    private var displayName: String {
        let name = store.settings.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Four Notes" : name
    }

    private var initials: String? {
        let name = store.settings.name?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty else { return nil }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }

    private var spaceLabel: String {
        store.currentSpaceId.flatMap { id in store.spaces.first { $0.id == id }?.name } ?? "Personal"
    }

    /// The account card: whose notes these are and which space is showing,
    /// with spaces and settings behind it.
    private var profileCard: some View {
        MenuButton(help: "Spaces and settings") {
            var entries: [MenuEntry] = []
            if !store.spaces.isEmpty {
                entries.append(.header("Space"))
                entries.append(.item("Personal", checked: store.currentSpaceId == nil) { store.switchSpace(nil) })
                entries += store.spaces.map { space in
                    .item(space.name, checked: store.currentSpaceId == space.id) { store.switchSpace(space.id) }
                }
                entries.append(.divider)
            }
            entries += [
                .item("Search or quick add…") { nav.present(.palette) },
                .item("Settings…") { nav.present(.settings) },
            ]
            return entries
        } label: {
            SidebarCardBody { hovering in
                HStack(spacing: 10) {
                    avatar
                    VStack(alignment: .leading, spacing: 1) {
                        Text(displayName)
                            .font(FN.font(15, .semibold))
                            .foregroundStyle(p.text)
                            .lineLimit(1)
                        Text(spaceLabel)
                            .font(FN.small)
                            .foregroundStyle(p.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Icon("chevronDown", size: 14)
                        .foregroundStyle(hovering ? p.text : p.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 60)
            }
        }
        .accessibilityLabel("\(displayName), \(spaceLabel)")
    }

    @ViewBuilder
    private var avatar: some View {
        if let initials {
            Text(initials)
                .font(FN.font(14, .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(p.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            Logo(size: 28)
                .frame(width: 36, height: 36)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var searchCard: some View {
        Button { nav.present(.palette) } label: {
            SidebarCardBody { hovering in
                HStack(spacing: 10) {
                    Icon("search", size: 17)
                    Text("Search…").font(FN.font(14)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("⌘K")
                        .font(FN.tiny)
                        .foregroundStyle(p.faint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(p.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .foregroundStyle(hovering ? p.text : p.muted)
                .padding(.horizontal, 14)
                .frame(height: 46)
            }
        }
        .buttonStyle(.fn)
        .accessibilityLabel("Search or quick add")
    }

    // MARK: - Tab actions

    /// What a tab's "…" menu offers: making the thing that tab holds.
    private func entries(for tab: Tab) -> [MenuEntry] {
        switch tab {
        case .today:
            return [
                .item("Open Today") { nav.tab = .today },
                .item("Search or quick add…") { nav.present(.palette) },
            ]
        case .notes:
            return [
                .item("New note") { QuickCreate.note(store: store, nav: nav) },
                .item("Scan a note…") { assistant.pickAndScan() },
                .item(assistant.recording ? "Stop recording" : "Record to note") {
                    assistant.recording ? assistant.stopRecording() : assistant.startRecording()
                },
            ]
        case .todo:
            return [.item("New task") { QuickCreate.task(store: store, nav: nav) }]
        case .finance:
            return [
                .item("New transaction") { QuickCreate.transaction(store: store, nav: nav) },
                .item("Scan a receipt…") { assistant.pickAndScan() },
            ]
        }
    }
}

// MARK: - Rows

/// One tab: icon and name, its count, and a "…" menu. The open tab is a
/// raised card; the rest sit flat on the sidebar until hovered.
private struct TabRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigation
    @State private var hovering = false

    let tab: Tab
    let count: Int
    let entries: () -> [MenuEntry]

    var body: some View {
        let selected = nav.tab == tab
        let hasNew = nav.pulsing.contains(tab)

        HStack(spacing: 0) {
            Button { nav.tab = tab } label: {
                HStack(spacing: 12) {
                    Icon(tab.sidebarIcon, size: 18)
                    Text(tab.title).font(selected ? FN.font(14, .medium) : FN.font(14))
                    if tab == .finance {
                        // Still being shaped: said plainly beside its name.
                        Text("Beta")
                            .font(FN.font(10, .semibold))
                            .foregroundStyle(p.danger)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(p.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(p.danger.opacity(0.45), lineWidth: 1))
                    }
                    if hasNew {
                        Circle()
                            .fill(p.accent)
                            .frame(width: 6, height: 6)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                    Spacer(minLength: 4)
                    // The count gives way to the menu while the row is in use.
                    if count > 0 && !(hovering || selected) {
                        Text("\(count)")
                            .font(FN.small)
                            .monospacedDigit()
                            .foregroundStyle(p.faint)
                            .contentTransition(.numericText())
                            .transition(.opacity)
                    }
                }
                .foregroundStyle(selected || hovering ? p.text : p.muted)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .accessibilityLabel(tab.title)
            .accessibilityValue(count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            if hovering || selected {
                IconMenu("more", size: 18, box: 30, help: "\(tab.title) actions", entries: entries)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? p.bg : (hovering ? p.hover : .clear))
                .shadow(color: selected ? p.shadow : .clear, radius: 6, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? p.line : .clear, lineWidth: 1)
        }
        .motion(selected, Motion.quick)
        .motion(hovering, Motion.quick)
        .motion(hasNew, Motion.pulse)
        .onHover { hovering = $0 }
    }
}

/// The account, search and bottom actions: flat rows that only light up
/// under the pointer. Only the tabs are cards.
private struct SidebarCardBody<Content: View>: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(hovering)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .motion(hovering, Motion.quick)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A bottom action — capture, settings — in the reference's "Add new folder"
/// and "Settings" places.
private struct SidebarCard: View {
    @Environment(\.palette) private var p
    let icon: String
    let title: String
    var tone: Color?
    var disabled = false
    /// Puts a small dot on the icon; the text says why, for VoiceOver and
    /// the tooltip.
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarCardBody { hovering in
                HStack(spacing: 12) {
                    Icon(icon, size: 18).foregroundStyle(tone ?? (hovering ? p.text : p.muted))
                        .overlay(alignment: .topTrailing) {
                            if badge != nil {
                                Circle()
                                    .fill(p.danger)
                                    .frame(width: 8, height: 8)
                                    .overlay(Circle().stroke(p.panel, lineWidth: 1.5))
                                    .offset(x: 3, y: -2)
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            }
                        }
                        .animation(Motion.standard, value: badge != nil)
                    Text(title).font(FN.font(14))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hovering ? p.text : p.muted)
                .padding(.horizontal, 14)
                .frame(height: 46)
            }
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .motion(disabled, Motion.quick)
        .help(badge ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? "")
    }
}

/// Half of the capture row: icon over nothing, name beside it.
private struct CaptureButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let icon: String
    let title: String
    let help: String
    var tone: Color?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(icon, size: 17)
                Text(title).font(FN.font(14)).lineLimit(1)
            }
            .foregroundStyle(tone ?? (hovering ? p.text : p.muted))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(hovering ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.line, lineWidth: 1))
            .contentShape(Rectangle())
            .motion(hovering, Motion.quick)
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 && !disabled }
    }
}

/// "LM Studio is running" with a Stop button, while a local server is on.
private struct ServerRunningRow: View {
    @Environment(\.palette) private var p
    @ObservedObject private var servers = LocalServers.shared
    let kind: LocalServers.Kind

    var body: some View {
        let working = servers.working.contains(kind)
        HStack(spacing: 8) {
            Icon("warning", size: 14).foregroundStyle(p.boardAmberInk)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(kind.name) is running").font(FN.font(13, .medium)).foregroundStyle(p.text).lineLimit(1)
                Text("Using memory until stopped").font(FN.tiny).foregroundStyle(p.faint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(working ? "Stopping…" : "Stop") { Task { await servers.stop(kind) } }
                .buttonStyle(.fn)
                .font(FN.font(12, .medium))
                .foregroundStyle(p.danger)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(p.danger.opacity(0.12), in: Capsule())
                .disabled(working)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(p.boardAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.boardAmber.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.name) server is running")
    }
}

extension Tab {
    /// The sidebar uses the app's own glyphs, not SF Symbols.
    var sidebarIcon: String {
        switch self {
        case .today: return "today"
        case .notes: return "note"
        case .todo: return "todo"
        case .finance: return "finance"
        }
    }
}

/// Sync at a glance: a cloud, green once synced, red on an error, with the
/// state beside it. Opens Settings at Sync.
private struct SyncStatusRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigation
    @ObservedObject var sync: GoogleSync
    @State private var hovering = false

    private var label: String {
        guard sync.account != nil else { return "Turn on sync" }
        switch sync.status {
        case .syncing: return "Syncing… · Google Drive"
        case .offline: return "Offline · Google Drive"
        case .error: return "Sync error · Google Drive"
        case .synced: return "Synced · Google Drive"
        case .idle: return sync.lastSynced == nil ? "Not synced yet · Google Drive" : "Synced · Google Drive"
        }
    }

    private var tone: Color {
        guard sync.account != nil else { return p.faint }
        switch sync.status {
        case .error: return p.danger
        case .synced: return p.ok
        case .idle: return sync.lastSynced == nil ? p.faint : p.ok
        case .syncing, .offline: return p.faint
        }
    }

    private var help: String {
        if sync.status == .error, let message = sync.message { return message }
        if let last = sync.lastSynced { return "Last synced \(last.formatted(.relative(presentation: .named)))" }
        return "Keep this Mac and the web app in step through Google Drive"
    }

    var body: some View {
        Button { nav.openSettings(section: "sync") } label: {
            HStack(spacing: 8) {
                Icon("cloud", size: 13)
                    .foregroundStyle(tone)
                    .opacity(sync.status == .syncing ? 0.6 : 1)
                    .motion(sync.status, Motion.quick)
                Text(label).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(FN.small)
            .foregroundStyle(hovering ? p.muted : p.faint)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(hovering ? p.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}
