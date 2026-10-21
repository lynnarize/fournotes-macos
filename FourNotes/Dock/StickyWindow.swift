import AppKit
import SwiftUI

// An open sticky note: its own little window beside the edge, popped out of
// the bubble it was clicked on. It floats over every app and stays put when
// you click elsewhere — only its minimize button sends it back, flying into
// its bubble, which stays out beside the handle while the note is open.
// Several can be open at once, and each remembers where it was dragged to.
//
// The flight to and from the bubble happens inside the note's own window:
// for the moment it lasts, the window is stretched to take in the bubble as
// well, with the paper drawn exactly where it was, and the paper moves
// across it. The notes sit one level below the dock, so the paper passes
// under the bubble — into it — rather than over it.

@MainActor
final class StickyWindows {
    static let shared = StickyWindows()

    private var open: [String: StickyPanel] = [:]
    private static let framesKey = "fournotes.stickies.frames"

    private init() {}

    /// Some note is out on screen (not counting ones on their way back in).
    var hasOpen: Bool { open.values.contains { !$0.state.closing } }

    func isOpen(_ noteId: String) -> Bool { open[noteId].map { !$0.state.closing } ?? false }

    /// Pops the note out of `anchor` (the bubble it lives in, in screen
    /// coordinates) — or brings it forward if it's already out.
    func show(_ noteId: String, from anchor: CGPoint, edge: DockEdge, visible: CGRect) {
        if let panel = open[noteId] {
            panel.orderFrontRegardless()
            panel.makeKey()
            // On its way back in: turned round.
            if panel.state.closing { flyOut(panel) } else { panel.state.focusRequest += 1 }
            return
        }
        let taken = open.values.map(paperWindow)
        let frame = savedFrame(noteId)
            ?? StickyGeometry.window(anchor: anchor, edge: edge, in: visible, avoiding: taken)
        let state = StickyWindowState(noteId: noteId)
        state.tilt = edge == .right ? 8 : -8
        let panel = StickyPanel(frame: frame, state: state)
        state.window = panel
        panel.contentView = StickyHostingView(rootView: StickyScene(model: AppModel.shared, state: state))
        open[noteId] = panel
        stretch(panel, toReach: anchor)
        panel.orderFrontRegardless()
        panel.makeKey()
        // A turn later, so it's drawn in the bubble first and flies from there.
        DispatchQueue.main.async { [weak self] in self?.flyOut(panel) }
    }

    /// Sends the note back into its bubble.
    func minimize(_ noteId: String) {
        guard let panel = open[noteId], !panel.state.closing else { return }
        let state = panel.state
        saveFrame(noteId, paperWindow(panel))
        state.closing = true
        state.generation += 1
        let current = state.generation
        stretch(panel, toReach: EdgeDock.shared.stickyAnchor(noteId))

        if Motion.reduce {
            remove(noteId)
            EdgeDock.shared.stickyReturned(noteId)
            return
        }
        // A turn later, once the stretched window is drawn. Slow to leave
        // and quick to arrive, it drops into the bubble; the bubble swells
        // as it catches it.
        DispatchQueue.main.async {
            guard state.generation == current else { return }
            withAnimation(.timingCurve(0.55, 0, 0.8, 0.4, duration: 0.34)) { state.shown = false }
            withAnimation(.easeIn(duration: 0.1).delay(0.24)) { state.visible = false }
        }
        after(0.33, state, current) { EdgeDock.shared.stickyReturned(noteId) }
        after(0.42, state, current) { [weak self] in self?.remove(noteId) }
    }

