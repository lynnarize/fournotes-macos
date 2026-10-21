import AppKit
import SwiftUI

// The note editor: header actions, the formatting toolbar, the title, the
// writing surface, and the footer with tags, reminders and linked items.
// Ported from src/components/notes/NoteEditor.tsx.

private let FONTS: [(label: String, value: String)] = [
    ("Sans Serif", ""),
    ("Serif", "Georgia"),
    ("Monospace", "Menlo"),
    ("Rounded", RichTextController.roundedFamily),
]

private let SIZES: [CGFloat] = [12, 14, 16, 18, 20, 24, 30]

private let TEXT_COLORS: [(label: String, value: String)] = [
    ("Default", ""), ("Gray", "#787774"), ("Red", "#d4351c"), ("Orange", "#b85c00"),
    ("Yellow", "#946b00"), ("Green", "#0f7b6c"), ("Blue", "#2f6fdd"),
    ("Purple", "#9065b0"), ("Pink", "#c14c8a"),
]

private let HIGHLIGHTS: [(label: String, value: String)] = [
    ("None", ""), ("Yellow", "#fde68a"), ("Green", "#bbf7d0"), ("Blue", "#bfdbfe"),
    ("Pink", "#fbcfe8"), ("Purple", "#ddd6fe"), ("Orange", "#fed7aa"),
]

/// Where a note came from, when it was not typed here.
private let SOURCE_NAME: [NoteSource: String] = [
    .chat: "Written by the assistant", .ocr: "Scanned", .recording: "Voice recording", .share: "Shared",
]

private extension String {
    /// "road-trip" -> "Road-trip": tags are stored lower case, shown like the
    /// reference's chips.
    var capitalizedTag: String { prefix(1).uppercased() + dropFirst() }
}

private extension WriteTask {
    /// What the result is called in the preview card.
    var result: String {
        switch self {
        case .summarize: return "Summary"
        case .improve: return "Improved writing"
        case .fix: return "Corrected text"
        case .shorter: return "Shorter version"
        case .continue: return "Continuation"
        }
    }
}

/// A model's rewrite, shown for review before it touches the note.
private struct AISuggestion {
    let task: WriteTask
    let text: String
    /// The selection it was made from, or nil for the whole note.
    let range: NSRange?
}

struct NoteEditorView: View {
    @Environment(\.palette) private var p
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Navigation
    @EnvironmentObject private var toasts: ToastCenter
    @EnvironmentObject private var engine: AIEngine

    let note: Note
    var listHidden: Bool
    var onToggleList: () -> Void
    var focusMode: Bool
    var onToggleFocus: () -> Void

    @StateObject private var controller = RichTextController()
    @State private var attributed = NSAttributedString()
    @State private var title = ""
    @State private var saving = false
    @State private var aiRunning: WriteTask?
    @State private var suggestion: AISuggestion?
    @State private var tagDraft: String?
    @State private var showLinkSheet = false
    @State private var linkURL = ""
    @State private var showReminderPicker = false
    @State private var reminderAt = Date()
    @State private var loadedNoteId = ""
    /// The web editor's HTML the open document was built from, to notice a
    /// formatting-only change arriving from the web app.
    @State private var loadedHTML: String?
    @State private var pendingSave: Task<Void, Never>?
    /// The formatting toolbar shows every tool rather than one line of them.
    @AppStorage("fournotes.toolbarExpanded") private var toolbarExpanded = false
    /// This editor's entry in PendingWrites, so quitting writes what's waiting.
    @State private var writeId = UUID()

    private var linkedTodos: [Todo] { store.liveTodos.filter { $0.noteId == note.id } }
    private var linkedTxs: [Transaction] { store.liveTransactions.filter { $0.noteId == note.id } }

