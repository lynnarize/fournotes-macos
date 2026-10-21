import AppKit
import SwiftUI

// Settings, after Arc, as on the web (src/components/SettingsModal.tsx): a big dialog
// with the sections listed on the left (the version below them) and the chosen
// section on the right. Budgets and categories live in Finance settings.

private let KOFI_URL = "https://ko-fi.com/lynnarize"

private let PRIVACY_POINTS: [(icon: String, title: String, text: String)] = [
    ("shield", "Saved on this Mac",
     "Everything you add is stored in a file on this Mac. There's no Four Notes account or server. If you turn on Sync, a copy is kept in a private app folder in your own Google Drive."),
    ("sparkle", "Shared with AI only when you ask",
     "Apple Intelligence and models in LM Studio or Ollama answer on this Mac. A cloud model you add gets only what a request needs, straight from this Mac. The results are saved here."),
    ("cloud", "Little else goes online",
     "Exchange rates are looked up by currency code, GitHub is asked once a day for a newer release (you can turn that off), and Sync, when you turn it on, talks only to Google Drive. That's all."),
    ("key", "Your API keys stay private",
     "Keys are kept in this Mac's Keychain only. They are never included in backups."),
]

struct SettingsView: View {
    @ObservedObject private var dock = EdgeDock.shared
    @ObservedObject private var stickies = EdgeStickies.shared
    @ObservedObject private var updates = UpdateCheck.shared
    @ObservedObject private var sync = AppModel.shared.sync
    @ObservedObject private var speech = SpeechModels.shared
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeModal) private var closeModal
    @Environment(\.modalMaxHeight) private var windowLimit
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var engine: AIEngine

    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @AppStorage(BriefStyle.storageKey) private var briefStyleRaw = BriefStyle.paragraph.rawValue
    @AppStorage(AccentChoice.storageKey) private var accentRaw = AccentChoice.neutral.rawValue

    /// The section showing, remembered between visits.
    @AppStorage("fournotes.settings.section") private var current = "appearance"
    @State private var confirmWipe = false
    @State private var wipeConfirmation = ""
    /// Which of "On this Mac" / "In the cloud" / "Speech models" is unfolded.
    @State private var openGroup: String?
    /// Bumped by "Forget all keys" so the provider editors reload.
    @State private var keysGeneration = 0
    /// The Privacy Policy or Terms, open over Settings.
    @State private var legalDocument: LegalDocument?
    @State private var confirmDisconnect = false
    @State private var deleteDriveCopy = false

    private var settings: AppSettings { store.settings }

    private struct Section: Identifiable {
        let id: String
        let icon: String
        let title: String
        let summary: String
    }

    private var sections: [Section] {
        var out = [
            Section(id: "appearance", icon: "moon", title: "Appearance",
                    summary: (ThemeChoice(rawValue: themeRaw) ?? .system).label
                        + " · " + (AccentChoice(rawValue: accentRaw) ?? .neutral).label),
            Section(id: "today", icon: "today", title: "Today",
                    summary: (BriefStyle(rawValue: briefStyleRaw) ?? .paragraph).label),
            Section(id: "dock", icon: "collapseLeft", title: "Edge Dock", summary: dockSummary),
            Section(id: "general", icon: "settings", title: "General",
                    summary: settings.currency + (settings.name.map { " · \($0)" } ?? "")),
        ]
        if sync.isAvailable { out.append(Section(id: "sync", icon: "cloud", title: "Sync", summary: syncSummary)) }
        out += [
            Section(id: "api", icon: "key", title: "AI & API keys", summary: apiSummary),
            Section(id: "privacy", icon: "shield", title: "Data & privacy", summary: dataSummary),
            Section(id: "about", icon: "info", title: "About", summary: aboutSummary),
        ]
        return out
    }

    var body: some View {
        let sections = sections
        let shown = sections.first { $0.id == current } ?? sections[0]
        HStack(spacing: 0) {
            // The sections, as the kit's nav rows.
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(FN.display(28))
                    .tracking(FN.displayTracking(28))
                    .foregroundStyle(p.foreground)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                ForEach(sections) { section in
                    SettingsNavRow(icon: section.icon, title: section.title, selected: section.id == shown.id,
                                   badge: section.id == "about" && updates.available != nil) {
                        withAnimation(Motion.standard) { current = section.id }
                    }
                }
                Spacer(minLength: 12)
                Text("Version \(AppVersion.short)")
                    .font(FN.small)
                    .foregroundStyle(p.textMuted)
                    .padding(.horizontal, 12)
            }
            .padding(12)
            .frame(width: 232, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(p.sidebar)

            Rectangle().fill(p.border).frame(width: 1)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(shown.title).font(FN.font(16, .medium)).foregroundStyle(p.foreground)
                        if !shown.summary.isEmpty {
                            Text(shown.summary).font(FN.small).foregroundStyle(p.textMuted).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton("x", size: 17, box: 32, help: "Close") {
                        if let closeModal { closeModal() } else { dismiss() }
                    }
                }
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .frame(height: 64)
                Rectangle().fill(p.borderSubtle).frame(height: 1)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        content(for: shown.id)
                        if shown.id == "about" { kofi }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(shown.id)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.surface)
        }
        .frame(width: 860)
        .frame(height: min(700, windowLimit ?? 700))
        .sheet(item: $legalDocument) { LegalSheet(document: $0) }
        .onAppear {
            updates.markSeen()
            if let requested = nav.settingsSection {
                current = requested
                nav.settingsSection = nil
            }
        }
    }

    @ViewBuilder
    private func content(for id: String) -> some View {
        switch id {
        case "today": todayBrief
        case "dock": edgeDock
        case "general": general
        case "sync": syncSection
        case "api": apiKeys
        case "privacy": privacy
        case "about": about
        default: appearance
        }
    }

    // MARK: - Appearance

    /// Each look drawn as a tiny window in its own colours, as in setup; then the
    /// accent, spent on what's selected or active.
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionTitle("Theme")
            themes
                .padding(.top, -14)
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Accent")
                accents
                Text("Neutral keeps the app in ink. A colour marks what's selected, the primary button and progress.")
                    .font(FN.small)
                    .foregroundStyle(p.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accents: some View {
        HStack(spacing: 10) {
            ForEach(AccentChoice.allCases, id: \.self) { choice in
                let selected = accentRaw == choice.rawValue
                Button { withAnimation(Motion.standard) { accentRaw = choice.rawValue } } label: {
                    Circle()
                        .fill(choice == .neutral ? p.foreground : choice.swatch)
                        .frame(width: 26, height: 26)
                        .overlay {
                            if selected { Icon("check", size: 13, weight: 2.4).foregroundStyle(.white) }
                        }
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? p.borderStrong : .clear, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.fn)
                .help(choice.label)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var themes: some View {
        HStack(spacing: 12) {
            ForEach(ThemeChoice.allCases, id: \.self) { choice in
                let selected = themeRaw == choice.rawValue
                Button { withAnimation(Motion.standard) { themeRaw = choice.rawValue } } label: {
                    VStack(spacing: 8) {
                        ThemePreview(choice: choice)
                            .frame(height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selected ? p.accent : p.border, lineWidth: selected ? 2 : 1))
                        HStack(spacing: 5) {
                            Icon(choice.icon, size: 12)
                            Text(choice.label)
                        }
                        .font(FN.font(12.5, selected ? .medium : .regular))
                        .foregroundStyle(selected ? p.foreground : p.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
                .animation(Motion.standard, value: selected)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Today

    private var todayBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How the daily brief reads").font(FN.small).foregroundStyle(p.muted)
            HStack(spacing: 8) {
                ForEach(BriefStyle.allCases, id: \.self) { style in
                    let selected = briefStyleRaw == style.rawValue
                    Button { withAnimation(Motion.standard) { briefStyleRaw = style.rawValue } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Icon(style.icon, size: 15)
                                Text(style.label).font(FN.bodyMedium)
                                if style == .paragraph {
                                    Text("Compact").font(FN.font(10.5, .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(p.accent.opacity(0.14), in: Capsule())
                                }
                            }
                            .foregroundStyle(selected ? p.accent : p.text)
                            Text(style.detail)
                                .font(FN.small).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .background(selected ? p.accent.opacity(0.1) : p.bg,
                                    in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                            .stroke(selected ? p.accent : p.line, lineWidth: 1))
                        .contentShape(Rectangle())
                        .scaleEffect(selected ? 1.01 : 1)
                        .motion(selected, Motion.quick)
                    }
                    .buttonStyle(.fn)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Edge Dock

    private var dockSummary: String {
        guard dock.isEnabled else { return "Off" }
        let shown = MiniApp.allCases.count - dock.hidden.count
        return "\(dock.edge == .right ? "Right" : "Left") edge · \(shown) mini apps"
    }

    private var edgeDock: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Show the edge dock", isOn: Binding(
                    get: { dock.isEnabled },
                    set: { value in if value != dock.isEnabled { dock.setEnabled(value) } }))
                    .toggleStyle(.fnCheckbox)
                    .font(FN.body)
                Text("A handle on the edge of the screen, over any app, that opens a quick note, today's tasks, dictation and more. Click it, or press ⇧⌘. from Four Notes. Closing the window leaves it running.")
                    .font(FN.small).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }

            Group {
                labelled("Edge") {
                    SegmentedTabs(items: [("right", "Right"), ("left", "Left")],
                                  selection: Binding(get: { dock.edge == .right ? "right" : "left" },
                                                     set: { dock.setEdge($0 == "right" ? .right : .left) }))
                        .fixedSize()
                }

                if dock.screens.count > 1 {
                    labelled("Screen") {
                        SelectMenu(options: dock.screens.map { ($0.id, $0.name) },
                                   selection: Binding(get: { dock.screenId }, set: { dock.moveToScreen($0) }))
                            .fixedSize()
                    }
                }

                labelled("Mini apps") {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(MiniApp.allCases) { app in
                            Toggle(app.title, isOn: Binding(
                                get: { !dock.hidden.contains(app) },
                                set: { shown in dock.setHidden(app, !shown) }))
                                .toggleStyle(.fnCheckbox)
                                .font(FN.body)
                        }
                    }
                }

                labelled("Arrangement") {
                    HStack(spacing: 10) {
                        Text("Drag a card by its title to move it, in either column.")
                            .font(FN.small).foregroundStyle(p.muted)
                        Spacer()
                        SecondaryButton(title: "Reset layout") {
                            withAnimation(Motion.standard) { dock.resetLayout() }
                        }
                        .disabled(dock.layout == MiniApp.defaultLayout)
                        .opacity(dock.layout == MiniApp.defaultLayout ? 0.5 : 1)
                    }
                }

                HStack(spacing: 8) {
                    SecondaryButton(title: "Open the dock now", icon: "arrowUpRight") {
                        if let closeModal { closeModal() } else { dismiss() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { dock.open() }
                    }
                    Text("⇧⌘.").font(FN.small).foregroundStyle(p.faint)
                }
            }
            .disabled(!dock.isEnabled)
            .opacity(dock.isEnabled ? 1 : 0.5)

            // Stickies stay on the edge whether the dock is on or not.
            labelled("Sticky notes") {
                HStack(spacing: 10) {
                    Text(stickies.placements.isEmpty
                         ? "Stick a note to the edge from its menu, the dock's quick note, or ⌃⌘N. Point at the dock's handle and it splits off as a bubble above or below it."
                         : "\(stickies.placements.count) stuck. Point at the dock's handle and each splits off as a bubble above or below it; point at one for its title, click to open.")
                        .font(FN.small).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    SecondaryButton(title: "Take all off") { stickies.unstickAll() }
                        .disabled(stickies.placements.isEmpty)
                        .opacity(stickies.placements.isEmpty ? 0.5 : 1)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSummary: String {
        if let available = updates.available { return "Version \(available.version) is available" }
        return "Version \(AppVersion.short)"
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                versionField("Version", AppVersion.marketing)
                versionField("Build", AppVersion.build)
                if let commit = AppVersion.commit { versionField("Commit", commit) }
                Spacer()
            }
            .textSelection(.enabled)

            HStack(spacing: 8) {
                SecondaryButton(title: updates.state == .checking ? "Checking…" : "Check for updates") {
                    updates.check()
                }
                .disabled(updates.state == .checking)
                GhostButton(action: { NSWorkspace.shared.open(AppVersion.releasesPage) }) {
                    Text("Release notes")
                }
            }
            updateStatus
            Toggle("Check for updates automatically, once a day", isOn: $updates.automatic)
                .toggleStyle(.fnCheckbox)
                .font(FN.body)
        }
    }

    private func availableLine(_ version: String, _ page: URL) -> some View {
        HStack(spacing: 8) {
            Circle().fill(p.danger).frame(width: 7, height: 7)
            Text("Version \(version) is available.").font(FN.small).foregroundStyle(p.text)
            Button("Install…") { nav.present(.update) }
                .buttonStyle(.fn)
                .font(FN.font(12, .medium))
                .foregroundStyle(p.foreground)
                .underline()
        }
    }

    private func versionField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(FN.small).foregroundStyle(p.muted)
            Text(value).font(FN.bodyMedium).foregroundStyle(p.text).monospacedDigit()
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle, .checking:
            if let available = updates.available {
                availableLine(available.version, available.page)
            } else {
                Text("Asks GitHub for the latest release. Nothing else is sent.")
                    .font(FN.small).foregroundStyle(p.faint)
            }
        case .upToDate:
            Label { Text("You're on the latest version.") } icon: { Icon("check", size: 13) }
                .font(FN.small).foregroundStyle(p.muted)
        case .available(let version, let page):
            availableLine(version, page)
        case .failed(let message):
            Text(message).font(FN.small).foregroundStyle(p.danger)
        }
    }

    // MARK: - Sync

    private var syncSummary: String {
        guard sync.account != nil else { return "Off" }
        switch sync.status {
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .error: return "Needs attention"
        case .idle, .synced: return sync.account?.email ?? "Google Drive"
        }
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep this Mac and the web app in step through your own Google Drive. Four Notes keeps one file in a private app folder there: you won't see it among your files, and no one else can read it. Scans, sample data and API keys stay on this Mac.")
                .font(FN.small).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let account = sync.account {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email.map { "Connected as \($0)" } ?? "Connected to Google")
                        .font(FN.bodyMedium).foregroundStyle(p.text)
                    syncStatus
                }
                if confirmDisconnect {
                    boxed {
                        Text("Disconnect this Mac?").font(FN.bodyMedium).foregroundStyle(p.text)
                        Text("Your data stays on this Mac either way.")
                            .font(FN.small).foregroundStyle(p.muted)
                        Toggle("Also delete the copy in Google Drive", isOn: $deleteDriveCopy)
                            .toggleStyle(.fnCheckbox)
                            .font(FN.body)
                        HStack(spacing: 8) {
                            PrimaryButton(title: "Disconnect", tone: deleteDriveCopy ? p.danger : nil) {
                                let deleteCopy = deleteDriveCopy
                                confirmDisconnect = false
                                deleteDriveCopy = false
                                Task { await sync.disconnect(deleteCopy: deleteCopy) }
                            }
                            GhostButton(action: { confirmDisconnect = false; deleteDriveCopy = false }) {
                                Text("Cancel")
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -8)))
                } else {
                    HStack(spacing: 8) {
                        SecondaryButton(title: sync.status == .syncing ? "Syncing…" : "Sync now") { sync.syncNow() }
                            .disabled(sync.status == .syncing)
                        GhostButton(action: { confirmDisconnect = true }) { Text("Disconnect") }
                    }
                }
            } else {
                if let message = sync.message {
                    Text(message).font(FN.small).foregroundStyle(p.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PrimaryButton(title: sync.connecting ? "Waiting for Google…" : "Connect Google",
                              disabled: sync.connecting) {
                    Task { await sync.connect() }
                }
            }
        }
        .animation(Motion.standard, value: confirmDisconnect)
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch sync.status {
        case .syncing:
            Text("Syncing…").font(FN.small).foregroundStyle(p.muted)
        case .offline:
            Text("Offline. Sync will resume when this Mac is back online.").font(FN.small).foregroundStyle(p.muted)
        case .error:
            Text(sync.message ?? "Sync failed.").font(FN.small).foregroundStyle(p.danger)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .synced:
            if let last = sync.lastSynced {
                Text("Last synced \(last.formatted(.relative(presentation: .named)))")
                    .font(FN.small).foregroundStyle(p.muted)
            } else {
                Text("Not synced yet.").font(FN.small).foregroundStyle(p.muted)
            }
        }
    }

    // MARK: - General

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            labelled("Your name (used in the daily brief)") {
                CommittedField(placeholder: "Name", value: settings.name ?? "") { value in
                    let clean = value.trimmingCharacters(in: .whitespaces)
                    store.updateSettings { $0.name = clean.isEmpty ? nil : clean }
                }
            }

            labelled("Base currency") {
                SelectMenu(options: currencyOptions.map { ($0, $0) },
                           selection: Binding(get: { settings.currency }, set: { changeCurrency($0) }),
                           width: 110)
            }

            Toggle("Speak replies aloud in voice mode", isOn: Binding(
                get: { settings.voiceReplies },
                set: { value in store.updateSettings { $0.voiceReplies = value } }))
                .toggleStyle(.fnCheckbox)
                .font(FN.body)

            SecondaryButton(title: "Run first-time setup again") {
                // Dismiss and present in one turn and the second sheet never
                // appears, so the wizard is handed to the next runloop turn.
                nav.present(.onboarding)
            }
        }
    }

    private var currencyOptions: [String] {
        var seen = Set<String>()
        return ([settings.currency] + CURRENCIES).filter { seen.insert($0).inserted }
    }

    private func changeCurrency(_ currency: String) {
        guard currency != settings.currency else { return }
        store.updateSettings { $0.currency = currency }
        // Stored rates were relative to the old base currency; refetch them.
        for t in store.all.transactions where t.fxRate != nil {
            store.updateTransaction(t.id) { $0.fxRate = nil }
        }
        toasts.push("Base currency is now \(currency). Budgets stay as numbers; adjust them if needed.")
    }

    // MARK: - API keys and providers

    private var apiSummary: String { engine.route.label }

    /// The status and the priority stay in view; the two sets of models
    /// fold away behind a row that says what each is set to.
    private var apiKeys: some View {
        VStack(alignment: .leading, spacing: 14) {
            routing
            Divider().overlay(p.line)
            prioritySection
            VStack(spacing: 8) {
                modelGroup("local", icon: "monitor", title: "On this Mac", summary: engine.localSummary) {
                    Text("Private and free. A model server, when set up, is asked before Apple Intelligence.")
                        .font(FN.small).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    ProviderSlotEditor(slot: .local).id(keysGeneration)
                }
                modelGroup("cloud", icon: "cloud", title: "In the cloud", summary: engine.cloudSummary) {
                    Text("Your own keys. They stay in your Keychain and go only to the provider, with each request.")
                        .font(FN.small).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    CloudProviderTabs { anthropicKey }.id(keysGeneration)
                    Divider().overlay(p.line)
                    forgetKeys
                }
                modelGroup("speech", icon: "mic", title: "Speech models", summary: speech.summary) {
                    SpeechModelsSettings()
                }
            }
        }
    }

    /// A folded group of settings inside a section: a row with a summary,
    /// and the settings under it when opened.
    private func modelGroup<Content: View>(_ id: String, icon: String, title: String, summary: String,
                                           @ViewBuilder _ content: () -> Content) -> some View {
        let isOpen = openGroup == id
        return VStack(alignment: .leading, spacing: 0) {
            Button { openGroup = isOpen ? nil : id } label: {
                HStack(spacing: 10) {
                    Icon(icon, size: 15).foregroundStyle(p.accent)
                    Text(title).font(FN.bodyMedium).foregroundStyle(p.text)
                    Spacer(minLength: 12)
                    Text(summary).font(FN.small).foregroundStyle(p.faint).lineLimit(1)
                    Icon("chevronDown", size: 13)
                        .foregroundStyle(p.faint)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .accessibilityLabel(title)
            .accessibilityValue(summary)
            .accessibilityHint(isOpen ? "Hide these settings" : "Show these settings")

            if isOpen {
                Divider().overlay(p.line)
                VStack(alignment: .leading, spacing: 12) { content() }
                    .padding(12)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(Motion.standard, value: isOpen)
        .background(p.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.line, lineWidth: 1))
    }

    /// Which kind of model is asked first.
    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask first").font(FN.bodyMedium).foregroundStyle(p.text)
            SegmentedTabs(items: AIEngine.Priority.allCases.map { ($0.rawValue, $0.label) },
                          selection: Binding(get: { engine.priority.rawValue },
                                             set: { engine.priority = AIEngine.Priority(rawValue: $0) ?? .localFirst }))
                .fixedSize()
            Text(engine.priority == .localFirst
                 ? "Stays on this Mac. The cloud is used only when you tap “Ask …” under a reply."
                 : "The cloud answers; this Mac steps in when it can't be reached.")
                .font(FN.small).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What answers each kind of request right now.
    private var routing: some View {
        let r = engine.readiness
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("How requests are answered").font(FN.bodyMedium).foregroundStyle(p.text)
                Spacer()
                StatusPill(text: r.route.label,
                           tone: r.route == .unavailable ? .warn : .good)
            }
            VStack(alignment: .leading, spacing: 5) {
                routeLine("sparkle", "Chat", r.chat)
                routeLine("scan", "Scanning", r.scanning)
                routeLine("mic", "Voice notes", r.voice)
                routeLine("chart", "Brief & review", r.summaries)
            }
            Text("Photos and recordings are always read on this Mac.")
                .font(FN.small).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func routeLine(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(icon, size: 13).foregroundStyle(p.faint).padding(.top, 2)
            Text(label).font(FN.small).foregroundStyle(p.muted).frame(width: 92, alignment: .leading)
            Text(value).font(FN.small).foregroundStyle(p.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var anthropicKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude").font(FN.bodyMedium).foregroundStyle(p.text)
            Text("Paid, and the most accurate. Needed for “Ideas from the web”.")
                .font(FN.small).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)

            KeyField(item: .anthropicKey) { engine.refresh() }

            HStack(spacing: 12) {
                labelled("Model") {
                    SelectMenu(options: AnthropicClient.userModels.map { ($0.id, $0.label) },
                               selection: keychainBinding(.anthropicModel, default: AnthropicClient.defaultModel))
                        .fixedSize()
                }
                labelled("Brief & review") {
                    SelectMenu(options: AnthropicClient.userModels.map { ($0.id, $0.label) },
                               selection: keychainBinding(.anthropicFastModel, default: AnthropicClient.defaultFastModel))
                        .fixedSize()
                }
            }

            Button("Get a key at console.anthropic.com") {
                if let url = URL(string: "https://console.anthropic.com/settings/keys") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.fn)
            .font(FN.small)
            .foregroundStyle(p.accent)
        }
    }

    private func keychainBinding(_ item: Keychain.Item, default fallback: String) -> Binding<String> {
        Binding(
            get: { Keychain.read(item).flatMap { $0.isEmpty ? nil : $0 } ?? fallback },
            set: { Keychain.write(item, $0) })
    }

    private var forgetKeys: some View {
        GhostButton(tone: p.danger, action: {
            Keychain.clearAll()
            keysGeneration += 1
            engine.refresh()
            toasts.push("Keys and model settings removed from the Keychain.")
        }) {
            Text("Forget all keys")
        }
    }

    // MARK: - Data & privacy

    private var counts: (notes: Int, tasks: Int, transactions: Int) {
        (store.all.notes.filter { $0.deletedAt == nil }.count,
         store.all.todos.filter { $0.deletedAt == nil }.count,
         store.all.transactions.filter { $0.deletedAt == nil }.count)
    }

    private var dataSummary: String {
        let c = counts
        return "\(plural(c.notes, "note")) · \(plural(c.tasks, "task")) · \(plural(c.transactions, "transaction"))"
    }

    private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private var privacy: some View {
        let c = counts
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                statTile("Notes", c.notes)
                statTile("Tasks", c.tasks)
                statTile("Transactions", c.transactions)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(PRIVACY_POINTS, id: \.title) { point in
                    HStack(alignment: .top, spacing: 10) {
                        Icon(point.icon, size: 16).foregroundStyle(p.muted).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(FN.bodyMedium).foregroundStyle(p.text)
                            Text(point.text)
                                .font(FN.small).foregroundStyle(p.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            legalLinks

            boxed {
                Text("Sample data").font(FN.bodyMedium).foregroundStyle(p.text)
                Text("A few example notes, tasks and transactions to try things out. They stay on this Mac and can be removed in one click.")
                    .font(FN.small).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecondaryButton(title: "Load sample data") { store.loadSamples() }
                    if store.hasSamples {
                        SecondaryButton(title: "Remove sample data") { store.clearSamples() }
                    }
                }
            }

            boxed {
                Text("Backup").font(FN.bodyMedium).foregroundStyle(p.text)
                Text("Save everything to a file, or restore from one. When importing, the newer version of each item is kept. The file is the same format as the web app's export.")
                    .font(FN.small).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecondaryButton(title: "Export backup", icon: "download", action: exportBackup)
                    SecondaryButton(title: "Import backup", action: importBackup)
                    SecondaryButton(title: "Show data file") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.shared.location])
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Danger zone").font(FN.bodyMedium).foregroundStyle(p.danger)
                Text("Erase all notes, tasks, spending, settings and saved API keys from this Mac. This can't be undone.")
                    .font(FN.small).foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if confirmWipe {
                    Text("Type **delete** to confirm.").font(FN.small).foregroundStyle(p.muted)
                    HStack(spacing: 8) {
                        BoxedField(placeholder: "delete", text: $wipeConfirmation)
                        PrimaryButton(title: "Delete everything", tone: p.danger,
                                      disabled: wipeConfirmation.lowercased() != "delete") {
                            store.eraseEverything()
                            Keychain.clearAll()
                            confirmWipe = false
                            wipeConfirmation = ""
                            toasts.push("All local data deleted.")
                        }
                        GhostButton(action: { confirmWipe = false; wipeConfirmation = "" }) {
                            Text("Cancel")
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: -8)))
                } else {
                    SecondaryButton(title: "Delete all local data") { confirmWipe = true }
                }
            }
            .animation(Motion.standard, value: confirmWipe)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                .stroke(p.danger.opacity(0.45), lineWidth: 1))
        }
    }

    /// The full Privacy Policy and Terms, opened over Settings.
    private var legalLinks: some View {
        HStack(spacing: 4) {
            Text("Full details:").foregroundStyle(p.muted)
            ForEach(Array(LegalDocument.allCases.enumerated()), id: \.element.id) { index, document in
                if index > 0 { Text("·").foregroundStyle(p.faint) }
                Button(document.title) { legalDocument = document }
                    .buttonStyle(.fn)
                    .foregroundStyle(p.accent)
                    .underline()
            }
            Text("· Questions?").foregroundStyle(p.muted)
            Button(LegalDocument.contact) {
                if let url = URL(string: "mailto:\(LegalDocument.contact)") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.fn)
            .foregroundStyle(p.accent)
        }
        .font(FN.small)
    }

    private func statTile(_ label: String, _ n: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(p.text)
            Text(label).font(FN.small).foregroundStyle(p.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(p.hover, in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
        .motion(n, Motion.data)
    }

    @ViewBuilder
    private func boxed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                .stroke(p.line, lineWidth: 1))
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(FN.small).foregroundStyle(p.muted)
            content()
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "four-notes-backup-\(DateKit.localDate()).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            store.flush()
            // Inline the images so the backup is self-contained and the web
            // app can read it.
            try Persistence.shared.encode(Attachments.inliningImages(store.all)).write(to: url)
            toasts.push("Saved \(url.lastPathComponent)")
        } catch {
            toasts.push("Could not export: \(error.localizedDescription)", tone: .error)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            var incoming = try Persistence.shared.decode(data)
            Attachments.extractInlineImages(&incoming)
            store.resumeSaving()
            store.mergeRemote(\.notes, incoming.notes)
            store.mergeRemote(\.todos, incoming.todos)
            store.mergeRemote(\.transactions, incoming.transactions)
            store.mergeRemote(\.stickies, incoming.stickies, reversed: true)
            store.mergeSettings(incoming.settings)
            Attachments.removeOrphans(keeping: store.all)
            toasts.push("Backup imported. The newer version of each item was kept.")
        } catch {
            toasts.push("That file isn't a Four Notes backup.", tone: .error)
        }
    }

    // MARK: - Support

    private var kofi: some View {
        HStack(spacing: 12) {
            Icon("coffee", size: 20)
                .foregroundStyle(Color.hex(0xFF5E5B))
                .frame(width: 40, height: 40)
                .background(Color.hex(0xFF5E5B).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Enjoying Four Notes?").font(FN.bodyMedium).foregroundStyle(p.text)
                Text("Four Notes is free. If it helps you, a coffee keeps it going.")
                    .font(FN.small).foregroundStyle(p.muted)
            }
            Spacer()
            Button {
                if let url = URL(string: KOFI_URL) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) {
                    Icon("coffee", size: 16)
                    Text("Buy me a coffee").font(FN.bodyMedium)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.hex(0xFF5E5B), in: Capsule())
            }
            .buttonStyle(.fn)
        }
        .padding(14)
        .background(p.surfaceMuted, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
    }
}

/// One Keychain-backed key field, masked until it is being edited.
struct KeyField: View {
    @Environment(\.palette) private var p
    let item: Keychain.Item
    var onChange: () -> Void = {}
    @State private var value = ""
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.label).font(FN.small).foregroundStyle(p.muted)
            HStack(spacing: 8) {
                if editing {
                    SecureField("Paste your key", text: $value)
                        .textFieldStyle(.plain)
                        .font(FN.body)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                            .stroke(p.line, lineWidth: 1))
                        .onSubmit(commit)
                    SecondaryButton(title: "Save", action: commit)
                } else {
                    Text(stored.isEmpty ? "Not set" : Keychain.mask(stored))
                        .font(FN.body)
                        .foregroundStyle(stored.isEmpty ? p.faint : p.text)
                    Spacer()
                    GhostButton(action: { editing = true; value = "" }) {
                        Text(stored.isEmpty ? "Add" : "Replace")
                    }
                    if !stored.isEmpty {
                        GhostButton(tone: p.danger, action: {
                            Keychain.write(item, nil)
                            refresh()
                            onChange()
                        }) {
                            Text("Remove")
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
    }

    @State private var stored = ""

    private func refresh() { stored = Keychain.read(item) ?? "" }

    private func commit() {
        Keychain.write(item, value)
        value = ""
        editing = false
        refresh()
        onChange()
    }
}

/// A section in the settings list: the kit's nav row.
private struct SettingsNavRow: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let icon: String
    let title: String
    let selected: Bool
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(icon, size: 16)
                    .foregroundStyle(selected ? p.accent : (hovering ? p.foreground : p.textSecondary))
                Text(title)
                    .font(FN.font(13, selected ? .medium : .regular))
                    .foregroundStyle(selected || hovering ? p.foreground : p.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if badge { Circle().fill(p.danger).frame(width: 7, height: 7) }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? p.accentSubtle : (hovering ? p.hover : .clear),
                        in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
        .motion(selected, Motion.quick)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
