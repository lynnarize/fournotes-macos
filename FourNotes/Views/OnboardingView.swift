import AppKit
import SwiftUI
import UserNotifications

// First-run setup, over the whole window: a calm, paper-and-light welcome
// that shows what the app does, then asks only what it needs — how it should
// look, the assistant, the currency — and ends on a small celebration.
// Skippable at every step. Each step blurs into the next.

struct OnboardingView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var engine: AIEngine
    @EnvironmentObject private var nav: Navigation
    @ObservedObject private var dock = EdgeDock.shared

    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @AppStorage(BriefStyle.storageKey) private var briefStyleRaw = BriefStyle.paragraph.rawValue

    @State private var step = 0
    /// Which way the last move went, so the steps slide the right way.
    @State private var forward = true
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var remindersOn = false

    /// The steps, in order; each has a dash in the progress bar. The
    /// celebration comes after the last.
    private enum Page: Int, CaseIterable {
        case welcome, oneView, brief, nothingSlips, edgeDock, look, assistant, money
    }
    private static let stepCount = Page.allCases.count
    private var page: Page? { Page(rawValue: step) }

    private var theme: ThemeChoice { ThemeChoice(rawValue: themeRaw) ?? .system }
    private var s: OnboardingStyle { OnboardingStyle(scheme: scheme, theme: theme) }
    private var celebrating: Bool { step == Self.stepCount }

    var body: some View {
        ZStack {
            OnboardingBackground(style: s, glow: celebrating ? 1 : 0.55 + Double(step) * 0.04)

            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .modifier(active: BlurStep(amount: 1, shift: forward ? 18 : -18),
                                             identity: BlurStep(amount: 0, shift: 0)),
                        removal: .modifier(active: BlurStep(amount: 1, shift: forward ? -18 : 18),
                                           identity: BlurStep(amount: 0, shift: 0))))
            }
            .frame(maxWidth: 900, maxHeight: .infinity)
            .padding(.horizontal, 56)
            .padding(.top, 48)
            .padding(.bottom, 84)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .environment(\.onboarding, s)
        .animation(Motion.reduce ? Motion.instant : .spring(response: 0.55, dampingFraction: 0.9), value: step)
        .task { await refreshReminders() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            if step > 0 && !celebrating {
                Button(page == .assistant ? "Not now" : "Skip") { page == .assistant ? go(1) : finish() }
                    .buttonStyle(.fn)
                    .font(FN.font(12.5, .medium))
                    .foregroundStyle(s.muted)
                    .help(page == .assistant ? "Set up the assistant later in Settings" : "Skip setup")
            }
        }
        .frame(height: 20)
    }

    private var bottomBar: some View {
        ZStack {
            if !celebrating {
                ProgressDashes(count: Self.stepCount, current: step)
            }
            HStack {
                if celebrating {
                    remindersButton
                } else if step > 0 {
                    Button { go(-1) } label: {
                        HStack(spacing: 5) {
                            Icon("chevronLeft", size: 12, weight: 2)
                            Text("Back")
                        }
                        .font(FN.font(13, .medium))
                        .foregroundStyle(s.muted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.fn)
                    // ⌘[ as in a browser: ⌘← belongs to text fields (line start).
                    .keyboardShortcut("[", modifiers: .command)
                }
                Spacer()
                OnboardingPrimary(title: primaryTitle, action: primary)
            }
        }
        .frame(height: 36)
    }

    private var primaryTitle: String {
        switch page {
        case .welcome: return "Get started"
        case .look: return "Looks good"
        case .assistant: return keyDraft.isEmpty ? "Continue" : "Save and continue"
        case .money: return "I'm ready"
        case nil: return "Open Four Notes"
        default: return "Continue"
        }
    }

    private func primary() {
        if page == .assistant, !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
            Keychain.write(.anthropicKey, keyDraft.trimmingCharacters(in: .whitespaces))
            engine.refresh()
            keySaved = true
        }
        if celebrating { finish() } else { go(1) }
    }

    private func go(_ delta: Int) {
        forward = delta > 0
        step = min(Self.stepCount, max(0, step + delta))
    }

    private func finish() {
        // Persist completion even when setup was skipped without changing any
        // setting; otherwise the empty install is treated as a new install on
        // every launch and the wizard reopens.
        store.flush()
        store.needsOnboarding = false
        withAnimation(Motion.screen) { nav.sheet = nil }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: welcome
        case .oneView: oneView
        case .brief: briefPage
        case .nothingSlips: nothingSlips
        case .edgeDock: edgeDockPage
        case .look: look
        case .assistant: assistant
        case .money: money
        case nil: celebration
        }
    }

    private var welcome: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                SerifTitle("Four notebooks.\nOne calm place.", size: 40)
                Text("Notes, to-dos, spending and an assistant that files things for you — together in one fast Mac app.")
                    .font(FN.font(15)).foregroundStyle(s.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WelcomeCards()
                .frame(width: 360, height: 330)
        }
    }

    private var oneView: some View {
        VStack(spacing: 10) {
            SerifTitle("Your day, on one calm page", size: 34, centered: true)
            Text("What's due, what you spent and what you jotted down — sorted by what needs you now.")
                .font(FN.font(14.5)).foregroundStyle(s.muted).multilineTextAlignment(.center)
            TodayMock()
                .frame(width: 560, height: 280)
                .padding(.top, 22)
        }
    }

    private var briefPage: some View {
        VStack(spacing: 10) {
            SerifTitle("How should your day read?", size: 34, centered: true)
            Text("A few sentences with the details a click away, or everything point by point. Change it any time in Settings.")
                .font(FN.font(14.5)).foregroundStyle(s.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 540)
            HStack(alignment: .top, spacing: 40) {
                ForEach(Array(BriefStyle.allCases.enumerated()), id: \.element) { index, style in
                    BriefStyleTile(style: style, selected: briefStyleRaw == style.rawValue) {
                        withAnimation(Motion.standard) { briefStyleRaw = style.rawValue }
                    }
                    .arrive(0.08 + Double(index) * 0.1)
                }
            }
            .padding(.top, 26)
        }
    }

    private var nothingSlips: some View {
        HStack(alignment: .center, spacing: 48) {
            RemindMock()
                .frame(width: 380, height: 250)
            VStack(alignment: .leading, spacing: 14) {
                SerifTitle("Nothing slips\nthrough", size: 38)
                Text("Say “remind me to pay rent Friday” and Four Notes reminds you on Friday. A receipt photo becomes spending; a voice memo becomes a note with its to-dos.")
                    .font(FN.font(14.5)).foregroundStyle(s.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var edgeDockPage: some View {
        HStack(alignment: .center, spacing: 44) {
            VStack(alignment: .leading, spacing: 14) {
                SerifTitle("Always at the\nedge of your screen", size: 38)
                Text("A small handle waits on the side of whatever you're working in. Click it for a quick note, today's tasks, dictation, a spend or a question — then get back to what you were doing.")
                    .font(FN.font(14.5)).foregroundStyle(s.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 330, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Keycap("⇧"); Keycap("⌘"); Keycap(".")
                        Text("opens it from Four Notes").font(FN.font(12.5)).foregroundStyle(s.muted)
                    }
                    Text("Drag the handle up or down, or drag a card's title to rearrange the drawer.")
                        .font(FN.font(12.5)).foregroundStyle(s.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 330, alignment: .leading)
                }
                .padding(.top, 4)

                Toggle(isOn: Binding(get: { dock.isEnabled }, set: { if $0 != dock.isEnabled { dock.setEnabled($0) } })) {
                    Text("Show the edge dock").font(FN.font(13, .medium)).foregroundStyle(s.ink)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            EdgeDockDemo(style: DockStyle.style(for: theme, scheme: scheme))
                .frame(width: 440, height: 300)
        }
    }

    private var look: some View {
        VStack(spacing: 10) {
            SerifTitle("Make it yours", size: 34, centered: true)
            Text("Follow the system, or pick a look and keep it. Change it any time in Settings.")
                .font(FN.font(14.5)).foregroundStyle(s.muted).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(ThemeChoice.allCases, id: \.self) { choice in
                    ThemeTile(choice: choice, selected: theme == choice, systemScheme: scheme) {
                        withAnimation(Motion.standard) { themeRaw = choice.rawValue }
                    }
                }
            }
            .padding(.top, 24)

        }
    }

    private var assistant: some View {
        VStack(spacing: 10) {
            SerifTitle("Meet your assistant", size: 34, centered: true)
            Text(OnDevice.languageModelAvailable
                 ? "It already works on this Mac with Apple Intelligence — offline and free. A key makes it sharper."
                 : "Scanning and voice notes already work on this Mac. Chat needs a model: add a key, or set one up later.")
                .font(FN.font(14.5)).foregroundStyle(s.muted).multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            VStack(spacing: 10) {
                if OnDevice.languageModelAvailable {
                    HStack(spacing: 8) {
                        Icon("check", size: 13, weight: 2.4).foregroundStyle(s.ok)
                        Text("Apple Intelligence is ready on this Mac").font(FN.font(13, .medium)).foregroundStyle(s.ink)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(s.ok.opacity(0.1), in: Capsule())
                }
                SecureField("", text: $keyDraft, prompt: Text("Anthropic key (optional) — sk-ant-…").foregroundStyle(s.faint))
                    .textFieldStyle(.plain)
                    .font(FN.font(13.5))
                    .foregroundStyle(s.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(s.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(s.fieldEdge, lineWidth: 1))
                    .onSubmit(primary)
                HStack(spacing: 4) {
                    Text("Prefer OpenRouter, OpenAI or a model on this Mac?").foregroundStyle(s.muted)
                    Text("Settings → AI & API keys").fontWeight(.semibold).foregroundStyle(s.ink)
                }
                .font(FN.font(12))
                Button("Get an Anthropic key") {
                    if let url = URL(string: "https://console.anthropic.com/settings/keys") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.fn)
                .font(FN.font(12, .semibold))
                .foregroundStyle(s.accent)
            }
            .frame(width: 340)
            .padding(.top, 20)

            HStack(spacing: 22) {
                TrustBadge(icon: "key", text: "Keys stay in your Keychain")
                TrustBadge(icon: "monitor", text: "On this Mac when it can be")
                TrustBadge(icon: "trash", text: "Delete any time")
            }
            .padding(.top, 26)
        }
    }

    private var money: some View {
        HStack(alignment: .center, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                SerifTitle("Bring your\nmoney in", size: 38)
                Text("Pick the currency you count in. Budgets and categories can wait.")
                    .font(FN.font(14.5)).foregroundStyle(s.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340, alignment: .leading)

                HStack(spacing: 10) {
                    Text("Currency").font(FN.font(13)).foregroundStyle(s.muted)
                    Picker("", selection: Binding(
                        get: { store.settings.currency },
                        set: { c in store.updateSettings { $0.currency = c } })) {
                            ForEach(CURRENCIES, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                }
                .padding(.top, 6)

                HStack(spacing: 6) {
                    Text("“").font(.system(size: 18, design: .serif)).foregroundStyle(s.accent)
                    Button(store.hasSamples ? "Sample data is loaded — remove it any time in Settings"
                           : "Load a few samples to look around first") {
                        guard !store.hasSamples else { return }
                        store.loadSamples()
                        toasts.push("Sample data loaded. Remove it any time in Settings → Data & privacy.")
                    }
                    .buttonStyle(.fn)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(store.hasSamples ? s.muted : s.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            FeatureOrbit()
                .frame(width: 340, height: 320)
        }
    }

    private var celebration: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CelebrationRow()
            HStack(spacing: 8) {
                Text("“").font(.system(size: 18, design: .serif)).foregroundStyle(s.accent)
                Text("Your notebook is ready. The edge dock waits on the side of your screen — ⇧⌘. opens it.")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(s.muted)
            }
            .padding(.top, 34)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Reminders

    private var remindersButton: some View {
        Button {
            Task { await turnOnReminders() }
        } label: {
            HStack(spacing: 6) {
                Icon(remindersOn ? "check" : "bell", size: 13, weight: 2)
                Text(remindersOn ? "Reminders on" : "Turn on reminders")
            }
            .font(FN.font(13, .medium))
            .foregroundStyle(remindersOn ? s.muted : s.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .disabled(remindersOn)
        .animation(Motion.standard, value: remindersOn)
    }

    private func refreshReminders() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        remindersOn = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func turnOnReminders() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .denied {
            // Asked before and refused: only System Settings can change it now.
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refreshReminders()
    }
}

// MARK: - Style

/// Colours for the setup: warm light over white, or the same light at night.
struct OnboardingStyle {
    let base, ink, muted, faint, card, cardEdge, field, fieldEdge: Color
    let peach, sky, accent, ok: Color
    let buttonFill, buttonText: Color
    let dark: Bool

    init(scheme: ColorScheme, theme: ThemeChoice) {
        dark = scheme == .dark
        if dark {
            base = .hex(0x141416); ink = .hex(0xEDEBE7); muted = .hex(0xA8A49C); faint = .hex(0x7D7A74)
            card = .hex(0x232326); cardEdge = .white.opacity(0.08)
            field = .hex(0x1C1C1F); fieldEdge = .white.opacity(0.1)
            peach = .hex(0x5A2E26); sky = .hex(0x1F3550)
            accent = .hex(0xE08A62); ok = .hex(0x5DBB8A)
            buttonFill = .hex(0xF2F0EC); buttonText = .hex(0x141416)
        } else {
            let paper = theme == .paper
            base = paper ? .hex(0xFBF6E8) : .hex(0xFCFBFA)
            ink = .hex(0x1F1D1A); muted = .hex(0x6B675F); faint = .hex(0x8E8A82)
            card = paper ? .hex(0xFFFCF3) : .white; cardEdge = .black.opacity(0.06)
            field = paper ? .hex(0xF4EDD9) : .hex(0xF3F2F0); fieldEdge = .black.opacity(0.05)
            peach = .hex(0xF6C7B6); sky = .hex(0xC9DDF3)
            accent = .hex(0xC0643C); ok = .hex(0x2F8A5B)
            buttonFill = .hex(0x1B1B1D); buttonText = .white
        }
    }
}

private struct OnboardingStyleKey: EnvironmentKey {
    static let defaultValue = OnboardingStyle(scheme: .light, theme: .light)
}

extension EnvironmentValues {
    fileprivate var onboarding: OnboardingStyle {
        get { self[OnboardingStyleKey.self] }
        set { self[OnboardingStyleKey.self] = newValue }
    }
}

// MARK: - Pieces

/// The shared calm wash, drifting — brighter at the end.
private struct OnboardingBackground: View {
    let style: OnboardingStyle
    let glow: Double

    var body: some View {
        CalmBackground(base: style.base, warm: style.peach, cool: style.sky,
                       glow: glow, dark: style.dark, animated: true)
    }
}

/// Steps arrive out of a soft blur and leave into one.
private struct BlurStep: ViewModifier {
    let amount: Double
    let shift: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: 14 * amount)
            .opacity(1 - amount)
            .offset(x: shift * amount)
    }
}

private struct SerifTitle: View {
    @Environment(\.onboarding) private var s
    let text: String
    let size: CGFloat
    var centered = false

    init(_ text: String, size: CGFloat, centered: Bool = false) {
        self.text = text
        self.size = size
        self.centered = centered
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .serif))
            .tracking(-0.6)
            .lineSpacing(0)
            .foregroundStyle(s.ink)
            .multilineTextAlignment(centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OnboardingPrimary: View {
    @Environment(\.onboarding) private var s
    @State private var hovering = false
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Image(systemName: "return").font(.system(size: 10, weight: .semibold)).opacity(0.6)
            }
            .font(FN.font(13, .semibold))
            .foregroundStyle(s.buttonText)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(s.buttonFill.opacity(hovering ? 0.86 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: title)
    }
}

private struct ProgressDashes: View {
    @Environment(\.onboarding) private var s
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? s.accent : s.faint.opacity(index < current ? 0.55 : 0.28))
                    .frame(width: index == current ? 24 : 16, height: 3)
            }
        }
        .animation(Motion.standard, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// A white card with a soft shadow, the building block of every picture.
private struct PaperCard<Content: View>: View {
    @Environment(\.onboarding) private var s
    var radius: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(s.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(s.dark ? 0.35 : 0.07), radius: 14, y: 6)
    }
}

/// Comes in once, a beat after the one before it.
private struct Arrive: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 6)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(delay)) { shown = true }
            }
    }
}

extension View {
    fileprivate func arrive(_ delay: Double) -> some View { modifier(Arrive(delay: delay)) }
}

/// The app's mark on a rounded tile, like an app icon.
private struct MarkTile: View {
    @Environment(\.onboarding) private var s
    var size: CGFloat = 56

    var body: some View {
        Logo(size: size * 0.62)
            .frame(width: size, height: size)
            .background(s.card, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(s.dark ? 0.4 : 0.09), radius: 12, y: 5)
    }
}

private struct Glyph: View {
    let icon: String
    let tone: Color
    var size: CGFloat = 30

    var body: some View {
        Icon(icon, size: size * 0.5, weight: 1.9)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone, in: Circle())
    }
}

// MARK: - Pictures

/// Four things the app keeps, floating in a loose stack.
private struct WelcomeCards: View {
    @Environment(\.onboarding) private var s

    var body: some View {
        ZStack(alignment: .topLeading) {
            MarkTile(size: 54)
                .rotationEffect(.degrees(-6))
                .offset(x: -18, y: -14)
                .arrive(0.05)
                .zIndex(1)

            VStack(alignment: .leading, spacing: 12) {
                row(icon: "note", tone: .hex(0x7D6FF6), title: "Singapore trip",
                    detail: "Flights on the 12th, hotel near Bugis…", trailing: "Note", x: 26)
                    .arrive(0.15)
                row(icon: "todo", tone: .hex(0x3BA5F1), title: "Pay the electricity bill",
                    detail: "Tomorrow, 9:00", trailing: "Due", trailingTone: s.accent, x: 6)
                    .arrive(0.27)
                row(icon: "coffee", tone: .hex(0xF0A23B), title: "Kopi Kenangan",
                    detail: "Food & Drink", trailing: "Rp 25.000", x: 30)
                    .arrive(0.39)
                row(icon: "sparkle", tone: .hex(0x3CC6A3), title: "Receipt filed",
                    detail: "Rp 128.500 at Indomaret · Groceries", trailing: "now", x: 12)
                    .arrive(0.51)
            }
            .padding(.top, 34)
        }
    }

    private func row(icon: String, tone: Color, title: String, detail: String, trailing: String,
                     trailingTone: Color? = nil, x: CGFloat) -> some View {
        PaperCard {
            HStack(spacing: 10) {
                Glyph(icon: icon, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(FN.font(13, .semibold)).foregroundStyle(s.ink)
                    Text(detail).font(FN.font(11.5)).foregroundStyle(s.muted).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(trailing).font(FN.font(11, .medium)).foregroundStyle(trailingTone ?? s.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 300)
        }
        .offset(x: x)
    }
}

/// A small Today page: the sidebar, what's due, and the assistant's note.
private struct TodayMock: View {
    @Environment(\.onboarding) private var s

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            PaperCard(radius: 12) {
                HStack(spacing: 0) {
                    VStack(spacing: 14) {
                        Logo(size: 16).padding(.top, 12)
                        ForEach(["today", "note", "todo", "finance"], id: \.self) { icon in
                            Icon(icon, size: 13).foregroundStyle(icon == "today" ? s.accent : s.faint)
                        }
                        Spacer()
                    }
                    .frame(width: 42)
                    .background(s.field.opacity(0.7))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Today").font(FN.font(13, .semibold)).foregroundStyle(s.ink)
                            Spacer()
                            Icon("search", size: 11).foregroundStyle(s.faint)
                        }
                        section("Due today", "2")
                        line(icon: "todo", tone: .hex(0x3BA5F1), title: "Pay the electricity bill", detail: "9:00 · Bills", tag: "Due", tagTone: s.accent)
                        line(icon: "todo", tone: .hex(0x7D6FF6), title: "Send the Q3 deck to Maya", detail: "Before 5 PM", tag: "2h", tagTone: s.faint)
                        section("Spent yesterday", "")
                        line(icon: "coffee", tone: .hex(0xF0A23B), title: "Kopi Kenangan", detail: "Food & Drink", tag: "Rp 25.000", tagTone: s.muted)
                        line(icon: "cart", tone: .hex(0x3CC6A3), title: "Indomaret", detail: "Groceries", tag: "Rp 128.500", tagTone: s.muted)
                    }
                    .padding(14)
                }
                .frame(width: 440, height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .arrive(0.05)

            PaperCard {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        MarkTile(size: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Assistant").font(FN.font(12.5, .semibold)).foregroundStyle(s.ink)
                            Text("One message, three things").font(FN.font(10.5)).foregroundStyle(s.muted)
                        }
                    }
                    filed("A task for Friday")
                    filed("Rp 45.000 at Warteg")
                    filed("A note: “gift ideas”")
                }
                .padding(12)
                .frame(width: 200, alignment: .leading)
            }
            .rotationEffect(.degrees(2.5))
            .offset(x: 10, y: 14)
            .arrive(0.3)
        }
    }

    private func section(_ title: String, _ count: String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(FN.font(10.5, .semibold)).foregroundStyle(s.ink)
            Text(count).font(FN.font(10.5)).foregroundStyle(s.faint)
        }
        .padding(.top, 2)
    }

    private func line(icon: String, tone: Color, title: String, detail: String, tag: String, tagTone: Color) -> some View {
        HStack(spacing: 8) {
            Glyph(icon: icon, tone: tone, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(FN.font(11, .semibold)).foregroundStyle(s.ink)
                Text(detail).font(FN.font(10)).foregroundStyle(s.muted)
            }
            Spacer()
            Text(tag).font(FN.font(10, .medium)).foregroundStyle(tagTone)
        }
    }

    private func filed(_ text: String) -> some View {
        HStack(spacing: 6) {
            Icon("check", size: 10, weight: 2.4).foregroundStyle(s.ok)
            Text(text).font(FN.font(11.5)).foregroundStyle(s.ink)
        }
    }
}

