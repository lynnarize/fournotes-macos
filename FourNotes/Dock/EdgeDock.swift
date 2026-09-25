import AppKit
import SwiftUI

// The edge dock: a small handle on the edge of the screen, over every app and
// every Space, that opens into a drawer of mini apps — a quick note, today's
// tasks, dictation, a spend, what's due, a question for the assistant.
//
// One borderless panel. It never activates the app, so whatever you were
// working in stays in front; it takes the keyboard only while the drawer is
// open, and gives it back when it closes.

@MainActor
final class EdgeDock: ObservableObject {
    static let shared = EdgeDock()
    static let mainWindowId = "main"

    /// What the shape draws right now; animated between handle and drawer.
    @Published private(set) var geometry: DockGeometry
    @Published private(set) var isOpen = false
    /// The pointer is over the handle: it peeks out a little further.
    @Published private(set) var hovering = false
    @Published private(set) var edge: DockEdge
    @Published private(set) var hidden: Set<MiniApp>
    /// Where each mini app sits: `[near the edge, away from it]`, top to
    /// bottom. Arranged by dragging a card's title bar.
    @Published private(set) var layout: [[MiniApp]]
    /// The drawer's height when last open, so it keeps its size (and its
    /// state) while the window is only as big as the handle.
    @Published private(set) var drawerHeight = DockGeometry.drawerMaxHeight

    // Sticky notes: see "Sticky notes" below.
    /// The bubbles are out beside the handle (or on their way in or out).
    @Published private(set) var islandShown = false
    /// 0 inside the handle … 1 split off to their places.
    @Published private(set) var islandProgress: CGFloat = 0
    /// The notes with a bubble, and where each sits, from the window's top.
    @Published private(set) var bubbleIds: [String] = []
    @Published private(set) var bubbleYs: [CGFloat] = []
    /// The bubble stretched into a pill, and how far (0 … 1).
    @Published private(set) var expandedBubble: String?
    @Published private(set) var expansion: CGFloat = 0
    /// The one before, shrinking back while the next stretches out.
    @Published private(set) var previousBubble: String?
    @Published private(set) var previousExpansion: CGFloat = 0
    /// A bubble that just caught a note swells for a moment.
    @Published private(set) var pulsingBubble: String?
    @Published private(set) var pulse: CGFloat = 0
    /// Bumped by every change to the bubbles, so one that finishes late
    /// doesn't undo a newer one.
    private var islandGeneration = 0
    private var islandTimer: Task<Void, Never>?
    /// Opening a note that just landed: kept apart from `islandTimer`, which
    /// every movement of the pointer restarts.
    private var landTimer: Task<Void, Never>?
    /// Narrowing the island back to just its bubbles, once the pointer has
    /// left them while a note is open (see `rest()`).
    private var restTimer: Task<Void, Never>?
    /// The bubbles are on their way back into the handle.
    private var islandHiding = false
    private var pointerInIsland = false
    private var flight: StickyFlightPanel?

    /// Set by the main window, which is the only thing that can open another.
    var openMainWindow: (() -> Void)?

    private var model: AppModel?
    private var panel: DockPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every open and close, so a close that finishes after the
    /// drawer was opened again doesn't shrink it.
    private var generation = 0
    private var drag: (mouseY: CGFloat, centerY: CGFloat)?

    private enum Key {
        static let enabled = "fournotes.dock.enabled"
        static let edge = "fournotes.dock.edge"
        static let position = "fournotes.dock.position"
        static let screen = "fournotes.dock.screen"
        static let hidden = "fournotes.dock.hidden"
        static let layout = "fournotes.dock.layout"
    }

    private init() {
        let defaults = UserDefaults.standard
        edge = DockEdge(rawValue: defaults.string(forKey: Key.edge) ?? "") ?? .right
        hidden = Set((defaults.string(forKey: Key.hidden) ?? "")
            .split(separator: ",").compactMap { MiniApp(rawValue: String($0)) })
        layout = MiniApp.layout(from: defaults.string(forKey: Key.layout))
        geometry = DockGeometry.handle(in: CGRect(x: 0, y: 0, width: 1440, height: 900), edge: .right, centerY: 450)
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }

