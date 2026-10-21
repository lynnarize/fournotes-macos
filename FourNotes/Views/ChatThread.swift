import AppKit
import SwiftUI

// The conversation, as on the web (assistant/Thread.tsx): your messages in bubbles on
// the right, replies across the width under the model's name. A new reply streams in a
// few words at a time with its newest line faded; what it filed, its sources and its
// actions (Copy, Retry, Save as note) follow once the text is all there. The list keeps
// to the newest line unless you scroll up, and then offers "Jump to latest".

/// Replies that arrived while a conversation was on screen, and so stream in once.
/// Anything already there when it opens is shown whole.
@MainActor
enum FreshReplies {
    static var ids = Set<UUID>()
}

struct ChatThread: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var assistant: Assistant
    let onJump: (ChangeLink, [ChangeLink]) -> Void
    let onSplit: (String) -> Void
    /// The panel's empty state offers a few questions; nil shows none.
    var onSuggest: ((String) -> Void)?

    @State private var position = ScrollPosition(edge: .bottom)
    /// Following the newest line. Scrolling up lets go; reaching the bottom takes hold again.
    @State private var stuck = true

    private struct Metrics: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
        var atBottom: Bool { offset + container >= content - 32 }
    }

    var body: some View {
        let messages = assistant.messages
        let lastReply = messages.last(where: { $0.role == .assistant })?.id

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if messages.isEmpty && assistant.busy == nil, let onSuggest {
                    EmptyChat(onSuggest: onSuggest)
                }
                ForEach(messages) { message in
                    Group {
                        if message.role == .user {
                            UserBubble(message: message)
                        } else {
                            ReplyView(message: message, isLast: message.id == lastReply,
                                      onJump: onJump, onSplit: onSplit)
                        }
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 12))
                            .combined(with: .scale(scale: 0.98, anchor: message.role == .user ? .bottomTrailing : .topLeading)),
                        removal: .opacity))
                }
                if let busy = assistant.busy {
                    Thinking(label: busy)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.list, value: messages)
            .animation(Motion.standard, value: assistant.busy)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: Metrics.self) {
            Metrics(offset: $0.contentOffset.y, content: $0.contentSize.height, container: $0.containerSize.height)
        } action: { old, new in
            if new.content != old.content || new.container != old.container {
                // The conversation grew (a reply streaming in) or the card resized:
                // keep to the newest line if we were on it.
                if stuck { position.scrollTo(edge: .bottom) }
            } else {
                // Only the offset moved: that was a scroll.
                stuck = new.atBottom
            }
        }
        .onChange(of: messages.count) { old, new in
            // Your own message always brings the newest line back.
            if new > old, messages.last?.role == .user {
                stuck = true
                withAnimation(Motion.standard) { position.scrollTo(edge: .bottom) }
            }
        }
        .overlay(alignment: .bottom) {
            if !stuck && !messages.isEmpty {
                JumpToLatest {
                    stuck = true
                    withAnimation(Motion.screen) { position.scrollTo(edge: .bottom) }
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(Motion.quick, value: stuck)
        .accessibilityLabel("Conversation")
    }
}

// MARK: - Messages

private struct UserBubble: View {
    @Environment(\.palette) private var p
    let message: UIMessage

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let thumb = message.imageThumb, let image = NSImage(data: thumb) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 176)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            }
            Text(message.content)
                .font(FN.font(15))
                .lineSpacing(3)
                .foregroundStyle(p.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(p.surfaceMuted, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 56)
    }
}

