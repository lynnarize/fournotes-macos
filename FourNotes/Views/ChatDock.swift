import AppKit
import SwiftUI

// Where the assistant lives on screen, as on the web (src/components/ChatDock.tsx):
//   hero       Today's composer, under the greeting, with a few things to start with.
//              Sending turns it, in place, into a chat card, as Arc's AI composer does:
//              your message lifts into a bubble, the reply streams in under it, and the
//              composer glides to the card's foot. The sidebar and Today's cards stay.
//   minimized  Every other tab: an "Ask Four Notes" pill in the corner that opens the
//              same chat as a panel. "Open on Today" moves it into Today's card.

struct ChatDock: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var engine: AIEngine

    var minimized: Bool
    /// Today's: the composer in the page, turning into the chat card.
    var hero = false

    @Namespace private var glide
    @State private var text = ""
    /// Minimized mode only: the panel is showing instead of the pill.
    @State private var expanded = false
    /// The corner panel's frame in the window, for telling clicks outside it.
    @State private var panelFrame: CGRect = .zero
    @State private var outsideClicks: Any?
    @State private var unread = false
    @State private var splitTxId: String?
    @FocusState private var inputFocused: Bool

    /// Things to start with on Today: two fill in the start of a request, one asks.
    private static let starters: [(icon: String, title: String, text: String)] = [
        ("noteAdd", "Write a note", "Write a note about "),
        ("receipt", "Log spending", "Spent "),
        ("calendarCheck", "Plan my day", "What should I focus on today?"),
    ]

    var body: some View {
        Group {
            if hero {
                if nav.todayChat { chatCard } else { heroComposer }
            } else if minimized && !expanded {
                pill
                    // Grows back out of the corner the panel folds into.
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                panel
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { panelFrame = $0 }
                    .onExitCommand { collapse() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    // Opens out of the pill's corner, and folds back into it.
                    .transition(.scale(scale: 0.4, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Motion.instant : .spring(response: 0.42, dampingFraction: 0.84),
                   value: minimized && !expanded)
        // Opened in the corner, a click anywhere else folds it away again.
        .onChange(of: minimized && expanded) { _, isOpen in
            isOpen ? watchOutsideClicks() : stopWatchingClicks()
        }
        .onDisappear { stopWatchingClicks() }
        // Replies are model output, and a note or a web page can steer it:
        // only web links open from here.
        .environment(\.openURL, .webOnly)
        .onChange(of: minimized) { _, _ in expanded = false }
        .onChange(of: assistant.messages.count) { old, new in
            guard new > old, let last = assistant.messages.last else { return }
            // A reply that arrives while a conversation is on screen streams in.
            if last.role == .assistant, hero || expanded { FreshReplies.ids.insert(last.id) }
            if hero {
                // On Today the card opens: a scan or a recording started from the
                // sidebar lands there too.
                if !nav.todayChat { glideTo(true) }
            } else if expanded || last.role == .user {
                reveal()
            } else {
                unread = true
            }
        }
        .onChange(of: nav.assistantDraft) { _, draft in takeDraft(draft) }
        // Also when this view is new — a window reopened from the edge dock with a
        // request waiting: onChange never sees a value set before it.
        .onAppear {
            takeDraft(nav.assistantDraft)
            // Cleared from the corner panel since: no empty card on Today.
            if hero, nav.todayChat, assistant.messages.isEmpty, assistant.busy == nil { nav.todayChat = false }
        }
        .onChange(of: assistant.recording) { _, recording in
            // Recording shows its live status, so it needs the panel open.
            if recording && minimized { reveal() }
        }
        .fnSheet(item: Binding(
            get: { splitTxId.map { IdentifiedString(value: $0) } },
            set: { splitTxId = $0?.value })) { wrapped in
            SplitEditorSheet(txId: wrapped.value)
        }
    }

    // MARK: - Today

    private var heroComposer: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChatComposer(text: $text, focused: $inputFocused,
                         placeholder: "Ask anything, / for commands, @ to add a note",
                         floating: true, onSend: submit)
                .matchedGeometryEffect(id: "composer", in: glide)

            HStack(spacing: 8) {
                ForEach(Self.starters, id: \.title) { starter in
                    PillButton(icon: starter.icon, title: starter.title) {
                        text = starter.text
                        if starter.text.hasSuffix("?") { submit(starter.text); text = "" } else { inputFocused = true }
                    }
                }
                if !assistant.messages.isEmpty {
                    PillButton(icon: "undo", title: "Back to the conversation") { glideTo(true) }
                        .transition(.opacity)
                }
            }
            .disabled(assistant.busy != nil)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// The conversation, in a card where the composer was.
    private var chatCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(cardTitle)
                    .font(FN.font(13, .medium))
                    .foregroundStyle(p.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconButton("newChat", size: 16, box: 30, help: "New chat") {
                    glideTo(false) { assistant.clear() }
                }
                .disabled(assistant.busy != nil)
                IconButton("x", size: 16, box: 30, help: "Close the chat") { glideTo(false) }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }

            ChatThread(onJump: jump, onSplit: { splitTxId = $0 })

            ChatComposer(text: $text, focused: $inputFocused,
                         placeholder: "Ask a follow-up, / for commands, @ to add a note",
                         onSend: submit)
                .matchedGeometryEffect(id: "composer", in: glide)
                .padding(12)
        }
        .background(p.surface, in: RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        // As tall as the window allows, within reason.
        .containerRelativeFrame(.vertical) { height, _ in max(420, min(680, height - 200)) }
        .transition(.opacity.combined(with: .offset(y: 6)))
        .onExitCommand { glideTo(false) }
    }

    /// The card's title: the conversation's first question.
    private var cardTitle: String {
        assistant.messages.first(where: { $0.role == .user })?.content
            .components(separatedBy: .newlines).first ?? "Assistant"
    }

    /// Opens or folds the card, the composer gliding between its two places.
    private func glideTo(_ open: Bool, then: (() -> Void)? = nil) {
        withAnimation(reduceMotion ? Motion.instant : .spring(response: 0.46, dampingFraction: 0.88)) {
            nav.todayChat = open
            then?()
        }
        if open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { inputFocused = true } }
    }

    // MARK: - The corner

    private var pill: some View {
        HStack {
            Spacer()
            AskPill(busy: assistant.busy, unread: unread) { reveal(focus: true) }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                HStack(spacing: 8) {
                    Text("Assistant").font(FN.font(13, .medium)).foregroundStyle(p.foreground)
                    if engine.chatRunsOnDevice { OnDeviceMark(origin: .onDevice) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !assistant.messages.isEmpty {
                    IconButton("newChat", size: 16, box: 30, help: "New chat") { assistant.clear() }
                        .disabled(assistant.busy != nil)
                }
                IconButton("expand", size: 15, box: 30, help: "Open on Today") { openOnToday() }
                IconButton("x", size: 16, box: 30, help: "Close") { collapse() }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }

            ChatThread(onJump: jump, onSplit: { splitTxId = $0 }, onSuggest: { q in submit(q) })

            ChatComposer(text: $text, focused: $inputFocused,
                         placeholder: "Ask anything, / for commands, @ to add a note",
                         onSend: submit)
                .padding(12)
        }
        .frame(width: 420)
        .clipShape(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
        .containerRelativeFrame(.vertical) { height, _ in min(720, height - 40) }
        .floating(p)
    }

    /// Moves the conversation onto Today, into its card.
    private func openOnToday() {
        collapse()
        nav.todayChat = true
        nav.tab = .today
    }

    // MARK: - Clicks outside the corner panel

    /// Watches clicks in the window while the corner panel is open; one outside it
    /// folds it away. The click still goes where it was aimed.
    private func watchOutsideClicks() {
        guard outsideClicks == nil else { return }
        outsideClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Only the main window: the edge dock, menus the composer opens and
            // sheets are other windows, and clicks there aren't "outside".
            guard let window = event.window, window.canBecomeMain,
                  let content = window.contentView else { return event }
            let point = CGPoint(x: event.locationInWindow.x,
                                y: content.bounds.height - event.locationInWindow.y)
            if !panelFrame.insetBy(dx: -4, dy: -4).contains(point) {
                DispatchQueue.main.async { collapse() }
            }
            return event
        }
    }

    private func stopWatchingClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    // MARK: - Actions

    private func reveal(focus: Bool = false) {
        expanded = true
        unread = false
        if focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { inputFocused = true }
        }
    }

    /// "Ask the assistant…" from elsewhere: fill in the request and open the input,
    /// without sending — it is the user's to finish.
    private func takeDraft(_ draft: String?) {
        guard let draft else { return }
        text = draft
        nav.assistantDraft = nil
        if hero { inputFocused = true } else { reveal(focus: true) }
    }

    private func collapse() {
        inputFocused = false
        expanded = false
    }

    private func submit(_ message: String) {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, assistant.busy == nil else { return }
        if hero && !nav.todayChat { glideTo(true) }
        Task { await assistant.send(t) }
    }

    /// Jump to what the assistant changed, folding the conversation so the item isn't
    /// hidden behind it.
    private func jump(_ link: ChangeLink, _ all: [ChangeLink]) {
        nav.markFiled(all)
        // Shown now, so not news: no dot left on the tabs these went to.
        nav.clearPulses(for: all)
        if minimized { collapse() }
        inputFocused = false
        nav.open(link)
    }
}

// MARK: - Bits

/// A quiet "On this Mac" mark: which replies Apple Intelligence worked out
/// locally, with the reason on hover. It replaces a sentence that used to be
/// appended to the reply — and then read back to the model as history.
struct OnDeviceMark: View {
    @Environment(\.palette) private var p
    let origin: ReplyOrigin
    /// "LM Studio" or "Apple Intelligence", for the hover text.
    var name: String?

    var body: some View {
        HStack(spacing: 4) {
            Icon("monitor", size: 11)
            Text("On this Mac")
        }
        .font(FN.font(11, .medium))
        .foregroundStyle(p.faint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(p.hover, in: Capsule())
        .help(origin == .onDeviceFallback
              ? "The cloud model didn’t answer, so \(name ?? "this Mac") replied here. Nothing left this Mac."
              : "Answered by \(name ?? "Apple Intelligence") on this Mac. Nothing left this Mac.")
        .accessibilityLabel(origin == .onDeviceFallback
                            ? "Answered on this Mac because the cloud model didn’t answer"
                            : "Answered on this Mac")
    }
}

/// "Cloud · OpenRouter": a reply that was asked of a cloud model.
struct CloudMark: View {
    @Environment(\.palette) private var p
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Icon("cloud", size: 11)
            Text("Cloud · \(name)")
        }
        .font(FN.font(11, .medium))
        .foregroundStyle(p.faint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(p.hover, in: Capsule())
        .help("Answered by \(name) in the cloud, because you asked for it.")
        .accessibilityLabel("Answered by \(name) in the cloud")
    }
}

/// The assistant folded into the corner: a floating pill. Alive without being busy:
/// the sparkle breathes, a soft light passes over the words now and then, and it lifts
/// under the pointer. All of it stops with Reduce Motion.
private struct AskPill: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let busy: String?
    let unread: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var shown = false

    var body: some View {
        let label = busy ?? "Ask Four Notes"
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if busy != nil {
                        BusyRing(color: p.foreground).scaleEffect(1.35)
                    }
                    Icon("sparkle", size: 15)
                        .foregroundStyle(p.foreground)
                        .phaseAnimator(reduceMotion ? [false] : [false, true]) { icon, up in
                            icon.scaleEffect(up ? 1.16 : 0.88).rotationEffect(.degrees(up ? 16 : -10))
                        } animation: { _ in .easeInOut(duration: 1.6) }
                }
                .frame(width: 22, height: 22)

                Text(label)
                    .font(FN.font(13))
                    .foregroundStyle(hovering ? p.foreground : p.textSecondary)
                    .lineLimit(1)
                    // A band of light that crosses the words now and then.
                    .overlay {
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            LinearGradient(colors: [.clear, p.foreground.opacity(0.6), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: width * 0.45)
                                .keyframeAnimator(initialValue: -0.6, repeating: true) { band, x in
                                    band.offset(x: width * x)
                                } keyframes: { _ in
                                    CubicKeyframe(1.2, duration: 1.4)
                                    LinearKeyframe(1.2, duration: 3)
                                }
                        }
                        .mask(Text(label).font(FN.font(13)).lineLimit(1))
                        .allowsHitTesting(false)
                        .opacity(reduceMotion ? 0 : 1)
                    }

                if unread {
                    Circle().fill(p.accent).frame(width: 8, height: 8)
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 40)
            .background {
                Capsule().fill(p.surface)
                    .shadow(color: p.shadowStrong, radius: hovering ? 22 : 16, y: hovering ? 10 : 6)
            }
            .overlay(Capsule().strokeBorder(hovering ? p.borderStrong : p.border, lineWidth: 1))
            .scaleEffect(hovering ? 1.03 : 1, anchor: .bottomTrailing)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? Motion.instant : .spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .animation(Motion.standard, value: unread)
        .animation(Motion.standard, value: busy)
        .help("Assistant")
        .accessibilityLabel("Assistant")
        .accessibilityValue(unread ? "New reply" : (busy ?? ""))
        // A small pop on arrival, from the corner it lives in.
        .scaleEffect(shown ? 1 : 0.85, anchor: .bottomTrailing)
        .opacity(shown ? 1 : 0)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { shown = true }
        }
    }
}

