import AppKit
import SwiftUI

// The assistant bar. On Today it is the full dock; on the other tabs it folds
// into a round button in the corner and opens as a panel.
// Ported from src/components/ChatDock.tsx.

private let SUGGESTIONS = [
    "Remind me to pay rent of 2.5M every month on the 5th at 9am",
    "Spent 45k on lunch at Warteg, split with Andi",
    "Set my food budget to 1.5M a month",
    "Where did I write about the Bali trip?",
    "What did I spend most on this month?",
]

struct ChatDock: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var engine: AIEngine

    var minimized: Bool
    /// Today's: a large composer in the middle of the page, like a chat
    /// app's home, with the conversation opening above the input.
    var hero = false

    /// The conversation's own height, so the panel grows with it rather than
    /// opening at full size around two lines.
    @State private var contentHeight: CGFloat = 0
    /// Today's floating conversation, measured so it sits above the input.
    @State private var floatingHeight: CGFloat = 0

    @State private var text = ""
    @State private var open = false
    /// Minimized mode only: the panel is showing instead of the round button.
    @State private var expanded = false
    @State private var unread = false
    @State private var splitTxId: String?
    @FocusState private var inputFocused: Bool

    private var showingPanel: Bool { minimized ? expanded : true }

    var body: some View {
        Group {
            if hero {
                heroComposer
            } else if minimized && !expanded {
                roundButton
            } else if minimized {
                // Opened from the corner: the same composer as Today's,
                // narrower, in the corner.
                heroComposer
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 24)
                    .padding(.bottom, 20)
            } else {
                dock
            }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .animation(Motion.screen, value: minimized && !expanded)
        // Replies are model output, and a note or a web page can steer it:
        // only web links open from here.
        .environment(\.openURL, .webOnly)
        .onChange(of: minimized) { _, _ in
            expanded = false
            if minimized { open = false }
        }
        .onChange(of: assistant.messages.count) { old, new in
            guard new > old else { return }
            let lastIsUser = assistant.messages.last?.role == .user
            if !minimized || expanded || lastIsUser { reveal() } else { unread = true }
        }
        .onChange(of: nav.assistantDraft) { _, draft in takeDraft(draft) }
        // Also when this view is new — a window reopened from the edge dock
        // with a request waiting: onChange never sees a value set before it.
        .onAppear { takeDraft(nav.assistantDraft) }
        .onChange(of: assistant.recording) { _, recording in
            // Recording shows its live status, so it needs the panel open.
            if recording && minimized { reveal() }
        }
        .sheet(item: Binding(
            get: { splitTxId.map { IdentifiedString(value: $0) } },
            set: { splitTxId = $0?.value })) { wrapped in
            SplitEditorSheet(txId: wrapped.value)
        }
    }

    // MARK: - Collapsed button

    /// The assistant folded away on the other tabs: a small pill in the
    /// style of Today's composer. One click opens the composer in its place.
    private var roundButton: some View {
        HStack {
            Spacer()
            Button { reveal(focus: true) } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Icon("sparkle", size: 15).foregroundStyle(p.accent)
                        if assistant.busy != nil {
                            Circle()
                                .trim(from: 0, to: 0.75)
                                .stroke(p.accent.opacity(0.8), lineWidth: 1.5)
                                .frame(width: 24, height: 24)
                                .rotationEffect(.degrees(spin))
                                .onAppear {
                                    guard !reduceMotion else { return }
                                    // From zero each time: left at 360, the next
                                    // busy spell had nothing to animate to.
                                    spin = 0
                                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                                        spin = 360
                                    }
                                }
                        }
                    }
                    .frame(width: 24, height: 24)
                    Text(assistant.busy ?? "Ask Four Notes")
                        .font(FN.font(13.5))
                        .foregroundStyle(p.muted)
                        .lineLimit(1)
                    if unread {
                        Circle().fill(p.danger).frame(width: 8, height: 8)
                            .transition(.scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 16)
                .frame(height: 42)
                .background(p.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(p.line, lineWidth: 1))
                .shadow(color: p.shadowStrong, radius: 14, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.fn)
            .help("Assistant")
            .accessibilityLabel("Assistant")
            .motion(unread, Motion.standard)
            .motion(assistant.busy, Motion.standard)
        }
        .padding(.trailing, 24)
        .padding(.bottom, 20)
    }

    @State private var spin: Double = 0

    // MARK: - Today's composer

    /// Things to start with, each filling in the start of a request.
    private static let starters: [(icon: String, title: String, text: String)] = [
        ("noteAdd", "Write", "Write a note about "),
        ("bell", "Remind", "Remind me to "),
        ("wallet", "Spent", "Spent "),
        ("search", "Find", "Where did I write about "),
        ("sparkle", "Plan my day", "What should I focus on today?"),
    ]

    private var heroComposer: some View {
        let sendDisabled = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.busy != nil
        return VStack(spacing: 18) {
            VStack(spacing: 0) {
                if assistant.recording {
                    recordingBar
                    Divider().overlay(p.line)
                }

                TextField("How can I help you today?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(p.text)
                    .lineLimit(2...8)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onChange(of: inputFocused) { _, focused in if focused { open = true } }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)

                HStack(spacing: 6) {
                    MenuButton(help: "Add", entries: {
                        [.item("Scan a receipt or note…") { assistant.pickAndScan() },
                         .item(assistant.recording ? "Stop recording" : "Record a voice note") {
                             assistant.recording ? assistant.stopRecording() : assistant.startRecording()
                         },
                         .item("Paste from the clipboard") {
                             if let clip = NSPasteboard.general.string(forType: .string) {
                                 text = String(clip.prefix(2_000))
                                 inputFocused = true
                             }
                         }]
                    }) {
                        Icon("plus", size: 18)
                            .foregroundStyle(p.muted)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .disabled(assistant.busy != nil)

                    if minimized {
                        IconButton("chevronDown", size: 16, box: 32, help: "Hide the assistant") { collapse() }
                    }

                    Spacer()

                    Text(engine.route.label)
                        .font(FN.font(13))
                        .foregroundStyle(p.faint)
                        .lineLimit(1)
                        .padding(.trailing, 4)
                        .help("Answers come from \(engine.route.label). Change it in Settings → AI & API keys.")

                    IconButton(assistant.recording ? "stop" : "mic", size: 18, box: 32,
                               tone: assistant.recording ? .white : nil,
                               help: assistant.recording ? "Stop and summarize" : "Record a voice note") {
                        assistant.recording ? assistant.stopRecording() : assistant.startRecording()
                    }
                    .background(assistant.recording ? p.danger : .clear, in: Circle())
                    .disabled(assistant.busy != nil && !assistant.recording)

                    Button(action: submit) {
                        Icon("send", size: 16, weight: 2)
                            .foregroundStyle(sendDisabled ? p.faint : p.bg)
                            .frame(width: 32, height: 32)
                            .background(sendDisabled ? p.hover : p.text, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.fn)
                    .disabled(sendDisabled)
                    .motion(sendDisabled, Motion.quick)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .background(p.panel, in: inputShape)
            .overlay(inputShape.stroke(p.line, lineWidth: 1))
            .shadow(color: p.shadowStrong, radius: 18, y: 6)
            // The conversation grows up out of the input, over the page: one
            // card, so Today stays one page and nothing below it moves.
            .overlay(alignment: .top) {
                if showsConversation {
                    conversation
                        .background(p.panel, in: conversationShape)
                        .clipShape(conversationShape)
                        .overlay(conversationShape.stroke(p.line, lineWidth: 1))
                        .shadow(color: .black.opacity(0.22), radius: 20, y: -6)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { floatingHeight = $0 }
                        // Sitting exactly on the input, sharing its edge.
                        .offset(y: -floatingHeight + 1)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .animation(Motion.screen, value: open || assistant.recording)

            if !minimized {
            HStack(spacing: 8) {
                ForEach(Self.starters, id: \.title) { starter in
                    StarterChip(icon: starter.icon, title: starter.title) {
                        if starter.text.hasSuffix("?") {
                            text = starter.text
                            submit()
                        } else {
                            text = starter.text
                            inputFocused = true
                        }
                    }
                }
            }
            .disabled(assistant.busy != nil)
            }
        }
        .frame(maxWidth: minimized ? 460 : 720)
    }

    private var showsConversation: Bool {
        open && (!assistant.messages.isEmpty || assistant.busy != nil)
    }

    /// Rounded all round; square on top while the conversation sits on it.
    private var inputShape: UnevenRoundedRectangle {
        let top: CGFloat = showsConversation ? 0 : 20
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 20,
                                      bottomTrailingRadius: 20, topTrailingRadius: top, style: .continuous)
    }

    private var conversationShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous)
    }

    // MARK: - Full dock

    private var dock: some View {
        VStack(spacing: 0) {
            if open {
                conversation
                Divider().overlay(p.line)
            }
            if assistant.recording {
                recordingBar
                Divider().overlay(p.line)
            }
            inputRow
        }
        .background(p.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(p.line, lineWidth: 1))
        .shadow(color: p.shadowStrong, radius: 16, y: 4)
        .entrance()
        // Opened from the corner button it is a compact panel in that corner,
        // not a sheet across the bottom of whatever you were working on. On
        // Today it is the page's own bar.
        .frame(maxWidth: minimized ? 500 : 800)
        .frame(maxWidth: .infinity, alignment: minimized ? .trailing : .center)
        .padding(.horizontal, minimized ? 24 : 16)
        .padding(.bottom, minimized ? 20 : 14)
        .transition(.opacity.combined(with: .offset(y: 10)))
        .animation(Motion.screen, value: open || assistant.recording)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Icon("sparkle", size: 15).foregroundStyle(p.accent)
                    Text("Assistant").font(FN.bodyMedium).foregroundStyle(p.muted)
                    if engine.chatRunsOnDevice {
                        OnDeviceMark(origin: .onDevice)
                    }
                }
                Spacer()
                if !assistant.messages.isEmpty {
                    GhostButton(action: { assistant.clear() }) { Text("Clear") }
                }
                IconButton("x", size: 14, box: 26, help: "Collapse chat") {
                    minimized && !hero ? collapse() : (open = false)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if assistant.messages.isEmpty {
                            FlowLayout(spacing: 8, alignment: .leading) {
                                ForEach(SUGGESTIONS, id: \.self) { s in
                                    SuggestionChip(text: s) { Task { await assistant.send(s) } }
                                }
                            }
                        }
                        ForEach(assistant.messages) { message in
                            MessageRow(message: message, onJump: jump) { splitTxId = $0 }
                                .id(message.id)
                                .transition(.move(edge: message.role == .user ? .trailing : .leading)
                                    .combined(with: .opacity))
                        }
                        if let busy = assistant.busy {
                            TypingDots(label: busy).id("busy")
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                // As tall as the conversation, up to a cap; past that it scrolls.
                // A floor too, so a two-line exchange doesn't look cramped.
                .frame(height: min(max(contentHeight, assistant.messages.isEmpty ? 1 : 220),
                                   minimized ? 540 : (hero ? 380 : 400)))
                .animation(Motion.list, value: assistant.messages)
                .animation(Motion.standard, value: assistant.busy)
                .onChange(of: assistant.messages.count) { _, _ in
                    withAnimation(Motion.list) { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                }
            }
        }
    }

    private var recordingBar: some View {
        HStack(spacing: 8) {
            Text("● Recording")
                .font(FN.bodyMedium)
                .foregroundStyle(p.danger)
            Text(transcriptLabel)
                .font(FN.body)
                .foregroundStyle(p.muted)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var transcriptLabel: String {
        if !assistant.liveTranscript.isEmpty { return assistant.liveTranscript }
        if assistant.transcriptionUnavailable {
            return "Recording. Dictation is off, so this will be written up after you stop."
        }
        return "Listening… press stop when you're done."
    }

    private var inputRow: some View {
        let sendDisabled = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || assistant.busy != nil
        return HStack(alignment: .bottom, spacing: 6) {
            IconButton("scan", size: 19, box: 34, help: "Scan a receipt, note or e-wallet screenshot") {
                assistant.pickAndScan()
            }
            .disabled(assistant.busy != nil)

            TextField(minimized ? "Ask or add anything…"
                                : "Ask, add a task, log spending, or paste an app notification…",
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(p.text)
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(submit)
                .onChange(of: inputFocused) { _, focused in if focused { open = true } }
                .padding(.vertical, 7)

            IconButton(assistant.recording ? "stop" : "mic", size: 19, box: 34,
                       tone: assistant.recording ? .white : nil,
                       help: assistant.recording ? "Stop and summarize" : "Record voice note") {
                assistant.recording ? assistant.stopRecording() : assistant.startRecording()
            }
            .background(assistant.recording ? p.danger : .clear,
                        in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
            .disabled(assistant.busy != nil && !assistant.recording)

            Button(action: submit) {
                Icon("send", size: 19)
                    .foregroundStyle(p.bg)
                    .frame(width: 34, height: 34)
                    .background(p.text, in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .disabled(sendDisabled)
            .opacity(sendDisabled ? 0.3 : 1)
            .motion(sendDisabled, Motion.quick)
            .accessibilityLabel("Send")
        }
        .padding(8)
    }

    // MARK: - Actions

    private func reveal(focus: Bool = false) {
        expanded = true
        open = true
        unread = false
        if focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { inputFocused = true }
        }
    }

    /// "Ask the assistant…" from elsewhere: fill in the request and open the
    /// input, without sending — it is the user's to finish.
    private func takeDraft(_ draft: String?) {
        guard let draft else { return }
        text = draft
        nav.assistantDraft = nil
        reveal(focus: true)
    }

    private func collapse() {
        expanded = false
        open = false
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, assistant.busy == nil else { return }
        text = ""
        open = true
        Task { await assistant.send(t) }
    }

    /// Jump to what the assistant changed, closing the panel so the item isn't hidden behind it.
    private func jump(_ link: ChangeLink, _ all: [ChangeLink]) {
        nav.markFiled(all)
        // Shown now, so not news: no dot left on the tabs these went to.
        nav.clearPulses(for: all)
        if minimized { collapse() } else { open = false }
        inputFocused = false
        nav.open(link)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var engine: AIEngine
    let message: UIMessage
    let onJump: (ChangeLink, [ChangeLink]) -> Void
    let onSplit: (String) -> Void

    private var targets: [ChangeLink] { message.links.compactMap { $0 } }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: .leading, spacing: 8) {
                if let thumb = message.imageThumb, let image = NSImage(data: thumb) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                if let note = message.fallbackNote {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Icon("warning", size: 12)
                        Text(note)
                    }
                    .font(FN.small)
                    .foregroundStyle(p.danger.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                }

                richText(message.content)
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .foregroundStyle(message.isError ? p.danger : p.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !message.filed.isEmpty {
                    FlowLayout(spacing: 6, alignment: .leading) {
                        ForEach(Array(message.filed.enumerated()), id: \.offset) { index, label in
                            if let link = message.links.indices.contains(index) ? message.links[index] : nil {
                                Button { onJump(link, targets) } label: {
                                    Chip(label)
                                }
                                .buttonStyle(.fn)
                                .help("Show this")
                            } else {
                                Chip(label)
                            }
                        }
                        if let first = targets.first {
                            Button { onJump(first, targets) } label: {
                                HStack(spacing: 4) {
                                    Text(targets.count == 1 ? "Show" : "Show changes (\(targets.count))")
                                    Icon("arrowRight", size: 13)
                                }
                                .font(FN.font(12, .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(p.accent, in: Capsule())
                            }
                            .buttonStyle(.fn)
                        }
                    }
                }

                if !message.sources.isEmpty {
                    sourceList
                }

                if message.origin != .cloud {
                    OnDeviceMark(origin: message.origin, name: message.answererName)
                } else if let name = message.answererName, engine.chatRunsOnDevice {
                    // With this Mac first, a cloud answer is the exception: say whose it is.
                    CloudMark(name: name)
                }

                if let offer = message.cloudOffer {
                    cloudQuestion(offer)
                }

                if message.webTopic != nil || message.canSaveAsNote {
                    FlowLayout(spacing: 6, alignment: .leading) {
                        if message.canSaveAsNote {
                            OfferButton(icon: "noteAdd", title: "Save as note",
                                        help: "Save this reply to Notes exactly as it is") {
                                assistant.saveAsNote(message.id)
                            }
                        }
                        if let topic = message.webTopic {
                            if engine.canSearchWeb {
                                OfferButton(icon: "sparkle", title: "Ideas from the web",
                                            help: "Search the web and suggest ideas here. Sends this note to Claude.",
                                            disabled: assistant.busy != nil) {
                                    Task { await assistant.searchWeb(topic) }
                                }
                            }
                            OfferButton(icon: "search", title: "Search the web",
                                        help: "Open a search for “\(topic.noteTitle)” in your browser") {
                                assistant.openWebSearch(topic)
                            }
                        }
                    }
                }

                if let txId = message.splitTxId {
                    Button { onSplit(txId) } label: {
                        HStack(spacing: 6) {
                            Icon("users", size: 14)
                            Text("Split this bill with someone?")
                        }
                        .font(FN.body)
                        .foregroundStyle(p.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                            .stroke(p.line, lineWidth: 1))
                    }
                    .buttonStyle(.fn)
                }
            }
            .padding(.horizontal, isUser ? 12 : 2)
            .padding(.vertical, isUser ? 8 : 2)
            .background(isUser ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Yours on the right, the assistant's across the panel.
            .frame(maxWidth: isUser ? 520 : .infinity, alignment: isUser ? .trailing : .leading)
            .transition(.move(edge: isUser ? .trailing : .leading).combined(with: .opacity))
        }
    }

    /// The end of a local reply, asked like a person would: "Want me to look
    /// this up online with OpenRouter?" Replying "yes" accepts; so does the link.
    private func cloudQuestion(_ offer: CloudOffer) -> some View {
        var line = AttributedString("Want me to ")
        var link = AttributedString("look this up online with \(offer.name)")
        link.link = URL(string: "fournotes-offer://cloud")
        link.foregroundColor = p.accent
        link.underlineStyle = .single
        line += link
        line += AttributedString("?")
        return Text(line)
            .font(.system(size: 15))
            .foregroundStyle(p.muted)
            .environment(\.openURL, OpenURLAction { _ in
                Task { await assistant.askCloud(offer) }
                return .handled
            })
            .help("Reply “yes”, or click. Sends this question and the notes it mentions to \(offer.name).")
            .transition(.opacity)
    }

    /// The pages a web answer cites, as links.
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(FN.font(11, .medium)).tracking(0.5)
                .foregroundStyle(p.faint)
            ForEach(message.sources, id: \.url) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Icon("link", size: 12)
                            Text(source.title).lineLimit(1)
                            Text(url.host() ?? "").foregroundStyle(p.faint).lineLimit(1)
                        }
                        .font(FN.small)
                        .foregroundStyle(p.accent)
                    }
                    .help(source.url)
                }
            }
        }
    }

    /// Models reply in Markdown, so it is parsed rather than shown raw.
    /// `inlineOnlyPreservingWhitespace` keeps the line breaks a reply relies on.
    private func richText(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return Text(text)
        }
        return Text(parsed)
    }
}

// MARK: - Bits

/// A next step offered under a reply: "Search the web".
private struct OfferButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let icon: String
    let title: String
    var help: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icon(icon, size: 14)
                Text(title)
            }
            .font(FN.font(13, .medium))
            .foregroundStyle(hovering ? p.text : p.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering ? p.hover : .clear, in: Capsule())
            .overlay(Capsule().stroke(p.line, lineWidth: 1))
            .contentShape(Capsule())
            .motion(hovering, Motion.quick)
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help)
        .onHover { hovering = $0 && !disabled }
    }
}

/// A quiet "On this Mac" mark: which replies Apple Intelligence worked out
/// locally, with the reason on hover. It replaces a sentence that used to be
/// appended to the reply — and then read back to the model as history.
private struct OnDeviceMark: View {
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
private struct CloudMark: View {
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

/// Today's starters: an icon and a word, on a soft pill.
private struct StarterChip: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Icon(icon, size: 15)
                Text(title)
            }
            .font(FN.font(14))
            .foregroundStyle(hovering ? p.text : p.muted)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(hovering ? p.hover.opacity(2) : p.panel.opacity(0.75),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(p.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
    }
}

private struct SuggestionChip: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(FN.body)
                .foregroundStyle(hovering ? p.text : p.muted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(hovering ? p.hover : .clear, in: Capsule())
                .overlay(Capsule().stroke(p.line, lineWidth: 1))
                .scaleEffect(hovering ? 1.02 : 1)
                .motion(hovering, Motion.quick)
                .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
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