/// "Remind me…" and the task it becomes, typed out as it happens.
private struct RemindMock: View {
    @Environment(\.onboarding) private var s
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typed = 0
    @State private var filed = false
    private let message = "Remind me to pay rent on Friday"

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    MarkTile(size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Four Notes").font(FN.font(13, .semibold)).foregroundStyle(s.ink)
                        Text("Assistant").font(FN.font(11)).foregroundStyle(s.muted)
                    }
                }
                Divider().overlay(s.cardEdge)

                HStack {
                    Spacer(minLength: 40)
                    Text(String(message.prefix(typed)) + (typed < message.count ? "▍" : ""))
                        .font(FN.font(13))
                        .foregroundStyle(s.buttonText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(s.buttonFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                if filed {
                    HStack(spacing: 10) {
                        Glyph(icon: "bell", tone: s.accent, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Pay rent").font(FN.font(13, .semibold)).foregroundStyle(s.ink)
                            Text("Friday, 9:00 · I'll remind you").font(FN.font(11.5)).foregroundStyle(s.muted)
                        }
                        Spacer()
                        Icon("check", size: 13, weight: 2.4).foregroundStyle(s.ok)
                    }
                    .padding(10)
                    .background(s.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 360, height: 220, alignment: .topLeading)
        }
        .rotationEffect(.degrees(-1.5))
        .arrive(0.05)
        .task {
            if reduceMotion { typed = message.count; filed = true; return }
            try? await Task.sleep(for: .milliseconds(450))
            for i in 1...message.count {
                typed = i
                try? await Task.sleep(for: .milliseconds(34))
            }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { filed = true }
        }
    }
}

/// Each look, drawn as a tiny window in its own colours.
private struct ThemeTile: View {
    @Environment(\.onboarding) private var s
    let choice: ThemeChoice
    let selected: Bool
    let systemScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                preview
                    .frame(width: 132, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? s.accent : s.cardEdge, lineWidth: selected ? 2 : 1))
                    .shadow(color: .black.opacity(selected ? 0.12 : 0.05), radius: selected ? 12 : 6, y: 4)
                HStack(spacing: 5) {
                    Icon(choice.icon, size: 12)
                    Text(choice.label)
                }
                .font(FN.font(12.5, selected ? .semibold : .regular))
                .foregroundStyle(selected ? s.ink : s.muted)
            }
            .scaleEffect(selected ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .animation(Motion.standard, value: selected)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var preview: some View {
        if choice == .system {
            // Half light, half dark: it follows the Mac.
            HStack(spacing: 0) {
                window(.light)
                window(.dark)
            }
        } else {
            window(choice.palette(for: choice == .dark ? .dark : .light))
        }
    }

    private func window(_ p: Palette) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i == 0 ? p.accent : p.faint.opacity(0.5)).frame(width: 16, height: 3)
                }
                Spacer()
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .background(p.panel)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(p.text).frame(width: 34, height: 4)
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(p.muted.opacity(0.5)).frame(height: 3)
                }
                Spacer()
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(p.bg)
        }
    }
}