    // MARK: - Setup

    func install(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
        // What's "due today" changes at midnight, with nothing else changing.
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        })
        if isEnabled { show() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Key.enabled)
        if on { show() } else { hide() }
        objectWillChange.send()
    }

    private func show() {
        guard let model else { return }
        if panel == nil {
            let panel = DockPanel()
            let host = DockHostingView(rootView: DockScene(model: model, dock: self))
            host.onPointer = { [weak self] point in self?.pointer(point) }
            panel.contentView = host
            self.panel = panel
        }
        layOutHandle()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        // Its only sign on screen is about to go: the microphone can't stay on.
        QuickTranscriber.shared.stop()
        if isOpen { finishClose() }
        panel?.orderOut(nil)
        // Nothing left on screen at all would look like a crash: bring the
        // window back.
        if mainWindow == nil { showApp() }
    }

    // MARK: - Where it sits

    private var screen: NSScreen? {
        let saved = UserDefaults.standard.integer(forKey: Key.screen)
        return NSScreen.screens.first { $0.displayId == saved } ?? NSScreen.screens.first
    }

    private var visible: CGRect { screen?.visibleFrame ?? .zero }

    private var savedCenterY: CGFloat {
        let fraction = UserDefaults.standard.object(forKey: Key.position) as? Double ?? 0.5
        return DockGeometry.centerY(fraction: fraction, in: visible)
    }

    private var handle: DockGeometry {
        DockGeometry.handle(in: visible, edge: edge, centerY: savedCenterY)
    }

    private func layOutHandle() {
        // Only the handle: the island folded away.
        islandGeneration += 1
        islandHiding = false
        islandShown = false
        islandProgress = 0
        expandedBubble = nil
        expansion = 0
        previousBubble = nil
        previousExpansion = 0
        pulsingBubble = nil
        pulse = 0
        let g = handle
        geometry = g
        panel?.setFrame(g.frame, display: true)
    }

    private func screensChanged() {
        guard panel?.isVisible == true else { return }
        if isOpen { finishClose() } else { layOutHandle() }
        restoreIsland()
    }

    /// The body in the window's own coordinates (origin top-left, as
    /// `DockHostingView.point(of:)` reports the pointer), for hover and for
    /// letting clicks beside it through.
    private var bodyRect: CGRect {
        guard let panel else { return .zero }
        let size = panel.frame.size
        let width = isOpen ? geometry.bodyWidth : DockGeometry.handlePeekWidth
        let x = edge == .right ? size.width - width : 0
        return CGRect(x: x, y: geometry.centerFromTop - geometry.bodyHeight / 2,
                      width: width, height: geometry.bodyHeight)
    }

    func setEdge(_ next: DockEdge) {
        guard next != edge else { return }
        if isOpen { finishClose() }
        edge = next
        UserDefaults.standard.set(next.rawValue, forKey: Key.edge)
        layOutHandle()
        restoreIsland()
    }

    var screens: [(id: Int, name: String)] {
        NSScreen.screens.map { ($0.displayId, $0.localizedName) }
    }

    var screenId: Int { screen?.displayId ?? 0 }

    func moveToScreen(_ id: Int) {
        if isOpen { finishClose() }
        UserDefaults.standard.set(id, forKey: Key.screen)
        layOutHandle()
        restoreIsland()
        objectWillChange.send()
    }

    func setHidden(_ app: MiniApp, _ isHidden: Bool) {
        if isHidden { hidden.insert(app) } else { hidden.remove(app) }
        UserDefaults.standard.set(MiniApp.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ","),
                                  forKey: Key.hidden)
    }

    // MARK: - Arranging the mini apps

    /// Moves `app` to `index` in `column` (0 near the edge, 1 away from it).
    func move(_ app: MiniApp, toColumn column: Int, index: Int) {
        var next = layout.map { $0.filter { $0 != app } }
        guard next.indices.contains(column) else { return }
        next[column].insert(app, at: min(max(0, index), next[column].count))
        guard next != layout else { return }
        layout = next
        UserDefaults.standard.set(MiniApp.encode(next), forKey: Key.layout)
    }

    func resetLayout() {
        layout = MiniApp.defaultLayout
        UserDefaults.standard.removeObject(forKey: Key.layout)
    }

    // MARK: - Dragging the handle along the edge

    /// A drag that ended without saying so (the gesture was cancelled):
    /// forget its anchor, or the next one starts from the stale point.
    func dragCancelled() {
        // A turn later: a drag that ends normally reports that it's over
        // before or after onEnded, and onEnded still needs the anchor.
        DispatchQueue.main.async { [weak self] in self?.drag = nil }
    }

    func dragChanged() {
        guard !isOpen else { return }
        let mouseY = NSEvent.mouseLocation.y
        if drag == nil { drag = (mouseY, handle.screenCenterY) }
        guard let drag else { return }
        // A click leaves the island be; a drag folds it away.
        if islandShown {
            guard abs(mouseY - drag.mouseY) > 3 else { return }
            layOutHandle()
        }

        let g = DockGeometry.handle(in: visible, edge: edge, centerY: drag.centerY + mouseY - drag.mouseY)
        geometry = g
        panel?.setFrame(g.frame, display: true)
    }

    /// True when it was a drag; false when the pointer barely moved — a click.
    func dragEnded() -> Bool {
        defer { drag = nil }
        guard let drag else { return false }
        let moved = abs(NSEvent.mouseLocation.y - drag.mouseY) > 3
        let fraction = DockGeometry.fraction(of: geometry.screenCenterY, in: visible)
        UserDefaults.standard.set(Double(fraction), forKey: Key.position)
        // Once the drag has let go of it (a click opens the drawer instead).
        if moved { DispatchQueue.main.async { [weak self] in self?.restoreIsland() } }
        return moved
    }

    private func setHovering(_ inside: Bool) {
        guard inside != hovering else { return }
        withAnimation(Motion.standard) { hovering = inside }
    }

    // MARK: - Open and close

    func toggle() {
        if !isEnabled { setEnabled(true) }
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen, let panel else { return }
        generation += 1
        let closed = handle
        let drawer = DockGeometry.drawer(in: visible, edge: edge, centerY: closed.screenCenterY)

        // Grow the window first, with the handle drawn exactly where it was;
        // then let the shape spring out to the drawer. Resizing the window
        // mid-animation would make it jump.
        islandTimer?.cancel()
        if islandShown { layOutHandle() }
        geometry = closed.handle(placedIn: drawer.frame)
        drawerHeight = drawer.bodyHeight
        panel.setFrame(drawer.frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        isOpen = true
        hovering = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(Motion.reduce ? Motion.instant : .spring(response: 0.42, dampingFraction: 0.84)) {
                self.geometry = drawer
            }
        }
        panel.allowsKey = true
        panel.makeKey()
        watchOutside()
    }

    func close() {
        guard isOpen, let panel else { return }
        generation += 1
        let current = generation
        stopWatching()
        let target = handle.handle(placedIn: panel.frame)
        let reduce = Motion.reduce
        withAnimation(reduce ? Motion.instant : .spring(response: 0.34, dampingFraction: 0.92)) {
            geometry = target
            isOpen = false
        }
        // On a timer rather than the animation's completion, which never
        // arrived when the panel wasn't key — leaving a large, invisible
        // window over the edge of the screen, swallowing clicks.
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.36)) { [weak self] in
            guard let self, self.generation == current, !self.isOpen else { return }
            self.finishClose()
        }
    }

    /// Shrinks the window back to the handle and hands the keyboard back.
    private func finishClose() {
        stopWatching()
        isOpen = false
        layOutHandle()
        model?.store.flush()
        releaseKeyboard()
        restoreIsland()
    }

    /// Hands the keyboard back to whatever had it before the dock took it.
    private func releaseKeyboard() {
        guard let panel else { return }
        panel.allowsKey = false
        guard panel.isKeyWindow else { return }
        if NSApp.isActive, let main = mainWindow, !main.isMiniaturized {
            main.makeKey()
        } else {
            // A non-activating panel that orders out gives the keyboard back
            // to the app in front.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Clicks elsewhere close it

    private func watchOutside() {
        stopWatching()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        // Local monitors run on the main thread; the event just isn't marked Sendable.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                // Menus the drawer opens are their own windows; clicks in
                // them belong to the drawer.
                guard let self, let window = event.window else { return }
                if window === self.panel {
                    // The shadow's margin is part of the window, but not of
                    // the drawer: a click there is a click beside it.
                    let point = (window.contentView as? DockHostingView)?.point(of: event) ?? .zero
                    if !self.bodyRect.insetBy(dx: 0, dy: -DockGeometry.drawerFillet).contains(point) {
                        self.close()
                    }
                } else if window.level.rawValue < NSWindow.Level.popUpMenu.rawValue,
                          !(window is NSPanel) || window.isSheet {
                    self.close()
                }
            }
            return event
        }) { monitors.append(local) }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            nonisolated(unsafe) let event = event
            let escape = MainActor.assumeIsolated {
                guard let self, event.window === self.panel, event.keyCode == 53 else { return false }
                self.close()
                return true
            }
            return escape ? nil : event
        }) { monitors.append(keys) }
    }

    private func stopWatching() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    // MARK: - Into the app

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0 !== panel && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    /// Brings the main window forward — opening one if it was closed — and
    /// then goes wherever `go` says.
    func showApp(_ go: @escaping @MainActor (Navigation) -> Void = { _ in }) {
        close()
        NSApp.activate()
        if !revealMainWindow() {
            // No window has appeared in this run, so there is no openWindow
            // to call. Asking the app to reopen makes SwiftUI create one.
            Self.reopen()
        }
        if let nav = model?.nav { go(nav) }
    }

    /// Brings the main window forward — out of the Dock if it was
    /// minimised, or a new one if it was closed. False when no window has
    /// appeared in this run, so there's no way to open one from here.
    @discardableResult
    func revealMainWindow() -> Bool {
        if let main = mainWindow {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
            return true
        }
        guard let openMainWindow else { return false }
        openMainWindow()
        return true
    }
}