    /// The note was dragged and let go: kept where its top strip can still
    /// be taken hold of, and remembered there.
    func moved(_ noteId: String) {
        guard let panel = open[noteId], !panel.state.closing else { return }
        let margin = StickyGeometry.windowMargin
        let paper = paperWindow(panel).insetBy(dx: margin, dy: margin)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let shift = StickyGeometry.keepGrabbable(paper, in: visible)
            if shift != .zero {
                var frame = panel.frame
                frame.origin.x += shift.dx
                frame.origin.y += shift.dy
                panel.setFrame(frame, display: true, animate: !Motion.reduce)
            }
        }
        saveFrame(noteId, paperWindow(panel))
    }

    /// Everything open that's no longer on the edge — taken off, deleted, or
    /// in a space that isn't showing — goes.
    func keep(_ noteIds: [String]) {
        for id in open.keys where !noteIds.contains(id) { minimize(id) }
    }

    // MARK: Flying

    private func flyOut(_ panel: StickyPanel) {
        let state = panel.state
        state.closing = false
        state.generation += 1
        let current = state.generation
        if Motion.reduce {
            state.shown = true
            state.visible = true
            fit(panel)
        } else {
            withAnimation(.spring(response: 0.46, dampingFraction: 0.78)) { state.shown = true }
            withAnimation(.easeOut(duration: 0.14)) { state.visible = true }
            // Back to just the paper's size once it has settled.
            after(0.7, state, current) { [weak self] in self?.fit(panel) }
        }
        state.focusRequest += 1
    }

    /// Where the paper rests, as the window it has when it isn't flying.
    private func paperWindow(_ panel: StickyPanel) -> CGRect {
        let size = StickyGeometry.windowSize
        let center = panel.state.paperCenter
        return CGRect(x: panel.frame.minX + center.x - size.width / 2,
                      y: panel.frame.maxY - center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Grows the window to take in `anchor` too, the paper staying exactly
    /// where it is on screen.
    private func stretch(_ panel: StickyPanel, toReach anchor: CGPoint) {
        let paper = paperWindow(panel)
        let reach = CGRect(x: anchor.x - 40, y: anchor.y - 40, width: 80, height: 80)
        let frame = paper.union(reach).integral
        place(panel, frame: frame, paper: paper, anchor: anchor)
    }

    /// Shrinks the window back to the paper, wherever it was dragged to.
    private func fit(_ panel: StickyPanel) {
        let paper = paperWindow(panel)
        guard panel.frame != paper else { return }
        let anchor = CGPoint(x: panel.frame.minX + panel.state.anchorPoint.x,
                             y: panel.frame.maxY - panel.state.anchorPoint.y)
        place(panel, frame: paper, paper: paper, anchor: anchor)
    }

    private func place(_ panel: StickyPanel, frame: CGRect, paper: CGRect, anchor: CGPoint) {
        let state = panel.state
        var instant = SwiftUI.Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            state.paperCenter = CGPoint(x: paper.midX - frame.minX, y: frame.maxY - paper.midY)
            state.anchorPoint = CGPoint(x: anchor.x - frame.minX, y: frame.maxY - anchor.y)
        }
        // Resized with the view laid out for it in the same moment, or the
        // paper would jump for a frame.
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        if let view = panel.contentView { panel.invalidateCursorRects(for: view) }
    }

    private func remove(_ noteId: String) {
        guard let panel = open.removeValue(forKey: noteId) else { return }
        panel.orderOut(nil)
        // Takes the note's view down with it, which saves anything unsaved.
        panel.contentView = nil
    }

    /// Runs `run` in `seconds`, unless the note has moved on since.
    private func after(_ seconds: Double, _ state: StickyWindowState, _ generation: Int,
                       _ run: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard state.generation == generation else { return }
            run()
        }
    }

    // MARK: Where each was left

    private func savedFrame(_ noteId: String) -> CGRect? {
        let frames = UserDefaults.standard.dictionary(forKey: Self.framesKey) as? [String: String] ?? [:]
        guard let saved = frames[noteId] else { return nil }
        let frame = NSRectFromString(saved)
        let size = StickyGeometry.windowSize
        guard frame.size == size else { return nil }
        // Only while its paper is still on a screen that's attached.
        let paper = frame.insetBy(dx: StickyGeometry.windowMargin, dy: StickyGeometry.windowMargin)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersection(paper).width > 80 }) else { return nil }
        return frame
    }

    private func saveFrame(_ noteId: String, _ frame: CGRect) {
        var frames = UserDefaults.standard.dictionary(forKey: Self.framesKey) as? [String: String] ?? [:]
        // Only notes still on the edge.
        let stuck = Set(EdgeStickies.shared.placements.map(\.noteId))
        frames = frames.filter { stuck.contains($0.key) }
        frames[noteId] = NSStringFromRect(frame)
        UserDefaults.standard.set(frames, forKey: Self.framesKey)
    }
}

/// What the note's view animates by.
@MainActor
final class StickyWindowState: ObservableObject {
    let noteId: String
    /// Out at its place (true), or down in its bubble.
    @Published var shown = false
    /// Faded in; faded out only at the last moment of going back.
    @Published var visible = false
    /// Where the paper's middle rests, and the bubble's, in the window
    /// (from its top left).
    @Published var paperCenter = CGPoint(x: StickyGeometry.windowSize.width / 2,
                                         y: StickyGeometry.windowSize.height / 2)
    @Published var anchorPoint = CGPoint.zero
    /// Tipped while it's small, like paper caught mid-air.
    var tilt: Double = 8
    /// On its way back into the bubble.
    var closing = false
    /// Bumped to put the caret in the note.
    @Published var focusRequest = 0
    /// Its window, for moving it by hand.
    weak var window: NSWindow?
    /// Being dragged by its top strip.
    @Published var carried = false
    var generation = 0