/// A way for the brief to read, shown as a small live Today.
private struct BriefStyleTile: View {
    @Environment(\.onboarding) private var s
    let style: BriefStyle
    let selected: Bool
    let action: () -> Void
    /// Which link or row is lit: it moves along, to show what the style does.
    @State private var beat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                PaperCard(radius: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Good morning.")
                            .font(.system(size: 17, design: .serif))
                            .foregroundStyle(s.ink)
                        if style == .paragraph { paragraph } else { points }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(width: 280, height: 164, alignment: .topLeading)
                }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? s.accent : .clear, lineWidth: 2))
                // Only the picture lifts: scaling the whole tile moved its
                // label row out of line with the other one.
                .scaleEffect(selected ? 1.03 : 1)

                HStack(spacing: 6) {
                    Icon(style.icon, size: 13)
                    Text(style.label).font(FN.font(13.5, selected ? .semibold : .medium))
                    if style == .paragraph {
                        Text("Compact")
                            .font(FN.font(10.5, .semibold))
                            .foregroundStyle(s.accent)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(s.accent.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    ZStack {
                        Circle().stroke(selected ? s.accent : s.faint.opacity(0.5), lineWidth: 1.5)
                        Circle().fill(s.accent).padding(4).scaleEffect(selected ? 1 : 0.01)
                    }
                    .frame(width: 16, height: 16)
                }
                .foregroundStyle(selected ? s.ink : s.muted)
                Text(style.detail)
                    .font(FN.font(12.5)).foregroundStyle(s.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // As wide as the picture: the label row's Spacer otherwise
            // stretched it across the page, and its radio button ended up
            // under the other tile.
            .frame(width: 280, alignment: .leading)
            .opacity(selected ? 1 : 0.82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: selected)
        .accessibilityLabel(style.label)
        .accessibilityHint(style.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeInOut(duration: 0.35)) { beat += 1 }
            }
        }
    }

    /// A few sentences, the phrases worth a click underlined — one lit at a time.
    private var paragraph: some View {
        let parts: [(String, Bool)] = [
            ("You have ", false), ("3 things due", true), (" today, starting with ", false),
            ("Call Budi", true), (" at 2:30 PM. Yesterday you spent ", false), ("Rp 120rb", true),
            (", mostly on food.", false),
        ]
        let lit = beat % 3
        var text = AttributedString()
        var link = 0
        for (piece, isLink) in parts {
            var run = AttributedString(piece)
            if isLink {
                run.foregroundColor = link == lit ? s.accent : s.ink
                run.underlineStyle = Text.LineStyle(pattern: .solid,
                                                    color: link == lit ? s.accent : s.faint.opacity(0.7))
                link += 1
            }
            text += run
        }
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(s.muted)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line each, the next arriving in turn.
    private var points: some View {
        let rows: [(String, CGFloat)] = [("✳︎", 150), ("○", 120), ("○", 170), ("⚠︎", 110)]
        let lit = beat % rows.count
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 9) {
                    Text(row.0).font(.system(size: 10)).foregroundStyle(index == lit ? s.accent : s.faint)
                        .frame(width: 12)
                    Capsule()
                        .fill(index == lit ? s.accent.opacity(0.55) : s.faint.opacity(0.35))
                        .frame(width: row.1, height: 5)
                }
                .offset(x: index == lit ? 3 : 0)
            }
        }
        .padding(.top, 2)
    }
}