/// One reply: the model's name, the text (streaming in when it's new), then what it
/// filed, its sources and its actions.
private struct ReplyView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var assistant: Assistant
    @EnvironmentObject private var engine: AIEngine
    let message: UIMessage
    let isLast: Bool
    let onJump: (ChangeLink, [ChangeLink]) -> Void
    let onSplit: (String) -> Void

    /// How many words are showing while the reply streams in; nil once it's all there.
    @State private var shownWords: Int?
    @State private var copied = false

    private var revealing: Bool { shownWords != nil }
    private var targets: [ChangeLink] { message.links.compactMap { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Icon("sparkle", size: 13).foregroundStyle(p.foreground)
                Text(message.answererName ?? engine.route.label)
                if message.origin != .cloud {
                    OnDeviceMark(origin: message.origin, name: message.answererName)
                } else if let name = message.answererName, engine.chatRunsOnDevice {
                    // With this Mac first, a cloud answer is the exception: say whose it is.
                    CloudMark(name: name)
                }
            }
            .font(FN.font(12.5))
            .foregroundStyle(p.textSecondary)

            if let note = message.fallbackNote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Icon("warning", size: 12)
                    Text(note)
                }
                .font(FN.small)
                .foregroundStyle(p.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            if message.isError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Icon("warning", size: 15).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(message.content).textSelection(.enabled)
                }
                .font(FN.font(15))
                .foregroundStyle(p.danger)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Self.rich(shownText)
                    .font(FN.font(15))
                    .lineSpacing(4)
                    .foregroundStyle(p.foreground)
                    .tint(p.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .mask { revealMask }
            }

            if !revealing {
                Group {
                    if !message.filed.isEmpty { filedCards }
                    if let txId = message.splitTxId { splitOffer(txId) }
                    if !message.sources.isEmpty { sourceList }
                    if let offer = message.cloudOffer { cloudQuestion(offer) }
                    if message.webTopic != nil { webOffers }
                    actions
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.standard, value: revealing)
        .task {
            // Let the conversation record that this reply is new before looking.
            await Task.yield()
            if FreshReplies.ids.remove(message.id) != nil, !message.isError { await reveal() }
        }
    }

    // MARK: Streaming in

    private var words: [Substring] { message.content.split(separator: " ", omittingEmptySubsequences: false) }

    private var shownText: String {
        guard let shownWords else { return message.content }
        return Self.tidy(words.prefix(shownWords).joined(separator: " "))
    }

    /// The newest line fades out while words are still arriving.
    @ViewBuilder
    private var revealMask: some View {
        if revealing {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        } else {
            Rectangle()
        }
    }

    /// About a hundred words a second, in uneven steps, as a reply would arrive.
    private func reveal() async {
        let count = words.count
        guard count > 6, !Motion.reduce else { return }
        let step = max(3, Int((Double(count) / 74).rounded(.up)))
        var n = 0
        shownWords = 0
        while n < count {
            n = min(count, n + step + Int.random(in: 0...2))
            shownWords = n
            try? await Task.sleep(for: .milliseconds(34))
            if Task.isCancelled { break }
        }
        withAnimation(Motion.standard) { shownWords = nil }
    }

    /// Text cut mid-stream can leave "**" or "`" open, which would show as stray marks.
    static func tidy(_ text: String) -> String {
        var out = text
        if out.components(separatedBy: "**").count % 2 == 0 { out += "**" }
        if out.filter({ $0 == "`" }).count % 2 == 1 { out += "`" }
        return out
    }

    /// Models reply in Markdown, so it is parsed rather than shown raw.
    /// `inlineOnlyPreservingWhitespace` keeps the line breaks a reply relies on.
    static func rich(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return Text(text) }
        return Text(parsed)
    }

    // MARK: What it filed

    /// "📝 Note: Weekend trip" → a card: kind, title, and a check.
    private var filedCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(message.filed.enumerated()), id: \.offset) { index, label in
                let link = message.links.indices.contains(index) ? message.links[index] : nil
                FiledCard(label: label, link: link) { if let link { onJump(link, targets) } }
            }
        }
    }

    private func splitOffer(_ txId: String) -> some View {
        PillButton(icon: "users", title: "Split this bill with someone?") { onSplit(txId) }
    }

    /// The pages a web answer drew on.
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("From the web").font(FN.small).foregroundStyle(p.textMuted)
            ForEach(message.sources, id: \.url) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Icon("link", size: 12)
                            Text(source.title).underline(color: p.borderStrong).lineLimit(1)
                            Text(url.host() ?? "").foregroundStyle(p.textMuted).lineLimit(1)
                        }
                        .font(FN.font(12.5))
                        .foregroundStyle(p.textSecondary)
                        .frame(minHeight: 26)
                    }
                    .help(source.url)
                }
            }
        }
    }

    /// The end of a local reply, asked like a person would: "Want me to look this up
    /// online with OpenRouter?" Replying "yes" accepts; so does the link.
    private func cloudQuestion(_ offer: CloudOffer) -> some View {
        var line = AttributedString("Want me to ")
        var link = AttributedString("look this up online with \(offer.name)")
        link.link = URL(string: "fournotes-offer://cloud")
        link.foregroundColor = p.foreground
        link.underlineStyle = .single
        line += link
        line += AttributedString("?")
        return Text(line)
            .font(FN.font(15))
            .foregroundStyle(p.textSecondary)
            .environment(\.openURL, OpenURLAction { _ in
                Task { await assistant.askCloud(offer) }
                return .handled
            })
            .help("Reply “yes”, or click. Sends this question and the notes it mentions to \(offer.name).")
    }

    @ViewBuilder
    private var webOffers: some View {
        if let topic = message.webTopic {
            HStack(spacing: 6) {
                if engine.canSearchWeb {
                    PillButton(icon: "sparkle", title: "Ideas from the web") {
                        Task { await assistant.searchWeb(topic) }
                    }
                    .disabled(assistant.busy != nil)
                    .help("Search the web and suggest ideas here. Sends this note to Claude.")
                }
                PillButton(icon: "search", title: "Search the web") { assistant.openWebSearch(topic) }
                    .help("Open a search for “\(topic.noteTitle)” in your browser")
            }
        }
    }

    /// Copy, Retry (the newest reply), Save as note.
    private var actions: some View {
        HStack(spacing: 2) {
            ReplyAction(icon: copied ? "check" : "copy", title: nil, help: copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
            }
            if isLast, message.filed.isEmpty {
                ReplyAction(icon: "retry", title: "Retry", help: "Ask again") { Task { await assistant.retry() } }
                    .disabled(assistant.busy != nil)
            }
            if message.canSaveAsNote {
                ReplyAction(icon: "noteAdd", title: "Save as note", help: "Save this reply to Notes exactly as it is") {
                    assistant.saveAsNote(message.id)
                }
            }
        }
        .padding(.leading, -6)
    }
}