// MARK: - Sticky notes

// Each stuck note is a bubble that splits off the handle. The pointer on
// the handle brings them out of its top and bottom, along the edge. On a
// bubble, it stretches into a pill with the note's title; a click pops the
// note out into its own window beside the edge (see StickyWindow.swift).
// Away from the handle and the bubbles, they draw back in — unless a note is
// open: then they stay out, narrowed to just the bubbles, so the note has
// its bubble to go back into.

extension EdgeDock {
    private var stickyIds: [String] { EdgeStickies.shared.shownIds }

    /// Pops a stuck note out of its bubble into its own window (closing the
    /// drawer, if it's open — the bubbles come back out once it has).
    func openSticky(_ id: String) {
        if isOpen { close() } else { showIsland() }
        StickyWindows.shared.show(id, from: stickyAnchor(id), edge: edge, visible: visible)
        // Opened from elsewhere (the menu, a new note): the bubbles rest.
        if !pointerInIsland { rest() }
    }

    /// A note is open: its bubble stays out beside the handle.
    private var stickyPinned: Bool { StickyWindows.shared.hasOpen && !stickyIds.isEmpty }

    /// Not being pointed at while a note is open: just the bubbles, in a
    /// window only as wide as they are, so it doesn't sit over the note.
    private var islandResting: Bool { stickyPinned && !pointerInIsland && expandedBubble == nil }