/// Everything the app does, around its mark.
private struct FeatureOrbit: View {
    @Environment(\.onboarding) private var s
    private let items: [(icon: String, label: String)] = [
        ("note", "Notes"), ("todo", "To-Do"), ("finance", "Finance"),
        ("scan", "Scan"), ("mic", "Voice"), ("collapseLeft", "Edge dock"),
    ]

    var body: some View {
        GeometryReader { proxy in
            let c = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let r = min(proxy.size.width, proxy.size.height) / 2 - 36
            ZStack {
                Circle()
                    .stroke(s.faint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    .frame(width: r * 2, height: r * 2)
                    .position(c)
                MarkTile(size: 70)
                    .position(c)
                    .arrive(0.05)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(items.count)
                    VStack(spacing: 5) {
                        Icon(item.icon, size: 17)
                            .foregroundStyle(s.ink.opacity(0.75))
                            .frame(width: 42, height: 42)
                            .background(s.card, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
                            .shadow(color: .black.opacity(s.dark ? 0.35 : 0.06), radius: 8, y: 3)
                        Text(item.label).font(FN.font(10.5)).foregroundStyle(s.muted)
                    }
                    .position(x: c.x + r * cos(angle), y: c.y + r * sin(angle) + 8)
                    .arrive(0.12 + Double(index) * 0.07)
                }
            }
        }
    }
}

/// The last page: what you just set up, in a row, with the mark raised.
private struct CelebrationRow: View {
    @Environment(\.onboarding) private var s
    @State private var raised = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let left: [(String, Color)] = [("note", .hex(0x7D6FF6)), ("todo", .hex(0x3BA5F1)), ("today", .hex(0xF0A23B))]
    private let right: [(String, Color)] = [("finance", .hex(0x3CC6A3)), ("mic", .hex(0xF2616E)), ("scan", .hex(0x5B6CF0))]

