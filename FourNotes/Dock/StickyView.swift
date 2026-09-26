import AppKit
import SwiftUI

// What the sticky notes show on the dock: a bubble each, splitting off the
// handle's top and bottom and stretching into a pill with the note's title;
// and, opened, the note on a sheet of its coloured paper in its own window.

struct StickyPaper {
    let fill, text, faint: Color
    /// The note's mark in the island: brighter than the paper, so it reads on the dock.
    let vivid: Color

    static func of(_ color: StickyTint, dark: Bool) -> StickyPaper {
        switch (color, dark) {
        case (.yellow, false): return .init(0xFFF1A6, 0x3B3318, 0xF2C230)
        case (.pink, false): return .init(0xFFDCE5, 0x4A2430, 0xEF7B9C)
        case (.blue, false): return .init(0xD8EDFF, 0x1E3347, 0x5AA8EE)
        case (.green, false): return .init(0xDDF4D3, 0x223A20, 0x62BE62)
        case (.violet, false): return .init(0xE9E2FF, 0x2D2552, 0x8C78F0)
        case (.yellow, true): return .init(0x4A4120, 0xF6EDC8, 0xE8B92C)
        case (.pink, true): return .init(0x4D2C36, 0xF8DDE5, 0xE56E90)
        case (.blue, true): return .init(0x233749, 0xD9ECFF, 0x4E9BE0)
        case (.green, true): return .init(0x283F26, 0xDDF3D5, 0x58B058)
        case (.violet, true): return .init(0x362F55, 0xE8E1FF, 0x8570E8)
        }
    }

    private init(_ fill: UInt32, _ text: UInt32, _ vivid: UInt32) {
        self.fill = .hex(fill)
        self.text = .hex(text)
        self.vivid = .hex(vivid)
        faint = Color.hex(text).opacity(0.55)
    }
}

/// The bubbles. Drawn as metaballs: blobs inside the top and bottom of the
/// handle and the bubbles themselves, blurred together and cut at half
/// opacity, so as the bubbles pull out a neck forms between each and what
/// it's leaving, thins and snaps by itself — and forms again as they come
/// back. The one under the pointer stretches into a pill.
struct StickyIsland: View, Animatable {
    let dock: EdgeDock
    /// 0 inside the handle … 1 split off to their places.
    var progress: CGFloat
    var expansion: CGFloat
    var previousExpansion: CGFloat
    var pulse: CGFloat
    let ids: [String]
    /// Each bubble's middle, from the window's top.
    let ys: [CGFloat]
    let expanded: String?
    let previous: String?
    let pulsing: String?
    /// The middle of the handle, and half its height.
    let handleCenter: CGPoint
    let handleHalf: CGFloat
    let edge: DockEdge
    let width: CGFloat
    let fill: Color

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(progress, expansion), AnimatablePair(previousExpansion, pulse)) }
        set {
            progress = newValue.first.first
            expansion = newValue.first.second
            previousExpansion = newValue.second.first
            pulse = newValue.second.second
        }
    }

    /// Where a bubble comes from: just inside the end of the handle facing it.
    private func anchor(above: Bool) -> CGPoint {
        CGPoint(x: handleCenter.x, y: handleCenter.y + (above ? -1 : 1) * (handleHalf - 12))
    }

    private func stretch(_ id: String) -> CGFloat {
        id == expanded ? expansion : id == previous ? previousExpansion : 0
    }

    /// Where bubble `i` is drawn now: pulled out of the handle to its place,
    /// then stretched into its pill.
    private func rect(_ i: Int) -> CGRect {
        let y = ys[i]
        let from = anchor(above: y < handleCenter.y)
        let to = StickyGeometry.bubbleRect(width: width, edge: edge, centerY: y)
        let p = max(0, progress)
        let size = 14 + (StickyGeometry.bubble - 14) * min(p, 1.1)
        let cx = from.x + (to.midX - from.x) * p
        let cy = from.y + (to.midY - from.y) * p
        var r = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
        let e = min(max(0, stretch(ids[i])), 1.05)
        if e > 0 {
            let pill = StickyGeometry.pillRect(width: width, edge: edge, centerY: y)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
            r = CGRect(x: mix(r.minX, pill.minX), y: mix(r.minY, pill.minY),
                       width: mix(r.width, pill.width), height: mix(r.height, pill.height))
        }
        if ids[i] == pulsing { r = r.insetBy(dx: -4 * pulse, dy: -4 * pulse) }
        return r
    }

    var body: some View {
        let rects = ids.indices.map(rect)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.addFilter(.alphaThreshold(min: 0.5, color: fill))
                context.addFilter(.blur(radius: 6))
                context.drawLayer { layer in
                    // Hidden behind the handle, which is drawn over them: only
                    // the necks they pull out towards the bubbles show.
                    for above in [true, false] {
                        let a = anchor(above: above)
                        layer.fill(Path(ellipseIn: CGRect(x: a.x - 11, y: a.y - 11, width: 22, height: 22)),
                                   with: .color(.black))
                    }
                    for r in rects {
                        layer.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(.black))
                    }
                }
            }
            .shadow(color: .black.opacity(0.22 * min(1, max(0, progress))), radius: 8, y: 3)
            .allowsHitTesting(false)

            ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                let r = rects[i]
                let e = max(0, min(stretch(id), 1))
                StickyBubbleFace(dock: dock, id: id, stretch: e, edge: edge)
                    .frame(width: max(r.width, 1), height: max(r.height, 1))
                    .position(x: r.midX, y: r.midY)
                    .opacity(Double(max(0, (progress - 0.6) / 0.4)))
                    .allowsHitTesting(progress > 0.9)
            }
        }
    }
}