    /// Brings the bubbles back out after something folded them away — the
    /// drawer, a drag, a move — while a note is open.
    private func restoreIsland() {
        if stickyPinned { showIsland() }
    }

    /// A minimized note just dropped into its bubble: it swells as it
    /// catches it, and with no note left open, they all go back in.
    func stickyReturned(_ id: String) {
        swell(id)
        guard !stickyPinned else { return }
        islandTimer?.cancel()
        islandTimer = after(0.9) { if !self.pointerInIsland { self.hideIsland() } }
    }

    /// Where a note goes back to on screen: its bubble while they're out,
    /// otherwise the handle it's tucked into.
    func stickyAnchor(_ id: String) -> CGPoint {
        if islandShown, let panel, let index = bubbleIds.firstIndex(of: id) {
            let frame = panel.frame
            let bubble = StickyGeometry.bubbleRect(width: frame.width, edge: edge, centerY: bubbleYs[index])
            return CGPoint(x: frame.minX + bubble.midX, y: frame.maxY - bubble.midY)
        }
        let x = edge == .right ? visible.maxX - DockGeometry.handleWidth / 2 : visible.minX + DockGeometry.handleWidth / 2
        return CGPoint(x: x, y: handle.screenCenterY)
    }

    /// The stuck notes changed — one added, taken off, deleted, or the space
    /// switched.
    func stickiesChanged() {
        StickyWindows.shared.keep(stickyIds)
        guard islandShown else { return }
        if stickyIds.isEmpty { hideIsland() } else { placeIsland() }
    }