    var body: some View {
        VStack(spacing: 14) {
            Text("I've just set up my Four Notes 🎉")
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(s.ink)
                .padding(.horizontal, 22)
                .frame(height: 50)
                .background(s.card.opacity(0.75), in: Capsule())
                .overlay(Capsule().stroke(s.cardEdge, lineWidth: 1))
                .shadow(color: .black.opacity(s.dark ? 0.3 : 0.05), radius: 10, y: 4)
                .arrive(0.35)

            HStack(spacing: 12) {
                ForEach(left, id: \.0) { tile($0.0, $0.1) }
                MarkTile(size: raised ? 74 : 54)
                    .offset(y: raised ? -14 : 0)
                ForEach(right, id: \.0) { tile($0.0, $0.1) }
            }
            .padding(.horizontal, 14)
            .frame(height: 76)
            .background(s.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
            .arrive(0.05)
        }
        .onAppear {
            if reduceMotion { raised = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.25)) { raised = true }
        }
    }

    private func tile(_ icon: String, _ tone: Color) -> some View {
        Icon(icon, size: 20, weight: 1.9)
            .foregroundStyle(tone)
            .frame(width: 50, height: 50)
            .background(s.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(s.dark ? 0.35 : 0.06), radius: 6, y: 2)
    }
}

private struct TrustBadge: View {
    @Environment(\.onboarding) private var s
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Icon(icon, size: 12).foregroundStyle(s.accent)
            Text(text).font(FN.font(11.5)).foregroundStyle(s.muted)
        }
    }
}

