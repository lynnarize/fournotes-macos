import AppKit
import SwiftUI

// The composer, after Arc's AI composer, as on the web (assistant/Composer.tsx): a
// rounded field, and at its foot + (scan, record, paste), the model that answers, the
// microphone and send. "/" at the start of a line opens commands that start a request
// for you; "@" puts one of your notes into the message, and the assistant reads that
// note in full. Both lists open above the line: arrows move, Return or Tab inserts,
// Escape closes.

struct ChatComposer: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var engine: AIEngine
    @EnvironmentObject private var store: Store

    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    /// Today's composer floats over the page; in a card or the panel it rests on it.
    var floating = false
    let onSend: (String) -> Void

    @State private var active = 0
    /// The trigger the list was closed on (Escape, or a note just inserted). It stays
    /// closed until what's typed changes.
    @State private var dismissed: String?

    var body: some View {
        let trigger = SuggestTrigger.find(in: text)
        let options = trigger.map { SuggestOption.options(for: $0, notes: store.liveNotes) } ?? []
        let listOpen = !options.isEmpty && trigger?.raw != dismissed
        let shape = RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous)

        VStack(alignment: .leading, spacing: 2) {
            if assistant.recording {
                recordingBar
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(FN.font(15))
                .foregroundStyle(p.foreground)
                .lineLimit(1...8)
                .focused(focused)
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .onSubmit {
                    if listOpen { pick(options[min(active, options.count - 1)], trigger) } else { send() }
                }
                .onKeyPress(.downArrow) {
                    guard listOpen else { return .ignored }
                    active = (active + 1) % options.count
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard listOpen else { return .ignored }
                    active = (active - 1 + options.count) % options.count
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard listOpen, let trigger else { return .ignored }
                    pick(options[min(active, options.count - 1)], trigger)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard listOpen else { return .ignored }
                    dismissed = trigger?.raw
                    return .handled
                }
                .onChange(of: text) { _, _ in active = 0 }
                .accessibilityLabel("Message the assistant")

            HStack(spacing: 2) {
                plusMenu
                Spacer(minLength: 8)
                modelMark
                micButton
                sendButton
            }
        }
        .padding(10)
        .background {
            shape.fill(p.surface)
                .shadow(color: floating ? p.shadowStrong : .clear, radius: 24, y: 10)
                .shadow(color: floating ? p.shadow : .clear, radius: 5, y: 2)
        }
        .overlay(shape.strokeBorder(focused.wrappedValue ? p.borderStrong : p.border, lineWidth: 1))
        .motion(focused.wrappedValue, Motion.quick)
        .animation(Motion.standard, value: assistant.recording)
        // The list opens above the line being typed, over whatever is there: hung from
        // a line along the composer's top edge, so it grows upward.
        .overlay(alignment: .topLeading) {
            Color.clear
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    if listOpen, let trigger {
                        SuggestList(trigger: trigger, options: options, active: min(active, options.count - 1),
                                    onPick: { pick($0, trigger) }, onHover: { active = $0 })
                            .padding(.leading, 8)
                            .padding(.bottom, 8)
                            .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
        }
        .animation(Motion.quick, value: listOpen)
        .zIndex(2)
    }

    // MARK: - Parts

    private var recordingBar: some View {
        HStack(spacing: 8) {
            Circle().fill(p.danger).frame(width: 8, height: 8)
                .phaseAnimator(Motion.reduce ? [true] : [true, false]) { dot, on in dot.opacity(on ? 1 : 0.35) }
            Text("Recording").font(FN.font(13, .medium)).foregroundStyle(p.foreground)
            Text(transcriptLabel)
                .font(FN.font(13))
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            GhostButton(action: { assistant.stopRecording() }) { Text("Stop") }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
    }

    private var transcriptLabel: String {
        if !assistant.liveTranscript.isEmpty { return assistant.liveTranscript }
        if assistant.transcriptionUnavailable {
            return "Dictation is off, so this will be written up after you stop."
        }
        return "Listening… press stop when you're done."
    }

    private var plusMenu: some View {
        IconMenu("plus", size: 18, box: 32, help: "Add a photo, recording or text") {
            [.item("Scan a receipt or note…") { assistant.pickAndScan() },
             .item(assistant.recording ? "Stop recording" : "Record a voice note") {
                 assistant.recording ? assistant.stopRecording() : assistant.startRecording()
             },
             .item("Paste from the clipboard") {
                 if let clip = NSPasteboard.general.string(forType: .string) {
                     text = String(clip.prefix(2_000))
                     focused.wrappedValue = true
                 }
             }]
        }
        .disabled(assistant.busy != nil)
    }

    /// Which model answers, as the web's model chip. Changed in Settings.
    private var modelMark: some View {
        HStack(spacing: 5) {
            Icon("sparkle", size: 13).foregroundStyle(p.foreground)
            Text(engine.route.label).lineLimit(1)
        }
        .font(FN.font(12.5))
        .foregroundStyle(p.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .help("Answers come from \(engine.route.label). Change it in Settings → AI & API keys.")
    }

    private var micButton: some View {
        Group {
            if assistant.recording {
                Button { assistant.stopRecording() } label: {
                    Icon("stop", size: 14, weight: 2)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(p.danger, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.fn)
                .help("Stop and write it up")
                .accessibilityLabel("Stop recording")
            } else {
                IconButton("mic", size: 17, box: 32, help: "Record a voice note") { assistant.startRecording() }
                    .disabled(assistant.busy != nil)
            }
        }
    }

    /// Muted until there is something to send; a turning ring while a reply is coming.
    private var sendButton: some View {
        let busy = assistant.busy != nil
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: send) {
            ZStack {
                Circle().fill(busy || empty ? p.surfaceMuted : p.accent)
                if busy {
                    BusyRing(color: p.foreground)
                } else {
                    Icon("arrowUp", size: 16, weight: 2)
                        .foregroundStyle(empty ? p.textMuted : p.accentForeground)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.fn)
        .disabled(busy || empty)
        .motion(empty, Motion.quick)
        .help(busy ? (assistant.busy ?? "") : "Send")
        .accessibilityLabel(busy ? (assistant.busy ?? "Working") : "Send")
    }

    // MARK: - Actions

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, assistant.busy == nil else { return }
        text = ""
        dismissed = nil
        onSend(t)
    }

    /// Replaces what was typed after "/" or "@" with the choice.
    private func pick(_ option: SuggestOption, _ trigger: SuggestTrigger?) {
        guard let trigger else { return }
        text = String(text[..<trigger.start]) + option.apply
        active = 0
        // A note just inserted would match its own name again: keep the list shut.
        dismissed = option.isNote ? SuggestTrigger.find(in: text)?.raw : nil
        focused.wrappedValue = true
    }
}

/// A ring that turns: something is on its way.
struct BusyRing: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .onAppear {
                guard !Motion.reduce else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

// MARK: - "/" and "@"

/// What's being typed at the end of the text: "/rem" at the start of a line, or
/// "@wee" after a space.
struct SuggestTrigger: Equatable {
    enum Kind { case slash, at }
    let kind: Kind
    /// What follows the "/" or "@", lowercased.
    let query: String
    /// Where the "/" or "@" is.
    let start: String.Index
    /// The trigger as typed, "/rem": the list closed on it stays closed until it changes.
    let raw: String

    static func find(in text: String) -> SuggestTrigger? {
        if let range = text.range(of: "(^|\n)/[A-Za-z ]{0,20}$", options: .regularExpression) {
            let start = text[range].hasPrefix("\n") ? text.index(after: range.lowerBound) : range.lowerBound
            let raw = String(text[start...])
            return SuggestTrigger(kind: .slash, query: String(raw.dropFirst()).lowercased(), start: start, raw: raw)
        }
        if let range = text.range(of: "(^|\\s)@[^\n@]{0,40}$", options: .regularExpression) {
            let start = text[range.lowerBound] == "@" ? range.lowerBound : text.index(after: range.lowerBound)
            let raw = String(text[start...])
            return SuggestTrigger(kind: .at, query: String(raw.dropFirst()).lowercased(), start: start, raw: raw)
        }
        return nil
    }
}

struct SuggestOption: Identifiable, Equatable {
    let id: String
    let label: String
    let hint: String
    /// An icon name, or nil for a quick note's yellow dot.
    let icon: String?
    /// What replaces the trigger.
    let apply: String
    var isNote = false

    /// Each fills in the start of a request; sending it is still yours.
    static let commands: [SuggestOption] = [
        .init(id: "note", label: "Note", hint: "/note", icon: "noteAdd", apply: "Write a note about "),
        .init(id: "task", label: "Task", hint: "/task", icon: "todo", apply: "Add a task: "),
        .init(id: "spent", label: "Spent", hint: "/spent", icon: "receipt", apply: "Spent "),
        .init(id: "remind", label: "Remind", hint: "/remind", icon: "bell", apply: "Remind me to "),
        .init(id: "plan", label: "Plan my day", hint: "/plan", icon: "target", apply: "What should I focus on today?"),
        .init(id: "summarize", label: "Summarize", hint: "/summarize", icon: "fileText", apply: "Summarize "),
    ]

    static func options(for trigger: SuggestTrigger, notes: [Note]) -> [SuggestOption] {
        switch trigger.kind {
        case .slash:
            return commands.filter { $0.id.hasPrefix(trigger.query) || $0.label.lowercased().hasPrefix(trigger.query) }
        case .at:
            let query = trigger.query.trimmingCharacters(in: .whitespaces)
            return notes
                .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
                    && (query.isEmpty || $0.title.lowercased().contains(query)) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(6)
                .map { note in
                    let title = note.title.trimmingCharacters(in: .whitespaces)
                    let quick = QuickNote.isQuick(note)
                    return SuggestOption(id: note.id, label: title, hint: quick ? "Quick note" : "Note",
                                         icon: quick ? nil : "fileText", apply: "@\(title) ", isNote: true)
                }
        }
    }
}

/// The list, above the line being typed.
private struct SuggestList: View {
    @Environment(\.palette) private var p
    let trigger: SuggestTrigger
    let options: [SuggestOption]
    let active: Int
    let onPick: (SuggestOption) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(trigger.kind == .slash ? "Commands" : "Your notes")
                .font(FN.small)
                .foregroundStyle(p.textMuted)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button { onPick(option) } label: {
                    HStack(spacing: 10) {
                        if let icon = option.icon {
                            Icon(icon, size: 15).foregroundStyle(p.textSecondary)
                        } else {
                            Circle().fill(p.noteYellow).frame(width: 8, height: 8).frame(width: 15)
                        }
                        Text(option.label).font(FN.font(13)).foregroundStyle(p.foreground).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(option.hint).font(FN.small).foregroundStyle(p.textMuted).lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(index == active ? p.accentSubtle : .clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { onHover(index) } }
                .accessibilityAddTraits(index == active ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(width: 320)
        .floating(p, radius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(trigger.kind == .slash ? "Commands" : "Your notes")
    }
}