/// What a reply filed: kind and title, with a check; clicking shows it.
private struct FiledCard: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let label: String
    let link: ChangeLink?
    let action: () -> Void

    /// "📝 Note: Weekend trip" → ("Note", "Weekend trip").
    private var parts: (head: String, title: String) {
        var rest = Substring(label)
        if let first = rest.first, !first.isLetter && !first.isNumber {
            rest = rest.drop { !$0.isLetter && !$0.isNumber }
        }
        guard let colon = rest.firstIndex(of: ":") else { return ("Done", String(rest)) }
        return (String(rest[..<colon]), rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    private var icon: String {
        switch link?.kind {
        case .notes: return "fileText"
        case .todos: return "squareCheck"
        case .transactions: return "wallet"
        case .budget: return "target"
        default: return "check"
        }
    }

    var body: some View {
        let parts = parts
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Icon(icon, size: 14).foregroundStyle(p.foreground)
                    Text(parts.head).lineLimit(1)
                    Spacer(minLength: 4)
                    Icon("check", size: 14).foregroundStyle(p.success)
                }
                .font(FN.small)
                .foregroundStyle(p.textMuted)
                Text(parts.title)
                    .font(FN.font(13.5, .medium))
                    .foregroundStyle(p.foreground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(hovering && link != nil ? p.surfaceMuted : p.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hovering && link != nil ? p.border : p.borderSubtle, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .disabled(link == nil)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
        .help(link == nil ? "" : "Show it")
    }
}

/// A small action under a reply: an icon, with a word when it needs one.
private struct ReplyAction: View {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let icon: String
    let title: String?
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icon(icon, size: 14)
                if let title { Text(title) }
            }
            .font(FN.font(12.5))
            .foregroundStyle(hovering ? p.foreground : p.textSecondary)
            .padding(.horizontal, title == nil ? 0 : 9)
            .frame(minWidth: 28, minHeight: 28)
            .background(hovering ? p.hover : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 && enabled }
        .motion(hovering, Motion.quick)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// "✦ Thinking", with a light passing over the words.
private struct Thinking: View {
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String

    var body: some View {
        let words = label.hasSuffix("…") ? String(label.dropLast()) : label
        HStack(spacing: 8) {
            Icon("sparkle", size: 14)
                .foregroundStyle(p.foreground)
                .phaseAnimator(reduceMotion ? [false] : [false, true]) { icon, up in
                    icon.scaleEffect(up ? 1.12 : 0.9).rotationEffect(.degrees(up ? 14 : -8))
                } animation: { _ in .easeInOut(duration: 1.05) }
            Text(words)
                .foregroundStyle(p.textSecondary)
                .overlay {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2)
                        let x = t / 1.4 * 1.6 - 0.3
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: p.foreground, location: 0.5),
                                               .init(color: .clear, location: 1)],
                                       startPoint: UnitPoint(x: x - 0.3, y: 0.5),
                                       endPoint: UnitPoint(x: x + 0.3, y: 0.5))
                            .opacity(t < 1.4 ? 1 : 0)
                    }
                    .mask(Text(words))
                    .allowsHitTesting(false)
                }
        }
        .font(FN.font(15))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// "Jump to latest", over the bottom of the conversation.
private struct JumpToLatest: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icon("arrowDown", size: 13)
                Text("Jump to latest")
            }
            .font(FN.font(12.5))
            .foregroundStyle(hovering ? p.foreground : p.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .floating(p, radius: 15)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
    }
}

/// An empty conversation in the panel: what to ask, and a few to start with.
private struct EmptyChat: View {
    @Environment(\.palette) private var p
    let onSuggest: (String) -> Void

    private static let questions = [
        "What did I spend the most on this month?",
        "What's due this week?",
        "Remind me to pay rent on the 5th every month",
    ]

    var body: some View {
        VStack(spacing: 14) {
            Logo(size: 34)
            Text("Ask about your notes, tasks and spending, or tell me what to add.")
                .font(FN.font(14))
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(Self.questions, id: \.self) { q in
                    PillButton(title: q) { onSuggest(q) }
                }
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