    var body: some View {
        // A flat pane: breadcrumb, the formatting toolbar along the top, then
        // the title and the note's properties, then the writing.
        VStack(spacing: 0) {
            header
            // Across the pane, as on the web: the header is a bar, not a section.
            Rectangle().fill(p.borderSubtle).frame(height: 1)
            toolbar
                .padding(.top, 12)
            writingArea
            footer
        }
        .background(p.bg)
        .overlay(alignment: .topLeading) { slashMenu }
        .onAppear { controller.onSlash = { runSlash($0) } }
        .motion(focusMode, Motion.screen)
        .background {
            // Escape leaves focus mode, as it does on the web — unless it is
            // closing the tag field.
            if focusMode && tagDraft == nil {
                Button("Exit focus mode", action: onToggleFocus)
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: note.id) { _, _ in load() }
        .onChange(of: note.updatedAt) { _, _ in reloadIfChangedElsewhere() }
        .fnSheet(isPresented: $showLinkSheet) { linkSheet }
        .fnSheet(isPresented: $showReminderPicker) { reminderPicker }
    }

    // MARK: - The "/" menu

    /// The card under the caret (above it near the bottom of the window), over everything.
    private var slashMenu: some View {
        GeometryReader { geo in
            if let s = controller.slash {
                let frame = geo.frame(in: .global)
                let height = CGFloat(min(320, s.commands.count * 50) + 86)
                let below = s.caret.maxY - frame.minY + 6
                let above = s.caret.minY - frame.minY - height - 6
                let y = below + height > geo.size.height - 8 && above > 8 ? above : below
                let x = min(max(8, s.caret.minX - frame.minX - 18), geo.size.width - 328)
                SlashMenuView(commands: s.commands, active: s.active,
                              onPick: { controller.runSlash($0) },
                              onHover: { controller.hoverSlash($0) })
                    .offset(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
            }
        }
        .animation(Motion.quick, value: controller.slash == nil)
    }

    /// What each "/" command does with the line it was typed on.
    private func runSlash(_ command: SlashCommand) {
        let line = controller.currentLineText
        let needLine = { toasts.push("Type something on this line first, then use the command.", tone: .error) }
        switch command {
        case .todo:
            guard !line.isEmpty else { return needLine() }
            store.addTodo { $0.title = line; $0.noteId = note.id }
            if !controller.state.isChecklist { controller.toggleChecklist() }
            toasts.push("✅ Task added and linked: \(line)")
        case .remind:
            guard !line.isEmpty else { return needLine() }
            let iso = DateKit.iso(Self.tomorrowAtNine)
            store.addTodo { $0.title = line; $0.noteId = note.id; $0.dueAt = iso; $0.remindAt = iso }
            controller.insertOnLine(" ⏰", atEnd: true)
            if !controller.state.isChecklist { controller.toggleChecklist() }
            toasts.push("⏰ Reminder \(Fmt.due(iso)): \(line)")
        case .expense:
            guard let amount = Money.parse(line), amount > 0 else {
                toasts.push("Add an amount on the line, like “lunch 45k”.", tone: .error)
                return
            }
            let merchant = line
                .replacingOccurrences(of: #"(?i)(rp|idr)?\.?\s*\d[\d.,]*\s*(rb|ribu|k|jt|juta)?\b"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let tx = store.addTransaction {
                $0.merchant = merchant.isEmpty ? "Expense" : merchant
                $0.amount = amount
                $0.category = Wallet.guessCategory(line)
                $0.noteId = note.id
            }
            controller.insertOnLine("💸 ", atEnd: false)
            toasts.push("💸 Logged \(Money.format(amount, tx.currency)) (\(tx.category))")
        case .sticky:
            guard !line.isEmpty else { return needLine() }
            store.addNote { QuickNote.apply(line, to: &$0) }
            toasts.push("📌 Saved as a quick note on Today")
        case .ask:
            guard !line.isEmpty else { return needLine() }
            let question = "\(line)\n\n(Context: from my note “\(displayTitle)”)"
            Task { _ = await AppModel.shared.assistant.send(question) }
        case .checklist: controller.toggleChecklist()
        case .bullet: controller.toggleBulletList()
        case .numbered: controller.toggleNumberedList()
        case .heading: controller.setHeading(2)
        case .quote: controller.toggleQuote()
        case .divider: controller.insertDivider()
        case .date: controller.insertText(todayString)
        case .time: controller.insertText(Fmt.time(Date()))
        }
    }

    // MARK: - Loading and saving

    private func load() {
        guard loadedNoteId != note.id else { return }
        loadedNoteId = note.id
        title = note.title
        attributed = Self.document(for: note)
        loadedHTML = note.html
        suggestion = nil
        tagDraft = nil
    }

    /// Sync, the assistant or the edge dock changed the open note. The editor
    /// used to go on showing what it first loaded — and the next keystroke
    /// saved that over the newer version. Edits still waiting to be saved win:
    /// they are newer than anything that has arrived.
    private func reloadIfChangedElsewhere() {
        guard loadedNoteId == note.id, !saving else { return }
        if title != note.title { title = note.title }
        let textChanged = NoteDocument.plainText(from: attributed) != note.content
        // This editor clears the HTML when it saves, so HTML that differs from
        // what was loaded was written by the web app.
        let formattingChanged = note.html != nil && note.html != loadedHTML
        guard textChanged || formattingChanged else { return }
        attributed = Self.document(for: note)
        loadedHTML = note.html
    }

    /// The note as something editable. A note this app has opened before has
    /// its own representation; one from the web app has HTML; anything else is
    /// rebuilt from the plain text, which carries the structure.
    static func document(for note: Note) -> NSAttributedString {
        NoteDocument.spaced(NoteDocument.usingBodyFont(unspacedDocument(for: note)))
    }

    private static func unspacedDocument(for note: Note) -> NSAttributedString {
        if let data = note.richText, let restored = NoteDocument.unarchive(data) {
            return NoteDocument.removingLiteralListMarkers(restored)
        }
        if let html = note.html, !html.isEmpty {
            // The web app writes both forms; an HTML-only note is read as best AppKit can.
            if note.content.isEmpty, let imported = NoteDocument.attributed(fromHTML: html) {
                return NoteDocument.removingLiteralListMarkers(imported)
            }
            return NoteDocument.attributed(fromHTML: html, plain: note.content)
        }
        return NoteDocument.attributed(fromPlainText: note.content)
    }

    private func save(_ next: NSAttributedString) {
        saving = true
        pendingSave?.cancel()
        // Writing is debounced off the keystroke path: it used to serialise the
        // whole document to HTML and regex every line on every character typed.
        PendingWrites.hold(writeId) { commit(next) }
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit(next)
        }
    }

    private func commit(_ document: NSAttributedString) {
        PendingWrites.release(writeId)
        pendingSave?.cancel()
        let plain = NoteDocument.plainText(from: document)
        // Only keep the native form when it carries something the plain text
        // cannot: bold, colour, a link. Structure round-trips as text.
        let archive = NoteDocument.hasInlineFormatting(document)
            ? NoteDocument.archive(document)
            : nil

        store.updateNote(note.id) {
            $0.content = plain
            $0.richText = archive
            // The HTML a note came with from the web app is now out of date.
            // Left in place, reopening the note loaded it again and the next
            // keystroke wrote the old text back. It is regenerated on export.
            $0.html = nil
        }
        syncLinkedTodos(plain)
        saving = false
    }

    /// Ticking a checklist box keeps a linked to-do of the same name in step.
    private func syncLinkedTodos(_ plain: String) {
        let states = NoteText.taskStates(plain)
        guard !states.isEmpty else { return }
        for todo in linkedTodos {
            let key = todo.title.trimmingCharacters(in: .whitespaces)
            if let checked = states[key], checked != todo.done {
                store.toggleTodo(todo.id, done: checked)
            }
        }
    }

    private func saveTitle(_ next: String) {
        store.updateNote(note.id) { $0.title = next.replacingOccurrences(of: "\n", with: " ") }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            if !focusMode {
                IconButton(listHidden ? "collapseRight" : "collapseLeft", size: 20, box: 30,
                           help: listHidden ? "Show note list" : "Hide note list", action: onToggleList)
            }
            IconButton(focusMode ? "shrink" : "expand", size: 18, box: 30,
                       help: focusMode ? "Exit focus mode (Esc)" : "Focus mode", action: onToggleFocus)

            // Where you are, as on the web: muted, the note's name a shade stronger.
            HStack(spacing: 6) {
                Text("Notes").foregroundStyle(p.faint)
                Icon("chevron", size: 12).foregroundStyle(p.faint)
                Text(title.isEmpty ? "Untitled" : title).foregroundStyle(p.muted)
            }
            .font(FN.body)
            .lineLimit(1)
            .padding(.leading, 6)

            Spacer(minLength: 8)

            // Whether it's saved, beside Share, where the web app says it.
            HStack(spacing: 5) {
                if saving {
                    Text("Saving…").transition(.opacity)
                } else {
                    Icon("check", size: 13)
                    Text("Saved").transition(.opacity)
                }
            }
            .font(FN.small)
            .foregroundStyle(p.faint)
            .fixedSize()
            .padding(.trailing, 6)
            .animation(Motion.standard, value: saving)
            .accessibilityElement(children: .combine)

            SecondaryButton(title: "Share", icon: "share", action: share)
                .fixedSize()

            IconMenu("more", size: 20, help: "More actions") {
                [
                    .item("Copy note text", action: copyText),
                    .item(EdgeStickies.shared.isStuck(note.id) ? "Take off screen edge" : "Stick to screen edge",
                          action: { EdgeStickies.shared.toggle(note.id) }),
                    .item("Duplicate", action: duplicate),
                    .item("Download as text…", action: downloadText),
                    .item("Print…", action: printNote),
                    .divider,
                    .item("Delete note", destructive: true, action: deleteNote),
                ]
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    /// A hairline between sections, inset to the content like the reference.
    private var rule: some View {
        Rectangle().fill(p.line).frame(height: 1).padding(.horizontal, 36)
    }

    /// The text column's width and where it sits: against the left edge beside
    /// the list, centred when the editor has the window to itself.
    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: focusMode ? 800 : 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: focusMode ? .center : .leading)
            .padding(.horizontal, focusMode ? 48 : 36)
    }

    // MARK: - Title and properties

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f
    }()