    init(noteId: String) { self.noteId = noteId }
}

final class StickyPanel: NSPanel {
    let state: StickyWindowState

    init(frame: CGRect, state: StickyWindowState) {
        self.state = state
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Just under the dock: over every app, but never over the handle and
        // its bubbles — which the note flies under, into its bubble.
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // Drawn by the note itself, round its paper.
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // Moved by hand (see sendEvent), not by the system.
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        setAccessibilityLabel("Sticky note")
        setFrame(frame, display: false)
    }

    // MARK: Dragged by the strip

    /// The strip along the paper's top, in the window's top-left
    /// coordinates: between the colour dots on its left and the unstick and
    /// minimize buttons on its right, which are clicked, not dragged.
    var strip: CGRect? {
        guard state.shown, !state.closing else { return nil }
        let center = state.paperCenter
        let paper = CGRect(x: center.x - StickyGeometry.paperWidth / 2,
                           y: center.y - StickyGeometry.paperHeight / 2,
                           width: StickyGeometry.paperWidth, height: StickyGeometry.paperHeight)
        let dots: CGFloat = 112, buttons: CGFloat = 68
        return CGRect(x: paper.minX + dots, y: paper.minY, width: paper.width - dots - buttons,
                      height: StickyGeometry.stripHeight)
    }

    /// Where the pointer and the window were when a drag by the strip began,
    /// on screen, and whether it has moved yet.
    private var carry: (mouse: CGPoint, origin: CGPoint, moved: Bool)?
    /// Where the pointer and the window were at the last mouse-down
    /// anywhere, on screen: where a drag by the rest of the paper (a SwiftUI
    /// gesture, which only hears of it a few points later) began.
    private(set) var lastDown: (mouse: CGPoint, origin: CGPoint)?

    /// A drag that starts on the strip is handled here, before SwiftUI sees
    /// it — like a title bar, it moves the note from the first point.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            lastDown = (NSEvent.mouseLocation, frame.origin)
            let point = CGPoint(x: event.locationInWindow.x, y: frame.height - event.locationInWindow.y)
            guard let strip, strip.contains(point) else { break }
            carry = (NSEvent.mouseLocation, frame.origin, false)
            makeKey()
            return
        case .leftMouseDragged:
            guard var carry else { break }
            let mouse = NSEvent.mouseLocation
            if !carry.moved {
                // A click that wobbles isn't a drag.
                guard hypot(mouse.x - carry.mouse.x, mouse.y - carry.mouse.y) >= 2 else { return }
                carry.moved = true
                self.carry = carry
                state.carried = true
                NSCursor.closedHand.push()
            }
            setFrameOrigin(CGPoint(x: carry.origin.x + mouse.x - carry.mouse.x,
                                   y: carry.origin.y + mouse.y - carry.mouse.y))
            return
        case .leftMouseUp:
            guard let carry else { break }
            self.carry = nil
            if carry.moved {
                NSCursor.pop()
                state.carried = false
                StickyWindows.shared.moved(state.noteId)
            }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    // Types without bringing the app forward; whatever was in front stays.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The note's root: the shared objects and the theme, as the dock has them.
struct StickyScene: View {
    let model: AppModel
    @ObservedObject var state: StickyWindowState
    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let theme = ThemeChoice(rawValue: themeRaw) ?? .system
        let scheme = theme.colorScheme ?? systemScheme
        let shown = state.shown
        StickySheet(state: state)
            .frame(width: StickyGeometry.paperWidth, height: StickyGeometry.paperHeight)
            // Down in its bubble: shrunk to the bubble's size, tipped, and
            // (at the last moment) faded; out, at full size where it rests.
            .scaleEffect(shown ? 1 : 0.1)
            .rotationEffect(.degrees(shown ? 0 : state.tilt))
            .blur(radius: state.visible ? 0 : 3)
            .opacity(state.visible ? 1 : 0)
            .position(shown ? state.paperCenter : state.anchorPoint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, scheme)
            .environment(\.palette, theme.palette(for: scheme))
            .environment(\.dock, DockStyle.style(for: theme, scheme: scheme))
            .environmentObject(model.store)
            .environmentObject(model.nav)
            .environment(\.openURL, .webOnly)
            .ignoresSafeArea()
    }
}

/// Takes the first click even while another app is in front, so a click on
/// the paper puts the caret there rather than only waking the window.
final class StickyHostingView: NSHostingView<StickyScene> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// An open hand over the strip the note is dragged by. The view is
    /// flipped, so the window's top-left coordinates are its own.
    override func resetCursorRects() {
        super.resetCursorRects()
        if let strip = (window as? StickyPanel)?.strip { addCursorRect(strip, cursor: .openHand) }
    }
}