// MARK: - The edge dock, shown working

/// A key, drawn as a small keycap.
private struct Keycap: View {
    @Environment(\.onboarding) private var s
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(FN.font(12, .semibold))
            .foregroundStyle(s.ink)
            .frame(minWidth: 24, minHeight: 24)
            .background(s.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(s.dark ? 0.3 : 0.06), radius: 0, y: 1.5)
    }
}

/// A small screen with an app on it and the dock's handle on its edge. The
/// pointer goes to the handle, it grows into the drawer — the same shape
/// the real one uses — a note gets typed, a task ticked, dictation listens,
/// and it tucks itself away again. On a loop, unless motion is reduced.
private struct EdgeDockDemo: View {
    @Environment(\.onboarding) private var s
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let style: DockStyle

    @State private var size: CGSize = .zero
    @State private var open = false
    @State private var peek = false
    @State private var cursor = CGPoint(x: 150, y: 220)
    @State private var pressed = false
    @State private var typed = 0
    @State private var ticked = false
    @State private var listening = false

    private let note = "Call Budi about the trip"
    private let drawerSize = CGSize(width: 206, height: 238)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The screen, with someone's work on it.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(s.field)
            appWindow
                .frame(width: 236, height: 196)
                .position(x: 150, y: size.height / 2 + 8)

