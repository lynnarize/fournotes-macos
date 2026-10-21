import SwiftUI

// The sidebar, after Arc, as on the web (src/components/Sidebar.tsx): the space
// switcher with the mark, a search field that opens ⌘K, the four places with their
// counts, then capture (Scan, Record) and Settings, and a last line saying where the
// data lives.

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
        VStack(alignment: .leading, spacing: 20) {
            spaceSwitcher

            searchField

            // The four places. The count gives way to a menu of quick actions while a
            // row is in use.
            let counts = counts
            VStack(spacing: 2) {
                ForEach(Tab.allCases) { tab in
                    TabRow(tab: tab, count: counts[tab] ?? 0, entries: { entries(for: tab) })
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                // A local model server holds a model in memory until it's stopped.
                ForEach(servers.running) { kind in
                    ServerRunningRow(kind: kind)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }

                // Capture, side by side.
                HStack(spacing: 8) {
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

                NavRow(icon: "settings", title: "Settings", shortcut: "⌘,",
                       badge: updates.hasUnseenUpdate ? "A new version is available" : nil) {
                    // With a new version waiting, open where it can be downloaded.
                    if updates.hasUnseenUpdate { nav.openSettings(section: "about") } else { nav.present(.settings) }
                }
            }

            // Where the data lives.
            SyncStatusRow(sync: AppModel.shared.sync.isAvailable ? AppModel.shared.sync : nil)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 248, alignment: .leading)
        .background(p.sidebar)
        .animation(Motion.standard, value: servers.running)
        .entrance()
        .task { servers.startWatching() }
        .onDisappear { servers.stopWatching() }
    }

    // MARK: - Who and where

    private var spaceLabel: String {
        store.currentSpaceId.flatMap { id in store.spaces.first { $0.id == id }?.name } ?? "Personal"
    }

    /// The space switcher: the mark, "Four Notes" and the space showing, with spaces,
    /// search and settings behind it.
    private var spaceSwitcher: some View {
        MenuButton(help: "Switch space") {
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
                .item("Search or add…") { nav.present(.palette) },
                .item("Settings…") { nav.present(.settings) },
            ]
            return entries
        } label: {
            HoverRow(cornerRadius: FN.radiusControl) { hovering in
                HStack(spacing: 10) {
                    Logo(size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Four Notes")
                            .font(FN.font(13, .medium))
                            .foregroundStyle(p.foreground)
                            .lineLimit(1)
                        Text(spaceLabel)
                            .font(FN.small)
                            .foregroundStyle(p.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Icon("chevronsUpDown", size: 15)
                        .foregroundStyle(hovering ? p.foreground : p.textMuted)
                }
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
        }
        .accessibilityLabel("Four Notes, \(spaceLabel)")
    }

    /// A field that opens search and quick add (⌘K).
    private var searchField: some View {
        Button { nav.present(.palette) } label: {
            SearchFieldBody()
        }
        .buttonStyle(.fn)
        .accessibilityLabel("Search or add")
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

/// The search field's look: a hairline field with the shortcut at its end.
private struct SearchFieldBody: View {
    @Environment(\.palette) private var p
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Icon("search", size: 15)
            Text("Search or add").font(FN.font(13)).lineLimit(1)
            Spacer(minLength: 4)
            Text("⌘K")
                .font(FN.font(11))
                .foregroundStyle(p.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(p.surfaceMuted, in: Capsule())
        }
        .foregroundStyle(p.textMuted)
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(p.surface, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
            .strokeBorder(hovering ? p.borderStrong : p.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
    }
}

/// One place: icon and name, its count, and a "…" menu. The kit's nav row: the open
/// one on the accent wash, its icon in the accent.
private struct TabRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigation
    @State private var hovering = false

    let tab: Tab
    let count: Int
    let entries: () -> [MenuEntry]

    var body: some View {
        let selected = nav.tab == tab
        let hasNew = nav.pulsing.contains(tab) && !selected

        ZStack(alignment: .trailing) {
            Button { nav.tab = tab } label: {
                HStack(spacing: 10) {
                    Icon(tab.sidebarIcon, size: 16)
                        .foregroundStyle(selected ? p.accent : (hovering ? p.foreground : p.textSecondary))
                    Text(tab.title)
                        .font(FN.font(13, selected ? .medium : .regular))
                        .foregroundStyle(selected || hovering ? p.foreground : p.textSecondary)
                    if tab == .finance {
                        // Still being shaped: said plainly beside its name.
                        Badge(text: "Beta")
                    }
                    Spacer(minLength: 4)
                    if hasNew {
                        Circle()
                            .fill(p.accent)
                            .frame(width: 7, height: 7)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                            .accessibilityLabel("New from the assistant")
                    }
                    // The count gives way to the menu while the row is in use.
                    if count > 0 {
                        Text("\(count)")
                            .font(FN.small)
                            .monospacedDigit()
                            .foregroundStyle(p.textMuted)
                            .contentTransition(.numericText())
                            .opacity(hovering ? 0 : 1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(selected ? p.accentSubtle : (hovering ? p.hover : .clear),
                            in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .accessibilityLabel(tab.title)
            .accessibilityValue(count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)

            if hovering {
                IconMenu("more", size: 16, box: 26, help: "\(tab.title) actions", entries: entries)
                    .padding(.trailing, 4)
                    .transition(.opacity)
            }
        }
        .motion(selected, Motion.quick)
        .motion(hovering, Motion.quick)
        .motion(hasNew, Motion.standard)
        .onHover { hovering = $0 }
    }
}

/// A row at the bottom of the sidebar (Settings), in the nav row's style, with its
/// shortcut at the end.
private struct NavRow: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let icon: String
    let title: String
    var shortcut: String?
    /// Puts a small dot on the icon; the text says why, for VoiceOver and the tooltip.
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 16)
                    .overlay(alignment: .topTrailing) {
                        if badge != nil {
                            Circle()
                                .fill(p.danger)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(p.sidebar, lineWidth: 1.5))
                                .offset(x: 3, y: -2)
                                .transition(.scale(scale: 0.2).combined(with: .opacity))
                        }
                    }
                    .animation(Motion.standard, value: badge != nil)
                Text(title).font(FN.font(13))
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(FN.small).foregroundStyle(p.textMuted)
                }
            }
            .foregroundStyle(hovering ? p.foreground : p.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(hovering ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
        .help(badge ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? "")
    }
}

/// Half of the capture row: the kit's secondary button, at regular weight.
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
            HStack(spacing: 7) {
                Icon(icon, size: 15)
                Text(title).font(FN.font(13)).lineLimit(1)
            }
            .foregroundStyle(tone ?? p.foreground)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(hovering ? p.surfaceMuted : p.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
            .contentShape(Capsule())
            .motion(hovering, Motion.quick)
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
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
            Icon("warning", size: 14).foregroundStyle(p.warning)
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
                .background(p.dangerSubtle, in: Capsule())
                .disabled(working)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(p.warningSubtle, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
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

/// Where the data lives, as the web sidebar's last line: "Saved on this Mac", or the
/// sync state, green once synced, red on an error. Opens Settings at Sync.
private struct SyncStatusRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigation
    /// Nil when this build has no sync.
    var sync: GoogleSync?

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(p.borderSubtle).frame(height: 1)
            if let sync {
                SyncLine(sync: sync)
            } else {
                HStack(spacing: 8) {
                    Icon("cloud", size: 15)
                    Text("On this Mac").lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(FN.small)
                .foregroundStyle(p.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
        }
    }
}

private struct SyncLine: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var nav: Navigation
    @ObservedObject var sync: GoogleSync
    @State private var hovering = false

    private var label: String {
        guard sync.account != nil else { return "On this Mac" }
        switch sync.status {
        case .syncing: return "Syncing… · Google Drive"
        case .offline: return "Offline · Google Drive"
        case .error: return "Sync error · Google Drive"
        case .synced: return "Synced · Google Drive"
        case .idle: return sync.lastSynced == nil ? "Not synced yet · Google Drive" : "Synced · Google Drive"
        }
    }

    private var tone: Color {
        guard sync.account != nil else { return p.textMuted }
        switch sync.status {
        case .error: return p.danger
        case .synced: return p.success
        case .idle: return sync.lastSynced == nil ? p.textMuted : p.success
        case .syncing, .offline: return p.textMuted
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
                Icon("cloud", size: 15)
                    .foregroundStyle(tone)
                    .opacity(sync.status == .syncing ? 0.6 : 1)
                    .motion(sync.status, Motion.quick)
                Text(label).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(hovering ? p.foreground : p.textMuted)
                Spacer(minLength: 0)
                if sync.account == nil {
                    Text("Turn on sync")
                        .font(FN.font(12, .medium))
                        .foregroundStyle(p.foreground)
                        .underline(hovering)
                }
            }
            .font(FN.small)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(sync.account == nil ? "Saved on this Mac. Turn on sync" : label)
    }
}