    // MARK: Out and back in

    /// Sizes the window for the bubbles (the handle staying exactly where it
    /// is) and works out where each sits.
    private func placeIsland() {
        guard let panel else { return }
        let ids = Array(stickyIds.suffix(StickyGeometry.maxBubbles))
        let slots = StickyGeometry.bubbleSlots(count: ids.count, handleY: handle.screenCenterY, in: visible)
        let window = StickyGeometry.islandWindow(handle: handle.frame, edge: edge, slots: slots,
                                                 wide: !islandResting)
        let placed = handle.handle(placedIn: window)
        let ys = slots.map { window.maxY - $0 }
        // Only what changed: this runs as the pointer moves.
        if geometry != placed { geometry = placed }
        if bubbleIds != ids { bubbleIds = ids }
        if bubbleYs != ys { bubbleYs = ys }
        if let id = expandedBubble, !ids.contains(id) { expandedBubble = nil; expansion = 0 }
        guard panel.frame != window else { return }
        panel.setFrame(window, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    /// Splits the bubbles off the handle.
    private func showIsland() {
        guard !islandShown || islandHiding, !isOpen, drag == nil, !stickyIds.isEmpty, panel != nil else { return }
        // On their way in: turned round, rather than folded away regardless.
        islandGeneration += 1
        islandHiding = false
        placeIsland()
        islandShown = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.islandShown, !self.islandHiding else { return }
            withAnimation(Motion.reduce ? Motion.instant : .spring(response: 0.55, dampingFraction: 0.68)) {
                self.islandProgress = 1
            }
        }
    }

    /// Draws a stretched bubble in, then all of them back into the handle —
    /// or, while a note is open, only narrows them to rest.
    private func hideIsland() {
        guard islandShown, !islandHiding else { return }
        if stickyPinned {
            rest()
            return
        }
        restTimer?.cancel()
        restTimer = nil
        islandGeneration += 1
        islandHiding = true
        let current = islandGeneration
        let reduce = Motion.reduce
        withAnimation(reduce ? Motion.instant : .spring(response: 0.3, dampingFraction: 0.86)) {
            expansion = 0
            previousExpansion = 0
        }
        withAnimation(reduce ? Motion.instant : .spring(response: 0.42, dampingFraction: 0.82).delay(0.1)) {
            islandProgress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduce ? 0 : 0.6)) { [weak self] in
            guard let self, self.islandGeneration == current, !self.isOpen else { return }
            self.layOutHandle()
        }
    }