    private func stamp(_ iso: String) -> String {
        DateKit.date(iso).map { Self.stamp.string(from: $0) } ?? ""
    }

    private var titleBlock: some View {
        column {
            VStack(alignment: .leading, spacing: 0) {
                // The web app's display face, not a serif: the two now read alike.
                CommittedField(placeholder: "Untitled", value: note.title,
                               font: FN.display(36), axis: .vertical,
                               onCommit: saveTitle)
                    .tracking(FN.displayTracking(36))
                    .foregroundStyle(p.text)
                    .padding(.bottom, 16)

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                    // Focus mode keeps only what you might still change.
                    if !focusMode {
                        property("Created") { Text(stamp(note.createdAt)).foregroundStyle(p.muted).help(stamp(note.createdAt)) }
                        if let source = SOURCE_NAME[note.source] {
                            property("Source") { Text(source) }
                        }
                    }
                    property("Tags") {
                        FlowLayout(spacing: 8, alignment: .leading) {
                            ForEach(tags, id: \.self) { tag in tagChip(tag) }
                            tagControl
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // What the note made, among its properties as on the web.
                    if !linkedTodos.isEmpty || !linkedTxs.isEmpty {
                        property("Linked") { linkedChips }
                    }
                }
                .animation(Motion.standard, value: focusMode)
            }
            .padding(.top, 22)
            .padding(.bottom, 18)
        }
    }

    private func property<Value: View>(_ label: String, @ViewBuilder _ value: () -> Value) -> some View {
        GridRow {
            Text(label)
                .font(FN.body)
                .foregroundStyle(p.faint)
                .frame(width: 104, alignment: .leading)
            value()
                .font(FN.body)
                .foregroundStyle(p.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Toolbar

    private var state: RichTextState { controller.state }

    /// The formatting tools, on one line unless the toolbar is expanded. The
    /// groups run from the most used to the least, so the line holds the
    /// ones that matter; the toggle at its end shows the rest on lines below
    /// it, and hides them again. It is only there when they don't all fit.
    private var toolbar: some View {
        ToolbarLayout(expanded: toolbarExpanded) {
            HStack(spacing: 2) { insertMenu }.fixedSize()
            group {
                IconMenu("textSize", size: 19, help: "Text style") { textStyleEntries }
                TextMenu(title: fontLabel, width: 92, help: "Font") { fontEntries }
                TextMenu(title: "\(Int(state.fontSize))", width: 44, help: "Font size") { sizeEntries }
            }
            group {
                tb("bold", "Bold (⌘B)", active: state.bold) { controller.toggleBold() }
                tb("italic", "Italic (⌘I)", active: state.italic) { controller.toggleItalic() }
                tb("underline", "Underline (⌘U)", active: state.underline) { controller.toggleUnderline() }
                tb("strike", "Strikethrough", active: state.strikethrough) { controller.toggleStrikethrough() }
            }
            group {
                tb("listBullet", "Bulleted list", active: state.isBulletList) { controller.toggleBulletList() }
                tb("listOrdered", "Numbered list", active: state.isNumberedList) { controller.toggleNumberedList() }
                tb("checklist", "Checklist", active: state.isChecklist) { controller.toggleChecklist() }
            }
            group { aiMenu }
            group {
                // Left is lit only once chosen, not on every ordinary paragraph.
                tb("alignLeft", "Left-align", active: state.alignment == .left) { controller.setAlignment(.left) }
                tb("alignCenter", "Center-align", active: state.alignment == .center) { controller.setAlignment(.center) }
                tb("alignRight", "Right-align", active: state.alignment == .right) { controller.setAlignment(.right) }
            }
            group {
                tb("link", "Insert link") { showLinkSheet = true }
                tb("calendar", "Insert today's date") { controller.insertText(todayString) }
                tb("mic", "Dictate") { controller.startDictation() }
            }
            group {
                tb("undo", "Undo (⌘Z)", enabled: state.canUndo) { controller.undo() }
                tb("redo", "Redo (⇧⌘Z)", enabled: state.canRedo) { controller.redo() }
            }
            group {
                tb("indent", "Indent (Tab)", enabled: state.inList) { controller.shiftDepth(1) }
                tb("outdent", "Outdent (⇧Tab)", enabled: state.inList) { controller.shiftDepth(-1) }
            }
            group {
                tb("superscript", "Superscript", active: state.superscript) { controller.toggleSuperscript() }
                tb("subscript", "Subscript", active: state.subscript) { controller.toggleSubscript() }
            }
            group {
                IconMenu("palette", size: 19,
                         tone: state.color.isEmpty ? nil : NSColor(hex: state.color).map { Color(nsColor: $0) },
                         help: "Font colour") { colorEntries }
                IconMenu("highlight", size: 19, help: "Highlight") { highlightEntries }
                tb("eraser", "Clear formatting") { controller.clearFormatting() }
            }
            // Last: the layout keeps it at the end of the first line.
            IconButton("chevronDown", size: 16, box: 30,
                       help: toolbarExpanded ? "Show fewer tools" : "Show all tools") {
                toolbarExpanded.toggle()
            }
            .rotationEffect(.degrees(toolbarExpanded ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tools that don't fit wait past the trailing edge, out of sight.
        .clipped()
        // One slim pill, as the web app's toolbar: a rounded card once it opens to more lines.
        .background(p.surface, in: RoundedRectangle(cornerRadius: toolbarExpanded ? 22 : 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: toolbarExpanded ? 22 : 26, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .frame(maxWidth: focusMode ? 800 : 760)
        .frame(maxWidth: .infinity, alignment: focusMode ? .center : .leading)
        .padding(.horizontal, focusMode ? 48 : 36)
        .animation(Motion.standard, value: toolbarExpanded)
    }

    /// A run of related tools that wraps as one piece, set off from the one before by a hairline.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            Rectangle().fill(p.border).frame(width: 1, height: 20).padding(.horizontal, 5)
            content()
        }
        .fixedSize()
    }

    private var fontEntries: [MenuEntry] {
        FONTS.map { font in
            .item(font.label, checked: state.fontFamily == font.value) { controller.setFontFamily(font.value) }
        }
    }

    private var sizeEntries: [MenuEntry] {
        SIZES.map { size in
            .item("\(Int(size))", checked: Int(state.fontSize) == Int(size)) { controller.setFontSize(size) }
        }
    }

    private func tb(_ icon: String, _ label: String, active: Bool = false, enabled: Bool = true,
                    action: @escaping () -> Void) -> some View {
        IconButton(icon, size: 18, box: 32, tone: active ? p.foreground : nil, help: label, action: action)
            .background(active ? p.accentSubtle : .clear, in: Circle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
    }

    private var insertMenu: some View {
        MenuButton(help: "Insert") {
            [
                .item("Checklist") { controller.toggleChecklist() },
                .item("Bulleted list") { controller.toggleBulletList() },
                .item("Numbered list") { controller.toggleNumberedList() },
                .item("Quote") { controller.toggleQuote() },
                .item("Code block") { controller.toggleCode() },
                .item("Divider") { controller.insertDivider() },
                .divider,
                .item("Link…") { showLinkSheet = true },
                .item("Today's date") { controller.insertText(todayString) },
                .item("Current time") { controller.insertText(Fmt.time(Date())) },
            ]
        } label: {
            Icon("plus", size: 18)
                .foregroundStyle(p.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }

    private var aiMenu: some View {
        MenuButton(help: "AI writing help") {
            let scope = controller.selection == nil ? "For this note" : "For the selected text"
            var entries: [MenuEntry] = [.header(scope)]
            entries += WriteTask.allCases.map { task in
                .item(task.label, enabled: aiRunning == nil) { Task { await runAI(task) } }
            }
            entries += [
                .divider,
                .item("Turn into to-dos…") {
                    guard !controller.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        toasts.push("Write something first.", tone: .error)
                        return
                    }
                    askAssistant("Turn the action items in my note “\(displayTitle)” into to-dos")
                },
                .item("Ask the assistant…") { askAssistant("About my note “\(displayTitle)”: ") },
            ]
            return entries
        } label: {
            HStack(spacing: 5) {
                if aiRunning == nil {
                    Icon("sparkle", size: 18).foregroundStyle(p.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Ask AI").font(FN.body).foregroundStyle(p.text)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
    }

    private var textStyleEntries: [MenuEntry] {
        let normal = state.headingLevel == nil && !state.isQuote && !state.isCode
        return [
            .item("Normal text", checked: normal) { controller.setHeading(nil) },
            .item("Heading 1", checked: state.headingLevel == 1) { controller.setHeading(1) },
            .item("Heading 2", checked: state.headingLevel == 2) { controller.setHeading(2) },
            .item("Heading 3", checked: state.headingLevel == 3) { controller.setHeading(3) },
            .item("Quote", checked: state.isQuote) { controller.toggleQuote() },
            .item("Code", checked: state.isCode) { controller.toggleCode() },
        ]
    }

    private var fontLabel: String {
        FONTS.first { $0.value == state.fontFamily }?.label ?? "Custom"
    }

    private var colorEntries: [MenuEntry] {
        let color = state.color.lowercased()
        return TEXT_COLORS.map { c in
            .item(c.label, checked: c.value.isEmpty ? !TEXT_COLORS.contains { !$0.value.isEmpty && $0.value == color }
                                                    : color == c.value,
                  swatch: c.value.isEmpty ? .labelColor : NSColor(hex: c.value)) {
                controller.setColor(c.value)
            }
        }
    }

    private var highlightEntries: [MenuEntry] {
        let highlight = state.highlight.lowercased()
        return HIGHLIGHTS.map { c in
            .item(c.label, checked: highlight == c.value,
                  swatch: c.value.isEmpty ? nil : NSColor(hex: c.value)) {
                controller.setHighlight(c.value)
            }
        }
    }

    // MARK: - Writing area

    /// The title, the properties and the writing scroll as one: the header is
    /// drawn inside the text's own scroll view, above the text.
    private var writingArea: some View {
        RichTextEditor(attributed: $attributed, controller: controller, onTextChange: save,
                       column: TextColumn(maxWidth: focusMode ? 800 : 760, padding: focusMode ? 48 : 36,
                                          centered: focusMode),
                       header: editorHeader)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What sits above the text: title, properties, and any AI work.
    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
            column {
                VStack(alignment: .leading, spacing: 0) {
                    if let task = aiRunning {
                        HStack(spacing: 8) {
                            Icon("sparkle", size: 15).foregroundStyle(p.accent)
                            Text("\(task.label)…")
                        }
                        .font(FN.body)
                        .foregroundStyle(p.muted)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.line, lineWidth: 1))
                        .padding(.bottom, 12)
                    }
                    if let suggestion {
                        suggestionCard(suggestion)
                            .padding(.bottom, 12)
                    }
                }
                .padding(.top, 20)
            }
        }
        .background(p.bg)
        // A separate hierarchy: it needs the app's objects handed over.
        .environmentObject(store)
        .environmentObject(nav)
        .environmentObject(toasts)
        .environmentObject(engine)
    }

    /// A model's rewrite, for review before it touches the note.
    private func suggestionCard(_ s: AISuggestion) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Icon("sparkle", size: 15).foregroundStyle(p.accent)
                Text(s.task.result).font(FN.bodyMedium).foregroundStyle(p.text)
                Text(s.range == nil ? "of this note" : "of the selected text")
                    .font(FN.small).foregroundStyle(p.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider().overlay(p.line)

            ScrollView {
                Text(s.text)
                    .font(FN.body)
                    .foregroundStyle(p.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(p.line)

            HStack(spacing: 8) {
                let addsBelow = s.task == .summarize || s.task == .continue
                if addsBelow {
                    PrimaryButton(title: s.task == .continue ? "Add to note" : "Insert below") { applyAI(s, replace: false) }
                    if s.task == .summarize {
                        GhostButton(action: { applyAI(s, replace: true) }) { Text("Replace") }
                    }
                } else {
                    PrimaryButton(title: "Replace") { applyAI(s, replace: true) }
                    GhostButton(action: { applyAI(s, replace: false) }) { Text("Insert below") }
                }
                GhostButton(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.text, forType: .string)
                    toasts.push("Copied")
                }) { Text("Copy") }
                Spacer()
                GhostButton(action: { suggestion = nil }) { Text("Discard") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(p.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(p.line, lineWidth: 1))
    }

    private var linkedChips: some View {
        FlowLayout(spacing: 6, alignment: .leading) {
            ForEach(linkedTodos) { todo in
                Button { nav.open(ChangeLink(kind: .todos, id: todo.id)) } label: {
                    Chip(tone: nil) {
                        Icon("todo", size: 11)
                        Text(todo.title.isEmpty ? "Untitled task" : todo.title)
                            .strikethrough(todo.done)
                    }
                }
                .buttonStyle(.fn)
                .help("Open in To-Do")
            }
            ForEach(linkedTxs) { tx in
                Button { nav.open(ChangeLink(kind: .transactions, id: tx.id)) } label: {
                    Chip(tone: nil) {
                        Icon("finance", size: 11)
                        Text("\(tx.merchant) · \(Money.format(tx.amount, tx.currency, compact: true))")
                    }
                }
                .buttonStyle(.fn)
                .help("Open in Finance")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var tags: [String] { NoteText.tags(note.tags) }

    private var wordCount: Int {
        attributed.string.split { $0.isWhitespace || $0.isNewline }
            .filter { $0 != "\u{FFFC}" }
            .count
    }

    /// Length and age on the left; reminders and the assistant on the right, as on
    /// the web. The far right is the assistant's: its "Ask Four Notes" pill sits
    /// over that corner, so the buttons stop short of it.
    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(p.borderSubtle).frame(height: 1)
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(wordCount) word\(wordCount == 1 ? "" : "s")").monospacedDigit()
                    Text("·")
                    Text("Edited \(Fmt.relative(note.updatedAt))")
                }
                .font(FN.small)
                .foregroundStyle(p.faint)
                .lineLimit(1)
                .fixedSize()

                Spacer(minLength: 8)

                MenuButton(help: "Remind me about this note", align: .trailing) {
                    [
                        .header("Remind me about this note"),
                        .item("In an hour") { setReminder(hours: 1) },
                        .item("Tomorrow at 9:00") { setReminder(hours: 24) },
                        .item("Next week") { setReminder(hours: 24 * 7) },
                        .divider,
                        .item("Pick a date and time…") {
                            reminderAt = Self.tomorrowAtNine
                            showReminderPicker = true
                        },
                    ]
                } label: {
                    HStack(spacing: 6) {
                        Icon("bell", size: 15)
                        Text("Remind me").font(FN.small)
                    }
                    .foregroundStyle(p.muted)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .fixedSize()

                SecondaryButton(title: "Ask about this note", icon: "sparkle") {
                    askAssistant("About my note “\(displayTitle)”: ")
                }
                .fixedSize()
            }
            .padding(.leading, 24)
            .padding(.trailing, 196)
            .frame(minHeight: 52)
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag.capitalizedTag).lineLimit(1)
            Button { removeTag(tag) } label: {
                Icon("x", size: 9)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.fn)
            .help("Remove tag")
            .accessibilityLabel("Remove tag \(tag)")
        }
        .font(FN.font(12.5))
        .foregroundStyle(p.textSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(p.surfaceMuted, in: Capsule())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    @ViewBuilder
    private var tagControl: some View {
        if tagDraft != nil {
            TagField(draft: $tagDraft, addTag: addTag)
        } else {
            HoverRow(cornerRadius: 5) { hovering in
                Button { tagDraft = "" } label: {
                    HStack(spacing: 6) {
                        Icon("plus", size: 12)
                        Text("Add tag")
                    }
                    .font(FN.font(12.5))
                    .foregroundStyle(hovering ? p.foreground : p.textMuted)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .overlay(Capsule().strokeBorder(p.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.fn)
                .accessibilityLabel("Add tag")
            }
        }
    }

    private func addTag(_ raw: String) {
        guard let tag = NoteText.tag(raw) else { return }
        store.updateNote(note.id) { n in
            var cleaned = NoteText.tags(n.tags)
            if !cleaned.contains(tag) { cleaned.append(tag) }
            n.tags = cleaned
        }
    }

    private func removeTag(_ tag: String) {
        store.updateNote(note.id) { n in
            // Also drops any spelling of it that cleans to the same tag.
            n.tags = NoteText.tags(n.tags).filter { $0 != tag }
        }
    }

    private var reminderPicker: some View {
        SheetFrame(title: "Remind me about this note", width: 340) {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("", selection: $reminderAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
            HStack {
                Spacer()
                GhostButton(action: { showReminderPicker = false }) { Text("Cancel") }
                PrimaryButton(title: "Set reminder") {
                    showReminderPicker = false
                    setReminder(at: reminderAt)
                }
            }
        }
        }
    }

    // MARK: - Actions

    private var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title
    }

    private var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, d MMMM yyyy"
        return f.string(from: Date())
    }

    private var plainBody: String { NoteDocument.plainText(from: attributed) }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(title)\n\n\(plainBody)", forType: .string)
        toasts.push("Copied")
    }

    private func share() {
        guard let window = NSApp.keyValueWindow, let content = window.contentView else { return }
        // At the pointer, which is on the Share button. Anchored to a zero
        // rect, the picker opened in the corner of the window instead.
        let point = content.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let picker = NSSharingServicePicker(items: ["\(title)\n\n\(plainBody)"])
        picker.show(relativeTo: NSRect(origin: point, size: .zero).insetBy(dx: -1, dy: -1), of: content,
                    preferredEdge: content.isFlipped ? .maxY : .minY)
    }

    private func duplicate() {
        // This note's last keystrokes first. Cancelled instead, they waited
        // in PendingWrites, and went in over anything typed in it later.
        if saving { commit(attributed) }
        let plain = NoteDocument.plainText(from: attributed)
        let richText = NoteDocument.hasInlineFormatting(attributed)
            ? NoteDocument.archive(attributed) : nil
        let copy = store.addNote {
            $0.title = title.isEmpty ? "Untitled copy" : "\(title) copy"
            $0.content = plain
            $0.richText = richText
            $0.tags = note.tags
            $0.source = note.source
            $0.imageDataUrl = note.imageDataUrl
            $0.imageFile = note.imageFile
        }
        nav.selectedNoteId = copy.id
        toasts.push("Note duplicated")
    }

    private func downloadText() {
        let panel = NSSavePanel()
        let base = title.replacingOccurrences(of: "[^\\w\\- ]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = (base.isEmpty ? "note" : base) + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try "\(title)\n\n\(plainBody)\n".write(to: url, atomically: true, encoding: .utf8)
            toasts.push("Saved \(url.lastPathComponent)")
        } catch {
            toasts.push("Could not save: \(error.localizedDescription)", tone: .error)
        }
    }

    private func printNote() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        // Paper is white: the note's text colours are the theme's, and in
        // the dark theme they printed white.
        textView.appearance = NSAppearance(named: .aqua)
        textView.isVerticallyResizable = true
        let body = NSMutableAttributedString(
            string: "\(title)\n\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.labelColor])
        body.append(attributed)
        textView.textStorage?.setAttributedString(body)
        // Tall enough for all of it, so every page prints, not just the first.
        if let manager = textView.textLayoutManager { manager.ensureLayout(for: manager.documentRange) }
        textView.sizeToFit()
        let operation = NSPrintOperation(view: textView)
        operation.printInfo.topMargin = 72
        operation.printInfo.bottomMargin = 72
        operation.run()
    }

    private func deleteNote() {
        // Pick the neighbour before removing, so the editor lands somewhere
        // deliberate rather than on whatever sorts first afterwards.
        let remaining = store.liveNotes.filter { $0.id != note.id }
        nav.focusMode = false
        store.remove(.notes, note.id)
        nav.selectedNoteId = remaining.first?.id
        toasts.push("Note deleted", action: Toast.Action(label: "Undo") {
            store.updateNote(note.id) { $0.deletedAt = nil }
        })
    }

    private static var tomorrowAtNine: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func setReminder(hours: Int) {
        let cal = Calendar.current
        var at = Date().addingTimeInterval(Double(hours) * 3600)
        if hours >= 24 { at = cal.date(bySettingHour: 9, minute: 0, second: 0, of: at) ?? at }
        setReminder(at: at)
    }

    private func setReminder(at date: Date) {
        let iso = DateKit.iso(date)
        store.addTodo {
            $0.title = title.isEmpty ? "Look at this note" : title
            $0.noteId = note.id
            $0.dueAt = iso
            $0.remindAt = iso
        }
        toasts.push("⏰ Reminder set for \(Fmt.due(iso))")
    }

    /// Opens the assistant with the request filled in but not sent.
    private func askAssistant(_ prefill: String) {
        nav.assistantDraft = prefill
    }

    private func runAI(_ task: WriteTask) async {
        guard aiRunning == nil else { return }
        // The selection when there is one, as the menu's heading says.
        let selected = controller.selection
        let text = (selected?.text ?? plainBody).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            toasts.push("Write something first.", tone: .error)
            return
        }
        suggestion = nil
        aiRunning = task
        defer { aiRunning = nil }
        do {
            let result = try await engine.write(task, text: text, title: displayTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else {
                toasts.push("The model came back empty. Try again.", tone: .error)
                return
            }
            // The editor may have been switched to another note meanwhile.
            guard loadedNoteId == note.id else { return }
            suggestion = AISuggestion(task: task, text: result, range: selected?.range)
        } catch {
            toasts.push((error as? APIError)?.errorDescription ?? "Could not run that.", tone: .error)
        }
    }

    private func applyAI(_ s: AISuggestion, replace: Bool) {
        if replace {
            controller.replace(s.range, withPlainText: s.text)
        } else {
            controller.insertBelow(s.range, plainText: s.text)
        }
        suggestion = nil
        toasts.push(replace ? "✨ Replaced" : "✨ Added to the note")
    }

    private var linkSheet: some View {
        SheetFrame(title: "Insert link", width: 420, maxHeight: 220) {
            VStack(alignment: .leading, spacing: 12) {
                BoxedField(placeholder: "https://example.com", text: $linkURL)
                HStack {
                    Spacer()
                    GhostButton(action: { showLinkSheet = false }) { Text("Cancel") }
                    PrimaryButton(title: "Insert",
                                  disabled: linkURL.trimmingCharacters(in: .whitespaces).isEmpty) {
                        controller.insertLink(linkURL, title: linkURL)
                        linkURL = ""
                        showLinkSheet = false
                    }
                }
            }
        }
    }
}

private extension NSApplication {
    /// The window to anchor a share sheet on.
    var keyValueWindow: NSWindow? { keyWindow ?? windows.first }
}

/// The formatting toolbar's arrangement: its groups of tools, then the button
/// that expands it, as the last subview.
///
/// Collapsed, it is one line — the groups that fit, in order, with the button
/// at the end of the line. Expanded, the rest wrap onto lines below, so the
/// first line stays as it was. When every group fits on one line there is
/// nothing to expand, and the button is left out.
struct ToolbarLayout: Layout {
    var expanded: Bool
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 6

    struct Arrangement: Equatable {
        /// Where each subview goes, in the toolbar's own coordinates.
        var frames: [CGRect]
        /// The subviews on show; the others are placed past the trailing edge.
        var shown: Set<Int>
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(of: subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangement(of: subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(of subviews: Subviews, width: CGFloat) -> Arrangement {
        Self.arrange(subviews.map { $0.sizeThatFits(.unspecified) }, width: width,
                     expanded: expanded, spacing: spacing, lineSpacing: lineSpacing)
    }

    /// The arithmetic, apart from SwiftUI. `sizes` are the groups' and then
    /// the button's.
    static func arrange(_ sizes: [CGSize], width: CGFloat, expanded: Bool,
                        spacing: CGFloat, lineSpacing: CGFloat) -> Arrangement {
        guard let button = sizes.last else { return Arrangement(frames: [], shown: [], size: .zero) }
        let groups = Array(sizes.dropLast())
        let oneLine = groups.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, groups.count - 1))
        let fitsOnOneLine = oneLine <= width

        // The lines every group would take expanded. The first leaves room at
        // its end for the button, when there is a button.
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for (index, size) in groups.enumerated() {
            let room = lines.count == 1 && !fitsOnOneLine ? width - button.width - spacing : width
            if !lines[lines.count - 1].isEmpty, x + size.width > room {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(index)
            x += size.width + spacing
        }

        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var tops: [CGFloat] = []
        var heights: [CGFloat] = []
        var y: CGFloat = 0
        for (number, line) in lines.enumerated() {
            var height = line.map { groups[$0].height }.max() ?? 0
            if number == 0 && !fitsOnOneLine { height = max(height, button.height) }
            var x: CGFloat = 0
            for index in line {
                let size = groups[index]
                frames[index] = CGRect(x: x, y: y + (height - size.height) / 2,
                                       width: size.width, height: size.height)
                x += size.width + spacing
            }
            tops.append(y)
            heights.append(height)
            y += height + lineSpacing
        }

        let lineCount = fitsOnOneLine || expanded ? lines.count : 1
        var shown = Set(lines.prefix(lineCount).joined())
        // Far enough past the trailing edge to be past the pane's too, where
        // nothing can be clicked, on the line it would take: expanding
        // slides it in from the side.
        let offstage = (width.isFinite ? width : oneLine) + 100
        for index in groups.indices where !shown.contains(index) {
            frames[index] = frames[index].offsetBy(dx: offstage, dy: 0)
        }
        let buttonIndex = sizes.count - 1
        if fitsOnOneLine {
            frames[buttonIndex] = CGRect(origin: CGPoint(x: offstage, y: 0), size: button)
        } else {
            frames[buttonIndex] = CGRect(origin: CGPoint(x: width - button.width, y: (heights[0] - button.height) / 2),
                                         size: button)
            shown.insert(buttonIndex)
        }

        let height = tops[lineCount - 1] + heights[lineCount - 1]
        return Arrangement(frames: frames, shown: shown,
                           size: CGSize(width: fitsOnOneLine ? oneLine : width, height: height))
    }
}

/// The field for a new tag. Its own view with its own focus, so it works
/// inside the header that scrolls with the note — a separate AppKit-hosted
/// hierarchy, where the editor's focus state doesn't reach.
private struct TagField: View {
    @Environment(\.palette) private var p
    @Binding var draft: String?
    let addTag: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("tag name", text: Binding(
            get: { draft ?? "" },
            set: { value in
                // A comma finishes a tag and starts the next, as on the web.
                guard value.contains(",") else { draft = value; return }
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                parts.dropLast().forEach { addTag(String($0)) }
                draft = String(parts.last ?? "")
            }))
            .textFieldStyle(.plain)
            .font(FN.small)
            .foregroundStyle(p.text)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(width: 130, height: 28)
            .background(RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                .stroke(focused ? p.accent.opacity(0.55) : p.line, lineWidth: 1))
            .onSubmit {
                addTag(draft ?? "")
                draft = nil
            }
            .onExitCommand { draft = nil }
            .onChange(of: focused) { _, isFocused in
                // Clicking away keeps what was typed, or closes an empty field.
                guard !isFocused, let pending = draft else { return }
                addTag(pending)
                draft = nil
            }
            .onAppear {
                // A field that has to be clicked again after "Add tag" was
                // one of the glitches; it takes focus as it appears.
                Task { @MainActor in focused = true }
            }
    }
}
