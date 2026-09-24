import AppKit
import SwiftUI

// What the sticky notes show on the dock: a bubble each, splitting off the
// handle's top and bottom and stretching into a pill with the note's title;
// and, opened, the note on a sheet of its coloured paper inside the shape
// the handle grew into.

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

/// The open note: a sheet of coloured paper inside the dock's shape, a strip
/// along its top, and the note's text to type into.
struct StickyPage: View {
    @ObservedObject var dock: EdgeDock
    let noteId: String
    @ObservedObject private var stickies = EdgeStickies.shared
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme

    @State private var text = ""
    @State private var loaded = false
    /// Whether the text has the keyboard; set to give it the keyboard.
    @State private var editing = false
    @State private var writeId = UUID()
    @State private var pendingSave: Task<Void, Never>?

    private var note: Note? { store.liveNotes.first { $0.id == noteId } }
    private var paper: StickyPaper {
        .of(stickies.placement(noteId)?.color ?? .yellow, dark: scheme == .dark)
    }

    /// Formatting the plain text can't hold (bold, a link, a web note's
    /// HTML) would be lost by editing it here, so those open in the app.
    private var editable: Bool {
        guard let note else { return false }
        return note.richText == nil && (note.html ?? "").isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if editable {
                    ZStack(alignment: .topLeading) {
                        StickyTextView(text: $text, editing: $editing, editable: true,
                                       palette: StickyText.Palette(paper), onEscape: minimize)
                            .padding(.horizontal, 12)
                        if text.isEmpty {
                            Text("Write something…")
                                .font(.system(size: 13))
                                .foregroundStyle(paper.faint)
                                .padding(.horizontal, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: text) { _, _ in scheduleSave() }
                } else {
                    StickyTextView(text: .constant(note?.content ?? ""), editing: .constant(false), editable: false,
                                   palette: StickyText.Palette(paper), onEscape: minimize)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .bottomTrailing) {
                        Button("Edit in Four Notes") { stickies.openInApp(noteId) }
                            .buttonStyle(.fn)
                            .font(FN.font(11, .medium))
                            .foregroundStyle(paper.faint)
                            .padding(8)
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(paper.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(12)
        .contextMenu { menu }
        .onExitCommand { minimize() }
        .onAppear(perform: load)
        .onChange(of: editing) { _, now in stickies.setEditing(noteId, now) }
        .onChange(of: dock.openSticky, initial: true) { _, open in
            guard open == noteId, stickies.consumeFocus(noteId) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { editing = true }
        }
        .onChange(of: note?.content) { _, content in
            // Changed somewhere else — in the app, by the assistant — while
            // this one wasn't being typed in.
            guard !editing, pendingSave == nil, let content, content != text else { return }
            text = content
        }
        .onDisappear {
            if pendingSave != nil { commit() }
            stickies.setEditing(noteId, false)
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Icon("pin", size: 12, weight: 1.9)
                .foregroundStyle(paper.faint)
                .padding(.trailing, 4)
            Text(label)
                .font(FN.font(11.5, .medium))
                .foregroundStyle(paper.faint)
                .lineLimit(1)
            Spacer(minLength: 4)
            headerButton(dock.edge == .right ? "collapseRight" : "collapseLeft", help: "Minimize", action: minimize)
            headerButton("arrowUpRight", help: "Open in Four Notes") {
                commit()
                stickies.openInApp(noteId)
            }
            headerButton("x", help: "Take off the edge (the note stays in Notes)") {
                commit()
                dock.close()
                stickies.unstick(noteId)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
    }

    private var label: String {
        guard let note else { return "" }
        if QuickNote.isQuick(note) { return Fmt.relative(note.createdAt) }
        return note.title.isEmpty ? "Untitled" : note.title
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 12, weight: 1.9)
                .foregroundStyle(paper.text.opacity(0.7))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .help(help)
        .accessibilityLabel(help)
    }

    private func minimize() {
        commit()
        editing = false
        dock.close()
    }

    @ViewBuilder
    private var menu: some View {
        Menu("Colour") {
            ForEach(StickyTint.allCases, id: \.self) { color in
                Button {
                    stickies.setColor(noteId, color)
                } label: {
                    if stickies.placement(noteId)?.color == color {
                        Label(color.rawValue.capitalized, systemImage: "checkmark")
                    } else {
                        Text(color.rawValue.capitalized)
                    }
                }
            }
        }
        Button("Minimize", action: minimize)
        Button("Open in Four Notes") { stickies.openInApp(noteId) }
        Divider()
        Button("Take Off the Edge") {
            commit()
            dock.close()
            stickies.unstick(noteId)
        }
        Button("Delete Note", role: .destructive) {
            pendingSave?.cancel()
            pendingSave = nil
            PendingWrites.release(writeId)
            store.remove(.notes, noteId)
        }
    }

    // MARK: - Loading and saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        text = note?.content ?? ""
    }

    private func scheduleSave() {
        guard let note, text != note.content else { return }
        pendingSave?.cancel()
        PendingWrites.hold(writeId) { commit() }
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        PendingWrites.release(writeId)
        pendingSave?.cancel()
        pendingSave = nil
        guard editable, let note, text != note.content else { return }
        let next = text
        store.updateNote(noteId) {
            $0.content = next
            // A quick note is titled by its first line, as it was when written.
            if QuickNote.isQuick(note) { $0.title = QuickNote.title(for: next) }
        }
    }
}