/// "The assistant is working": a sparkle that breathes and turns, three dots
/// rising in a wave, and the status line with a light sweeping across it.
/// Driven by a timeline rather than an implicit animation — animating a phase
/// from 0 to 2π interpolates between two identical opacities and shows nothing.
struct TypingDots: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var label: String?
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSince(start)
            HStack(spacing: 10) {
                sparkle(t)
                if let label {
                    Text(label)
                        .foregroundStyle(p.muted)
                        .overlay { sweep(t).mask(Text(label)) }
                }
                dots(t)
            }
            .font(.system(size: 15))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(p.hover.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Thinking")
    }

    private func sparkle(_ t: Double) -> some View {
        let breath = 0.5 + 0.5 * sin(t * 3)
        return ZStack {
            Circle()
                .fill(p.accent.opacity(0.18 + 0.14 * breath))
                .frame(width: 26, height: 26)
                .scaleEffect(0.85 + 0.2 * breath)
            Icon("sparkle", size: 15)
                .foregroundStyle(p.accent)
                .rotationEffect(.degrees(sin(t * 1.6) * 14))
                .scaleEffect(0.92 + 0.12 * breath)
        }
        .frame(width: 26, height: 26)
    }

    private func dots(_ t: Double) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                // Each dot lifts in turn, then rests.
                let wave = max(0, sin(t * 5 - Double(i) * 0.9))
                Circle()
                    .fill(p.accent)
                    .frame(width: 5, height: 5)
                    .opacity(0.35 + 0.65 * wave)
                    .offset(y: -3 * wave)
            }
        }
        .frame(height: 12)
    }

    /// A soft highlight crossing the text every 1.6 s.
    private func sweep(_ t: Double) -> some View {
        let x = t.truncatingRemainder(dividingBy: 1.6) - 0.3
        return LinearGradient(
            stops: [.init(color: .clear, location: 0),
                    .init(color: p.text, location: 0.5),
                    .init(color: .clear, location: 1)],
            startPoint: UnitPoint(x: x - 0.3, y: 0.5),
            endPoint: UnitPoint(x: x + 0.3, y: 0.5))
    }
}

struct IdentifiedString: Identifiable {
    var value: String
    var id: String { value }
}