/// What a bubble shows: the note's colour as a small folded note; stretched
/// into a pill, the title and when it was last changed too.
private struct StickyBubbleFace: View {
    let dock: EdgeDock
    let id: String
    let stretch: CGFloat
    let edge: DockEdge
    @ObservedObject private var stickies = EdgeStickies.shared
    @Environment(\.dock) private var d
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let note = stickies.note(id)
        let title = note.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled"
        let tint = StickyPaper.of(stickies.placement(id)?.color ?? .yellow, dark: scheme == .dark).vivid
        let glyph = RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(tint)
            .frame(width: 12, height: 14)
            .overlay(alignment: .topTrailing) {
                FoldedCorner().fill(.black.opacity(0.25)).frame(width: 4.5, height: 4.5)
            }
        ZStack {
            glyph.opacity(Double(max(0, 1 - stretch * 2.5)))
            HStack(spacing: 10) {
                glyph
                Text(title).font(FN.font(13, .medium)).foregroundStyle(d.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(Fmt.relative(note?.updatedAt)).font(FN.font(11)).foregroundStyle(d.faint)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .opacity(Double(max(0, (stretch - 0.55) / 0.45)))
        }
        .contentShape(Capsule())
        .onTapGesture { dock.openSticky(id) }
        .help(title)
        .accessibilityElement()
        .accessibilityLabel("Sticky note: \(title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dock.openSticky(id) }
    }
}

private struct FoldedCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}


/// The open note: a sheet of coloured paper with a title, the note's text to
/// write in, and a small toolbar along the bottom.
struct StickySheet: View {
    @ObservedObject var state: StickyWindowState
    @ObservedObject private var stickies = EdgeStickies.shared
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme
    @StateObject private var format = StickyTextController()

    @State private var text = ""
    @State private var title = ""
    /// The text and title as this sticky last read or wrote them. What
    /// differs from them was typed here; a newer version in the note was
    /// written elsewhere, and is not this sticky's to save back.
    @State private var base = ""
    @State private var titleBase = ""
    @State private var loaded = false
    /// Whether the text has the keyboard; set to give it the keyboard.
    @State private var editing = false
    @FocusState private var titleFocused: Bool
    @State private var hovering = false
    /// Where the pointer and the window were when a drag began (screen
    /// coordinates); nil while the note isn't being moved.
    @GestureState private var moving: Move?
    @State private var writeId = UUID()
    @State private var pendingSave: Task<Void, Never>?