    /// Draws a stretched bubble back in, then narrows the window to just the
    /// bubbles. Once: the pointer moving about over the note mustn't keep
    /// putting it off.
    private func rest() {
        guard expandedBubble != nil else {
            // No pill to wait for.
            restTimer?.cancel()
            restTimer = nil
            if islandShown, islandResting { placeIsland() }
            return
        }
        expand(nil)
        guard restTimer == nil else { return }
        restTimer = after(0.4) {
            self.restTimer = nil
            if self.islandShown, self.islandResting { self.placeIsland() }
        }
    }

    /// Stretches one bubble into its pill (and the one before back), or all back.
    private func expand(_ id: String?) {
        guard islandShown, id != expandedBubble else { return }
        let reduce = Motion.reduce
        previousBubble = expandedBubble
        previousExpansion = expansion
        expandedBubble = id
        expansion = 0
        withAnimation(reduce ? Motion.instant : .spring(response: 0.4, dampingFraction: 0.74)) {
            if id != nil { expansion = 1 }
            previousExpansion = 0
        }
    }

    // MARK: Arriving

    /// A note was just stuck: the bubbles come out, and the note flies from
    /// `from` into its own.
    func receiveSticky(_ id: String, from: CGPoint) {
        if !isEnabled { setEnabled(true) }
        let wasOpen = isOpen
        if wasOpen { close() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasOpen ? 0.4 : 0)) { [weak self] in
            self?.launch(id, from: from)
        }
    }

    private func launch(_ id: String, from: CGPoint) {
        islandTimer?.cancel()
        if islandShown { placeIsland() } else { showIsland() }
        guard let panel, islandShown, let index = bubbleIds.firstIndex(of: id), !Motion.reduce else {
            land(id)
            return
        }
        let frame = panel.frame
        let bubble = StickyGeometry.bubbleRect(width: frame.width, edge: edge, centerY: bubbleYs[index])
        let target = CGPoint(x: frame.minX + bubble.midX, y: frame.maxY - bubble.midY)
        let stickies = EdgeStickies.shared
        flight?.orderOut(nil)
        let flight = StickyFlightPanel(from: from, to: target,
                                       tint: stickies.placement(id)?.color ?? .yellow,
                                       title: stickies.note(id)?.title ?? "") { [weak self] in
            self?.land(id)
        }
        self.flight = flight
        flight.orderFrontRegardless()
    }

    /// The note reached its bubble: it swells as it catches it, and settles.
    private func land(_ id: String) {
        swell(id)
        islandTimer?.cancel()
        landTimer?.cancel()
        if EdgeStickies.shared.focusOnOpen == id {
            // A new note, made to be written in straight away, opens.
            landTimer = after(0.45) { self.openSticky(id) }
        } else {
            // Out for a moment so it's plain where it went, then away.
            islandTimer = after(1.6) { if !self.pointerInIsland { self.hideIsland() } }
        }
    }

    private func swell(_ id: String) {
        pulsingBubble = id
        withAnimation(Motion.reduce ? Motion.instant : .spring(response: 0.22, dampingFraction: 0.45)) {
            pulse = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { self?.pulse = 0 }
        }
    }

    // MARK: The pointer

    /// Where the pointer is over the window (top-left coordinates, like
    /// SwiftUI's and `bodyRect`), or nil when it left.
    fileprivate func pointer(_ point: CGPoint?) {
        let onHandle = point.map { bodyRect.insetBy(dx: -2, dy: -2).contains($0) } ?? false
        setHovering(onHandle)
        guard !isOpen, drag == nil, !stickyIds.isEmpty, let panel else {
            pointerInIsland = false
            return
        }
        let width = panel.frame.width
        var over: String?
        if islandShown, let p = point {
            for (id, y) in zip(bubbleIds, bubbleYs) {
                let rect = id == expandedBubble
                    ? StickyGeometry.pillRect(width: width, edge: edge, centerY: y)
                    : StickyGeometry.bubbleRect(width: width, edge: edge, centerY: y)
                if rect.insetBy(dx: -4, dy: -StickyGeometry.bubbleGap / 2).contains(p) { over = id }
            }
        }
        // The strip along the edge from the first bubble to the last, so
        // moving between them (or from the handle) keeps them out.
        var inStrip = false
        if islandShown, let p = point, let top = bubbleYs.min(), let bottom = bubbleYs.max() {
            let span = StickyGeometry.bubbleInset + StickyGeometry.bubble + 8
            let minY = min(top, geometry.centerFromTop) - StickyGeometry.bubble / 2 - 8
            let maxY = max(bottom, geometry.centerFromTop) + StickyGeometry.bubble / 2 + 8
            let strip = CGRect(x: edge == .right ? width - span : 0, y: minY, width: span, height: maxY - minY)
            inStrip = strip.contains(p)
        }
        pointerInIsland = onHandle || over != nil || inStrip
        if islandShown, pointerInIsland {
            // Resting narrow while a note is open: wide again, for the pills.
            restTimer?.cancel()
            restTimer = nil
            placeIsland()
        }

        islandTimer?.cancel()
        if !islandShown || islandHiding {
            if onHandle { islandTimer = after(0.1) { self.showIsland() } }
        } else if let over, over != expandedBubble {
            islandTimer = after(0.08) { self.expand(over) }
        } else if over == nil, expandedBubble != nil, pointerInIsland {
            islandTimer = after(0.25) { self.expand(nil) }
        } else if !pointerInIsland, stickyPinned {
            rest()
        } else if !pointerInIsland {
            islandTimer = after(0.3) {
                guard !self.pointerInIsland else { return }
                self.hideIsland()
            }
        }
    }

    @discardableResult
    private func after(_ seconds: Double, _ run: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            run()
        }
    }
}