            let shape = EdgeTabShape(geometry)
            shape.fill(style.surface)
                .shadow(color: .black.opacity(open ? 0.3 : 0.18), radius: open ? 16 : 4, y: open ? 6 : 1)
            shape.stroke(s.dark ? Color.white.opacity(0.1) : style.line, lineWidth: 1)

            ZStack(alignment: .topLeading) {
                handleFace
                    .frame(width: 17, height: 58)
                    .position(x: size.width - 8.5, y: size.height / 2)
                    .opacity(open ? 0 : 1)
                drawer
                    .frame(width: drawerSize.width, height: drawerSize.height)
                    .position(x: size.width - drawerSize.width / 2, y: size.height / 2)
                    .opacity(open ? 1 : 0)
            }
            .clipShape(shape)

            Image(systemName: "cursorarrow")
                .font(.system(size: 19))
                .foregroundStyle(s.dark ? .white : .black)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .scaleEffect(pressed ? 0.82 : 1)
                .position(cursor)
                .opacity(reduceMotion ? 0 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
        .shadow(color: .black.opacity(s.dark ? 0.35 : 0.08), radius: 16, y: 6)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .environment(\.dock, style)
        .task(id: size == .zero) {
            guard size != .zero else { return }
            await play()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("An animation of the edge dock opening from the side of the screen")
    }

    /// The shape as the real dock draws it: a slim handle, or the drawer.
    private var geometry: DockGeometry {
        DockGeometry(frame: .zero, centerFromTop: size.height / 2,
                     bodyWidth: open ? drawerSize.width : (peek ? 24 : 17),
                     bodyHeight: open ? drawerSize.height : 58,
                     corner: open ? 18 : 7, fillet: open ? 16 : 8)
    }

    private var appWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.hex(0xFF5F57), .hex(0xFEBC2E), .hex(0x28C840)], id: \.self) { c in
                    Circle().fill(c).frame(width: 6, height: 6)
                }
            }
            .padding(8)
            VStack(alignment: .leading, spacing: 7) {
                Capsule().fill(s.ink.opacity(0.55)).frame(width: 90, height: 6)
                ForEach([150, 170, 128, 160, 100], id: \.self) { w in
                    Capsule().fill(s.faint.opacity(0.35)).frame(width: CGFloat(w), height: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            Spacer()
        }
        .background(s.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(s.cardEdge, lineWidth: 1))
        .shadow(color: .black.opacity(s.dark ? 0.3 : 0.06), radius: 8, y: 3)
    }

    private var handleFace: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(style.raised, lineWidth: 1.8)
                Circle().trim(from: 0, to: 0.6).stroke(style.teal, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("2").font(.system(size: 6.5, weight: .bold)).foregroundStyle(style.text)
            }
            .frame(width: 12, height: 12)
        }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Wednesday").font(FN.serif(12)).foregroundStyle(style.text)
                .padding(.leading, 2)

            miniCard("Quick note") {
                HStack(spacing: 0) {
                    Text(String(note.prefix(typed)))
                    Rectangle().fill(style.primary).frame(width: 1, height: 10)
                        .opacity(open && typed < note.count ? 1 : 0)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(style.text)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(style.field, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            miniCard("Today") {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(ticked ? style.muted.opacity(0.35) : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(ticked ? .clear : style.faint, lineWidth: 1))
                        .overlay(Image(systemName: "checkmark").font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(style.text).opacity(ticked ? 1 : 0))
                        .frame(width: 10, height: 10)
                    Text("Pay the electricity bill")
                        .font(.system(size: 9.5))
                        .strikethrough(ticked, color: style.muted)
                        .foregroundStyle(ticked ? style.muted : style.text)
                }
            }

            miniCard("Transcribe") {
                HStack(spacing: 7) {
                    Circle().fill(listening ? style.rose : style.primary)
                        .frame(width: 16, height: 16)
                        .overlay(Image(systemName: listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 6.5)).foregroundStyle(.white))
                    LevelBars(active: listening, tint: style.primary, idle: style.faint)
                        .frame(height: 16)
                }
            }
        }
        .padding(10)
    }

    private func miniCard<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(FN.serif(10.5)).foregroundStyle(style.text)
            content()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(style.cardEdge, lineWidth: 1))
    }

    // MARK: The loop

    private func play() async {
        if reduceMotion {
            open = true; typed = note.count; ticked = true
            return
        }
        let rest = CGPoint(x: 150, y: size.height / 2 + 60)
        let handle = CGPoint(x: size.width - 10, y: size.height / 2 + 4)
        let noteSpot = CGPoint(x: size.width - 130, y: size.height / 2 - 52)
        let taskSpot = CGPoint(x: size.width - 188, y: size.height / 2 + 12)
        let micSpot = CGPoint(x: size.width - 182, y: size.height / 2 + 76)

        while !Task.isCancelled {
            open = false; peek = false; typed = 0; ticked = false; listening = false
            cursor = rest
            guard await pause(0.9) else { return }

            withAnimation(.easeInOut(duration: 1.0)) { cursor = handle }
            guard await pause(0.85) else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { peek = true }
            guard await pause(0.45) else { return }
            await click()
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) { open = true }
            guard await pause(0.55) else { return }

            withAnimation(.easeInOut(duration: 0.7)) { cursor = noteSpot }
            guard await pause(0.75) else { return }
            await click()
            for i in 1...note.count {
                typed = i
                guard await pause(0.045) else { return }
            }
            guard await pause(0.35) else { return }

            withAnimation(.easeInOut(duration: 0.6)) { cursor = taskSpot }
            guard await pause(0.65) else { return }
            await click()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { ticked = true }
            guard await pause(0.5) else { return }

            withAnimation(.easeInOut(duration: 0.6)) { cursor = micSpot }
            guard await pause(0.65) else { return }
            await click()
            withAnimation(Motion.standard) { listening = true }
            guard await pause(2.0) else { return }
            withAnimation(Motion.standard) { listening = false }

            withAnimation(.easeInOut(duration: 0.9)) { cursor = rest }
            guard await pause(0.25) else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { open = false; peek = false }
            guard await pause(1.6) else { return }
        }
    }

    private func click() async {
        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
        _ = await pause(0.1)
        withAnimation(.easeOut(duration: 0.12)) { pressed = false }
    }

    /// False once the page has gone, so the loop stops.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// Dictation's level bars, moving while "listening".
private struct LevelBars: View {
    let active: Bool
    let tint: Color
    let idle: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in
                    let wave = active ? (0.35 + 0.65 * abs(sin(t * 5.2 + Double(i) * 0.7) * cos(t * 2.1 + Double(i) * 0.3))) : 0.12
                    Capsule()
                        .fill(active ? tint.opacity(0.5 + 0.5 * Double(i) / 16) : idle.opacity(0.5))
                        .frame(width: 2.5, height: max(2.5, 16 * wave))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