    private var noteId: String { state.noteId }
    private var note: Note? { store.liveNotes.first { $0.id == noteId } }
    private var paper: StickyPaper {
        .of(stickies.placement(noteId)?.color ?? .yellow, dark: scheme == .dark)
    }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    /// Formatting the plain text can't hold (bold, a link, a web note's
    /// HTML) would be lost by editing it here, so those open in the app.
    private var editable: Bool {
        guard let note else { return false }
        return note.richText == nil && (note.html ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topStrip
            titleField
                .padding(.horizontal, 18)
            Text(edited)
                .font(FN.font(10.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(paper.faint)
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 10)
            page
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            toolbar
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 6)
        }
        .background { PaperBackground(paper: paper, dark: scheme == .dark) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(paper.text.opacity(scheme == .dark ? 0.14 : 0.07), lineWidth: 0.5))
        // Anywhere on the paper that isn't text or a button moves the note
        // (the strip along the top is the window's own: see StickyPanel).
        .contentShape(shape)
        .gesture(move)
        // Lifted a little off the screen while it's carried.
        .scaleEffect(carried ? 1.015 : 1)
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : carried ? 0.26 : 0.18),
                radius: carried ? 26 : 20, y: carried ? 18 : 12)
        .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
        .animation(Motion.quick, value: carried)
        .tint(paper.text)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .onExitCommand {
            // Esc only puts the pen down; the note stays out until minimized.
            editing = false
            titleFocused = false
        }
        .onAppear(perform: load)
        .onChange(of: editing) { _, now in stickies.setEditing(noteId, now) }
        .onChange(of: state.focusRequest) { _, _ in
            _ = stickies.consumeFocus(noteId)
            guard editable else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { editing = true }
        }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: note?.content) { _, content in
            // Changed somewhere else — in the app, by the assistant — with
            // nothing typed here waiting to be saved. Held back while this
            // one merely had the keyboard, it was then saved back over the
            // newer text, as soon as the sticky was minimized.
            guard let content, content != text, text == base else { return }
            text = content
            base = content
        }
        .onChange(of: note?.title) { _, _ in
            guard !titleFocused, title == titleBase, let note else { return }
            let shown = Self.autoTitled(note) ? "" : note.title
            if shown != title { title = shown }
            titleBase = shown
        }
        .onDisappear {
            if pendingSave != nil { commit() }
            stickies.setEditing(noteId, false)
        }
    }

    // MARK: Parts

    /// The strip along the top the note is dragged by, like the glued edge
    /// of a paper note, with the button that tucks it away.
    private var topStrip: some View {
        HStack(spacing: 0) {
            Spacer()
            Button(action: minimize) {
                Capsule()
                    .fill(paper.text.opacity(0.6))
                    .frame(width: 10, height: 1.6)
                    .frame(width: 22, height: 22)
                    .background(paper.text.opacity(hovering ? 0.07 : 0), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.fn)
            .help("Minimize")
            .accessibilityLabel("Minimize")
        }
        .padding(.horizontal, 8)
        .frame(height: StickyGeometry.stripHeight)
        .background {
            // The grip: what says the strip is there to take hold of.
            Capsule()
                .fill(paper.text.opacity(hovering || carried ? 0.2 : 0.1))
                .frame(width: 30, height: 4)
                .allowsHitTesting(false)
        }
        .animation(Motion.quick, value: hovering)
    }

    private var carried: Bool { moving != nil || state.carried }

    /// Moves the window with the pointer, by where both are on screen: the
    /// gesture's own coordinates move with the window, and would fight it.
    private var move: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($moving) { _, move, _ in
                guard let window = state.window else { return }
                let mouse = NSEvent.mouseLocation
                // From where the mouse went down, as the window saw it — not
                // the gesture's translation, which for a drag that began on
                // a toolbar button threw the note hundreds of points off.
                let down = (window as? StickyPanel)?.lastDown
                let start = move ?? Move(mouse: down?.mouse ?? mouse, origin: down?.origin ?? window.frame.origin)
                move = start
                window.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                              y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in StickyWindows.shared.moved(noteId) }
    }

    fileprivate struct Move {
        let mouse: CGPoint
        let origin: CGPoint
    }

    private var titleField: some View {
        TextField(text: $title, prompt: Text(titlePrompt).foregroundStyle(paper.faint.opacity(0.8))) {
            Text("Title")
        }
        .textFieldStyle(.plain)
        .font(FN.serif(20, .semibold))
        .foregroundStyle(paper.text)
        .focused($titleFocused)
        .onSubmit {
            titleFocused = false
            if editable { editing = true }
        }
        .accessibilityLabel("Title")
    }

    @ViewBuilder
    private var page: some View {
        if editable {
            ZStack(alignment: .topLeading) {
                StickyTextView(text: $text, editing: $editing, editable: true,
                               palette: StickyText.Palette(paper), controller: format,
                               onEscape: { editing = false })
                if text.isEmpty {
                    Text("Write something…")
                        .font(.system(size: StickyText.bodySize))
                        .foregroundStyle(paper.faint)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
        } else {
            StickyTextView(text: .constant(note?.content ?? ""), editing: .constant(false), editable: false,
                           palette: StickyText.Palette(paper))
        }
    }

    /// A few of the note editor's tools, for what plain text can hold.
    private var toolbar: some View {
        HStack(spacing: 1) {
            if editable {
                tool("textSize", "Heading", .heading)
                tool("listBullet", "Bulleted list", .bullet)
                tool("listOrdered", "Numbered list", .numbered)
                tool("checklist", "Checklist", .checklist)
                tool("quote", "Quote", .quote)
            } else {
                Button("Edit in Four Notes", action: openInApp)
                    .buttonStyle(.fn)
                    .font(FN.font(11, .medium))
                    .foregroundStyle(paper.text.opacity(0.7))
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 4)
            MenuButton(help: "Colour", entries: { colourEntries }) {
                Circle()
                    .fill(paper.vivid)
                    .overlay(Circle().strokeBorder(paper.text.opacity(0.2), lineWidth: 0.5))
                    .frame(width: 13, height: 13)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            ToolbarIcon(icon: "arrowUpRight", help: "Open in Four Notes", paper: paper, action: openInApp)
            MenuButton(help: "More", entries: { moreEntries }) {
                ToolbarIcon.label("more", paper: paper, active: false)
            }
        }
        .padding(2)
        .background(paper.text.opacity(0.045), in: Capsule())
        .opacity(hovering || editing || titleFocused ? 1 : 0.6)
        .animation(Motion.standard, value: hovering || editing || titleFocused)
    }

    private func tool(_ icon: String, _ help: String, _ kind: StickyText.LineKind) -> some View {
        ToolbarIcon(icon: icon, help: help, paper: paper,
                    active: editing && format.current == kind) { format.toggle(kind) }
    }

    private var colourEntries: [MenuEntry] {
        StickyTint.allCases.map { tint in
            .item(tint.rawValue.capitalized, checked: stickies.placement(noteId)?.color == tint,
                  swatch: NSColor(StickyPaper.of(tint, dark: scheme == .dark).vivid)) {
                withAnimation(Motion.standard) { stickies.setColor(noteId, tint) }
            }
        }
    }

    private var moreEntries: [MenuEntry] {
        [
            .item("Minimize", action: minimize),
            .item("Open in Four Notes", action: openInApp),
            .divider,
            .item("Take Off the Edge", action: takeOff),
            .item("Delete Note", destructive: true, action: delete),
        ]
    }

    @ViewBuilder
    private var menu: some View {
        Menu("Colour") {
            ForEach(StickyTint.allCases, id: \.self) { tint in
                Button {
                    stickies.setColor(noteId, tint)
                } label: {
                    if stickies.placement(noteId)?.color == tint {
                        Label(tint.rawValue.capitalized, systemImage: "checkmark")
                    } else {
                        Text(tint.rawValue.capitalized)
                    }
                }
            }
        }
        Button("Minimize", action: minimize)
        Button("Open in Four Notes", action: openInApp)
        Divider()
        Button("Take Off the Edge", action: takeOff)
        Button("Delete Note", role: .destructive, action: delete)
    }

    private var edited: String {
        guard let note else { return "" }
        let when = Fmt.relative(note.updatedAt)
        return when.isEmpty ? "" : "Edited \(when)"
    }

    /// A quick note is titled by its first line until it's given a title of
    /// its own; that first line shows, faintly, where the title goes.
    private var titlePrompt: String {
        guard let note, QuickNote.isQuick(note) else { return "Title" }
        let first = QuickNote.title(for: text)
        return first.isEmpty ? "Title" : first
    }

    private static func autoTitled(_ note: Note) -> Bool {
        QuickNote.isQuick(note) && note.title == QuickNote.title(for: note.content)
    }

    // MARK: Actions

    private func minimize() {
        commit()
        editing = false
        titleFocused = false
        StickyWindows.shared.minimize(noteId)
    }

    private func openInApp() {
        commit()
        StickyWindows.shared.minimize(noteId)
        stickies.openInApp(noteId)
    }

    private func takeOff() {
        commit()
        stickies.unstick(noteId)
    }

    private func delete() {
        pendingSave?.cancel()
        pendingSave = nil
        PendingWrites.release(writeId)
        store.remove(.notes, noteId)
    }

    // MARK: Loading and saving

    private func load() {
        guard !loaded, let note else { return }
        loaded = true
        text = note.content
        base = text
        title = Self.autoTitled(note) ? "" : note.title
        titleBase = title
    }

    private func scheduleSave() {
        guard loaded, let note,
              text != note.content || nextTitle(note, content: editable ? text : note.content) != note.title
        else { return }
        pendingSave?.cancel()
        PendingWrites.hold(writeId) { commit() }
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// The title to save: what's typed — or, for a quick note left without
    /// one, the first line of `content`.
    private func nextTitle(_ note: Note, content: String) -> String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, QuickNote.isQuick(note) { return QuickNote.title(for: content) }
        return typed == note.title.trimmingCharacters(in: .whitespacesAndNewlines) ? note.title : typed
    }

    private func commit() {
        PendingWrites.release(writeId)
        pendingSave?.cancel()
        pendingSave = nil
        guard loaded, let note else { return }
        // Only what was typed here.
        let typed = editable && text != base
        let content = typed ? text : note.content
        // A quick note left without a title follows its first line.
        let autoTitled = QuickNote.isQuick(note) && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let next = title != titleBase || autoTitled ? nextTitle(note, content: content) : note.title
        guard content != note.content || next != note.title else { return }
        store.updateNote(noteId) {
            $0.content = content
            $0.title = next
        }
        if typed { base = text }
        titleBase = title
    }
}

/// One of the sticky toolbar's buttons: an icon, lit while its format is on.
private struct ToolbarIcon: View {
    let icon: String
    let help: String
    let paper: StickyPaper
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Self.label(icon, paper: paper, active: active) }
            .buttonStyle(.fn)
            .help(help)
            .accessibilityLabel(help)
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    static func label(_ icon: String, paper: StickyPaper, active: Bool) -> some View {
        HoverIcon(icon: icon, paper: paper, active: active)
    }
}

private struct HoverIcon: View {
    let icon: String
    let paper: StickyPaper
    let active: Bool
    @State private var hovering = false

    var body: some View {
        Icon(icon, size: 14, weight: 1.8)
            .foregroundStyle(paper.text.opacity(active || hovering ? 0.95 : 0.6))
            .frame(width: 26, height: 26)
            .background(paper.text.opacity(active ? 0.12 : hovering ? 0.07 : 0), in: Circle())
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: active)
    }
}