extension EdgeDock {
    /// Sends this app the "reopen" event the Dock sends when its icon is
    /// clicked with no windows open.
    fileprivate static func reopen() {
        let target = NSAppleEventDescriptor(processIdentifier: ProcessInfo.processInfo.processIdentifier)
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: [.noReply], timeout: 1)
    }
}

// MARK: - The panel

final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        setAccessibilityLabel("Four Notes edge dock")
    }

    /// Only while the drawer is open. A click or drag on the closed handle
    /// used to make the panel key, quietly taking the keyboard from the app
    /// in front — typing went nowhere.
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    /// Borderless windows may sit partly off screen; the drawer's shadow does.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the dock's SwiftUI. Takes the first click even when another app is
/// in front, and tracks the pointer itself: SwiftUI's hover only reports
/// while this app is active, and the dock is mostly used while it isn't.
final class DockHostingView: NSHostingView<DockScene> {
    /// Where the pointer is (see `point(of:)`); nil when it left.
    var onPointer: (CGPoint?) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    /// An event's location with the origin at the top left, as SwiftUI lays
    /// things out. A hosting view is flipped, so converting already gives
    /// that; flipping it again (as this once did) went unnoticed while the
    /// window was always centred on the handle, and put the pointer on the
    /// wrong side once the sticky notes' bubbles made it lopsided.
    func point(of event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer(point(of: event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer(point(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer(nil)
    }
}

extension NSScreen {
    var displayId: Int {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
    }
}

/// Hands the main window's `openWindow` to the dock, so "Open Four Notes" can
/// bring back a window that was closed.
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let open = openWindow
                EdgeDock.shared.openMainWindow = { open(id: EdgeDock.mainWindowId) }
            }
    }
}