/// Coloured paper: a little lighter where the light catches the top, the
/// glued strip along it a shade deeper, and a fine grain all over.
///
/// It takes clicks, though it does nothing with them: a see-through window
/// lets clicks through wherever SwiftUI has nothing to hit, and with the
/// paper left out, clicks on the strip along the top went to the app
/// underneath — the note couldn't be dragged by it.
private struct PaperBackground: View {
    let paper: StickyPaper
    let dark: Bool

    var body: some View {
        ZStack(alignment: .top) {
            paper.fill
            LinearGradient(colors: [.white.opacity(dark ? 0.05 : 0.35), .clear],
                           startPoint: .top, endPoint: .bottom)
            // The glued strip.
            paper.text.opacity(dark ? 0.06 : 0.035).frame(height: StickyGeometry.stripHeight)
            Canvas { context, size in
                // The same grain every time: a fixed sequence, not random.
                var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
                func next() -> CGFloat {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return CGFloat(seed >> 33) / CGFloat(1 << 31)
                }
                let count = Int(size.width * size.height / 90)
                for _ in 0..<count {
                    let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 1, height: 1)
                    let light = next() > 0.5
                    context.fill(Path(rect), with: .color(light ? .white.opacity(0.10) : .black.opacity(dark ? 0.10 : 0.035)))
                }
            }
        }
    }
}
