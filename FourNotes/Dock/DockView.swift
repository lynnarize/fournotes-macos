import SwiftUI

// What the edge dock draws: the handle while closed, the drawer of mini apps
// while open, and the one shape that grows from one into the other.

enum MiniApp: String, CaseIterable, Identifiable, Hashable {
    case note, tasks, bills, transcribe, spend, ask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .note: return "Quick note"
        case .tasks: return "Today"
        case .bills: return "Coming up"
        case .transcribe: return "Transcribe"
        case .spend: return "Spend"
        case .ask: return "Ask"
        }
    }

    /// Where each starts: Today, what's due and Ask in the column nearest the
    /// edge — under the pointer that just opened the drawer.
    static let defaultLayout: [[MiniApp]] = [[.tasks, .bills, .ask], [.note, .transcribe, .spend]]

    /// "tasks,bills,ask|note,transcribe,spend" back into columns. Anything
    /// unknown or repeated is dropped; anything missing (a mini app added in
    /// an update) goes where it starts by default.
    static func layout(from saved: String?) -> [[MiniApp]] {
        guard let saved, !saved.isEmpty else { return defaultLayout }
        var seen = Set<MiniApp>()
        var columns = saved.components(separatedBy: "|").prefix(2).map { column in
            column.split(separator: ",").compactMap { MiniApp(rawValue: String($0)) }
                .filter { seen.insert($0).inserted }
        }
        while columns.count < 2 { columns.append([]) }
        for (index, column) in defaultLayout.enumerated() {
            for app in column where !seen.contains(app) { columns[index].append(app) }
        }
        return columns
    }

    static func encode(_ layout: [[MiniApp]]) -> String {
        layout.map { $0.map(\.rawValue).joined(separator: ",") }.joined(separator: "|")
    }
}

/// The dock's root: the shared objects and the theme, resolved once.
struct DockScene: View {
    let model: AppModel
    @ObservedObject var dock: EdgeDock
    @AppStorage("fournotes.theme") private var themeRaw = ThemeChoice.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let theme = ThemeChoice(rawValue: themeRaw) ?? .system
        let scheme = theme.colorScheme ?? systemScheme
        let style = DockStyle.style(for: theme, scheme: scheme)
        DockRoot(dock: dock)
            .environment(\.colorScheme, scheme)
            .environment(\.palette, theme.palette(for: scheme))
            .environment(\.dock, style)
            .tint(style.accent)
            .environmentObject(model.store)
            .environmentObject(model.nav)
            .environmentObject(model.toasts)
            .environmentObject(model.assistant)
            .environmentObject(model.engine)
            .environment(\.openURL, .webOnly)
    }
}

struct DockRoot: View {
    @ObservedObject var dock: EdgeDock
    @ObservedObject private var stickies = EdgeStickies.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let g = shown
            let mirrored = dock.edge == .left
            let shape = EdgeTabShape(g, mirrored: mirrored)
            let drawerWindow = width > DockGeometry.handlePeekWidth + DockGeometry.handleMargin + 1
            ZStack(alignment: .topLeading) {
                // Stuck notes, a bubble each, split off the handle's top and
                // bottom. Behind the handle, which hides where they come from.
                if dock.islandShown {
                    StickyIsland(dock: dock, progress: dock.islandProgress, expansion: dock.expansion,
                                 previousExpansion: dock.previousExpansion, pulse: dock.pulse,
                                 ids: dock.bubbleIds, ys: dock.bubbleYs, expanded: dock.expandedBubble,
                                 previous: dock.previousBubble, pulsing: dock.pulsingBubble,
                                 handleCenter: CGPoint(x: x(for: DockGeometry.handleWidth, in: width),
                                                       y: g.centerFromTop),
                                 handleHalf: g.bodyHeight / 2, edge: dock.edge, width: width,
                                 fill: d.materialSolid)
                }

                // The closed handle's soft shadow, kept outside it: under the
                // see-through body it would darken the handle itself. None on
                // the open drawer: it spread a grey band over the app beside
                // it, and the thin edge is enough to set it apart.
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                    .mask {
                        Rectangle()
                            .overlay { shape.fill(Color.black).blendMode(.destinationOut) }
                            .compositingGroup()
                    }
                    .opacity(dock.isOpen ? 0 : 1)
                    .allowsHitTesting(false)
                // The desktop behind, blurred, under a tint of the theme.
                DockMaterial(shape: shape)
                shape.fill(d.material)
                // A hairline edge, so the body reads against apps of its own colour.
                shape.stroke(d.hair, lineWidth: 1)

                ZStack(alignment: .topLeading) {
                    HandleFace(dock: dock)
                        .frame(width: g.bodyWidth, height: DockGeometry.handleHeight)
                        .position(x: x(for: g.bodyWidth, in: width), y: g.centerFromTop)
                        .opacity(dock.isOpen ? 0 : 1)
                        .allowsHitTesting(!dock.isOpen)

                    // Always there, only hidden while closed: a click beside the
                    // drawer must not cost a draft, a reply on its way or the
                    // scroll position. Clipped away by the handle's shape.
                    let showsDrawer = dock.isOpen
                    DrawerView(dock: dock)
                        .frame(width: DockGeometry.drawerWidth, height: dock.drawerHeight)
                        .position(x: x(for: DockGeometry.drawerWidth, in: width),
                                  y: drawerWindow ? proxy.size.height / 2 : g.centerFromTop)
                        .opacity(showsDrawer ? 1 : 0)
                        .allowsHitTesting(showsDrawer)
                        .accessibilityHidden(!showsDrawer)
                }
                .clipShape(shape)
            }
        }
        .ignoresSafeArea()
    }

    /// The geometry as drawn: the handle peeks out further under the pointer.
    private var shown: DockGeometry {
        var g = dock.geometry
        if !dock.isOpen && dock.hovering { g.bodyWidth = DockGeometry.handlePeekWidth }
        return g
    }

    private func x(for bodyWidth: CGFloat, in width: CGFloat) -> CGFloat {
        dock.edge == .right ? width - bodyWidth / 2 : bodyWidth / 2
    }

}

// MARK: - The handle

private struct HandleFace: View {
    @ObservedObject var dock: EdgeDock
    @GestureState private var dragging = false
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var assistant: Assistant
    @ObservedObject private var transcriber = QuickTranscriber.shared
    @Environment(\.dock) private var d

    var body: some View {
        let due = Glance.dueByToday(store.liveTodos)
        let done = Glance.doneToday(store.liveTodos).count
        let total = due.count + done
        VStack(spacing: 7) {
            Icon(dock.edge == .right ? "chevronLeft" : "chevron", size: 11, weight: 2.6)
                .foregroundStyle(d.muted)
                .opacity(dock.hovering ? 1 : 0)
                .frame(height: dock.hovering ? 11 : 0)

            if transcriber.phase == .listening || assistant.recording {
                LiveBadge(levels: transcriber.phase == .listening ? transcriber.levels : [])
            } else {
                // The ring fills as the day's tasks are done; full, with a
                // check, once nothing is left.
                ZStack {
                    Circle().inset(by: 1.25).stroke(d.track, lineWidth: 2.5)
                    Circle()
                        .inset(by: 1.25)
                        .trim(from: 0, to: due.isEmpty ? 1 : total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                        .stroke(d.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(Motion.data, value: done)
                    if due.isEmpty {
                        Icon("check", size: 10, weight: 3.2).foregroundStyle(d.accent)
                    } else {
                        Text("\(due.count)")
                            .font(FN.font(11, .medium))
                            .monospacedDigit()
                            .foregroundStyle(d.text)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 21, height: 21)
            }
        }
        .animation(Motion.standard, value: dock.hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { _ in dock.dragChanged() }
            .onEnded { _ in if !dock.dragEnded() { dock.open() } })
        // Reset on cancel too, which onEnded never hears about.
        .onChange(of: dragging) { _, now in if !now { dock.dragCancelled() } }
        .contextMenu { HandleMenu(dock: dock) }
        .help(due.isEmpty ? "Four Notes — nothing due today" : "Four Notes — \(due.count) due today")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Four Notes edge dock")
        .accessibilityValue(due.isEmpty ? "Nothing due today" : "\(due.count) due today")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dock.open() }
    }
}

/// Recording: a red dot and the level, so it's plain the microphone is on
/// even with the drawer closed.
private struct LiveBadge: View {
    @Environment(\.dock) private var d
    let levels: [Float]
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 6) {
            Circle().fill(d.danger)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.35 : 1)
                .animation(Motion.pulse, value: pulse)
                .onAppear { pulse = true }
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let level = levels.isEmpty ? 0.3 : CGFloat(levels[max(0, levels.count - 1 - i * 3)])
                    Capsule().fill(d.danger)
                        .frame(width: 2.5, height: 4 + 14 * level)
                }
            }
            .frame(height: 18)
            .animation(.linear(duration: 0.08), value: levels)
        }
    }
}

private struct HandleMenu: View {
    @ObservedObject var dock: EdgeDock
    @ObservedObject private var stickies = EdgeStickies.shared

    var body: some View {
        Button("Open Drawer") { dock.open() }
        Button("Open Four Notes") { dock.showApp() }
        Divider()
        Menu("Sticky Notes") {
            ForEach(stickies.shownIds, id: \.self) { id in
                Button(stickies.note(id).map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Untitled") {
                    dock.openSticky(id)
                }
            }
            if !stickies.shownIds.isEmpty { Divider() }
            Button("New Sticky Note") { stickies.stickNew() }
        }
        Divider()
        Picker("Edge", selection: Binding(get: { dock.edge }, set: { dock.setEdge($0) })) {
            Text("Right Edge").tag(DockEdge.right)
            Text("Left Edge").tag(DockEdge.left)
        }
        .pickerStyle(.inline)
        Divider()
        Button("Hide Edge Dock") { dock.setEnabled(false) }
    }
}

// MARK: - The drawer

private struct DrawerView: View {
    @ObservedObject var dock: EdgeDock
    @EnvironmentObject private var store: Store
    @Environment(\.dock) private var d

    // Dragging a card by its title bar. Everything is measured in the scroll
    // view's own (visible) space, so it holds while the content scrolls.
    nonisolated static let space = "dock.drawer"
    @State private var frames: [MiniApp: CGRect] = [:]
    @State private var dragging: MiniApp?
    @State private var pointer: CGPoint = .zero
    /// Where in the card it was picked up, so it doesn't jump to the pointer.
    @State private var grab: CGSize = .zero
    @State private var viewport: CGSize = .zero
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var scrollY: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var autoScroll: Task<Void, Never>?
    /// Ends the drag on any mouse-up, whatever happened to the gesture.
    @State private var mouseUp: Any?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                // One container for both columns, not two stacks: a card that
                // moved between stacks became a new view mid-drag, the drag
                // gesture died with the old one, and the card stayed lifted.
                TwoColumns(spacing: 10) {
                    ForEach(placed, id: \.app) { item in
                        card(item.app, column: item.column)
                            .layoutValue(key: ColumnKey.self, value: visual(item.column))
                    }
                    // An empty column still takes a card dropped into it.
                    ForEach([0, 1].filter(columnIsEmpty), id: \.self) { column in
                        emptyColumn
                            .layoutValue(key: ColumnKey.self, value: visual(column))
                    }
                }
                .animation(Motion.standard, value: dock.hidden)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in scrollY = y }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentSize.height }) { _, h in contentHeight = h }
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { viewport = $0 }
            .coordinateSpace(.named(Self.space))
            .onChange(of: dock.isOpen) { _, open in if !open { dragEnded() } }
            // Cards slide under a soft edge rather than being cut off — while
            // there is more below; at the end the last card shows whole.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: moreBelow ? 22 : 0)
            })
            .animation(Motion.quick, value: moreBelow)
        }
    }

    private var moreBelow: Bool { scrollY < contentHeight - viewport.height - 1 }

    private var header: some View {
        HStack(spacing: 12) {
            Logo(size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(FN.font(17, .medium))
                    .tracking(-0.25)
                    .foregroundStyle(d.text)
                Text(summary)
                    .font(FN.font(12))
                    .monospacedDigit()
                    .foregroundStyle(d.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                MenuButton(help: "Customize the drawer", entries: { customizeEntries }) {
                    HeaderMenuLabel(icon: "sliders")
                }
                DockRoundButton(icon: "arrowUpRight", help: "Open Four Notes", size: 30, look: .filled) {
                    dock.showApp()
                }
                DockRoundButton(icon: "x", help: "Close (Esc)", size: 30, look: .filled) { dock.close() }
            }
        }
    }

    /// One line of where the day stands: what's left, and what's been spent.
    private var summary: String {
        let due = Glance.dueByToday(store.liveTodos).count
        let spent = FinanceMath.spend(store.liveTransactions.filter { $0.date == DateKit.localDate() },
                                      store.settings.currency)
        let tasks = due == 0 ? "Nothing due" : "\(due) due today"
        let money = spent == 0 ? "no spending yet"
            : "\(Money.format(spent, store.settings.currency, compact: true)) spent"
        return "\(tasks) · \(money)"
    }

    private var customizeEntries: [MenuEntry] {
        var entries: [MenuEntry] = [.header("Show")]
        entries += MiniApp.allCases.map { app in
            .item(app.title, checked: !dock.hidden.contains(app)) {
                dock.setHidden(app, !dock.hidden.contains(app))
            }
        }
        entries += [.divider,
                    .item("Right Edge", checked: dock.edge == .right) { dock.setEdge(.right) },
                    .item("Left Edge", checked: dock.edge == .left) { dock.setEdge(.left) }]
        let screens = dock.screens
        if screens.count > 1 {
            entries.append(.menu("Screen", screens.map { screen in
                .item(screen.name, checked: screen.id == dock.screenId) { dock.moveToScreen(screen.id) }
            }))
        }
        entries += [.divider,
                    .item("Reset Layout", enabled: dock.layout != MiniApp.defaultLayout) {
                        withAnimation(Motion.standard) { dock.resetLayout() }
                    },
                    .item("Hide Edge Dock") { dock.setEnabled(false) }]
        return entries
    }

    /// Every visible card and the column it's in (0 near the edge).
    private var placed: [(app: MiniApp, column: Int)] {
        dock.layout.enumerated().flatMap { column, apps in
            apps.filter { !dock.hidden.contains($0) }.map { ($0, column) }
        }
    }

    /// On the right edge the near column is the right-hand one.
    private func visual(_ column: Int) -> Int { dock.edge == .right ? 1 - column : column }

    private func columnIsEmpty(_ column: Int) -> Bool {
        dock.layout[column].allSatisfy(dock.hidden.contains)
    }

    private var emptyColumn: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(d.hairStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            .frame(height: 120)
            .overlay(Text("Drag a card here").font(FN.font(12)).foregroundStyle(d.muted))
            .opacity(dragging == nil ? 0 : 1)
    }

    private func card(_ app: MiniApp, column: Int) -> some View {
        let lifted = dragging == app
        let slot = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack {
            // The slot it will land in.
            if lifted {
                slot.fill(d.accentSubtle)
                    .overlay(slot.strokeBorder(d.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .opacity(0.7)
            }
            miniApp(app)
                .environment(\.cardDrag, CardDrag(
                    lifted: lifted,
                    changed: { dragChanged(app, $0) },
                    ended: { dragEnded() }))
                // Picked up, the card needs a body of its own: see-through,
                // it showed the slot and the cards it passed over.
                .background { if lifted { slot.fill(d.materialSolid) } }
                .offset(lifted ? liftOffset(app) : .zero)
                .scaleEffect(lifted ? 1.025 : 1)
                .shadow(color: lifted ? d.lift : .clear, radius: lifted ? 20 : 0, y: lifted ? 18 : 0)
                .shadow(color: .black.opacity(lifted ? 0.1 : 0), radius: lifted ? 5 : 0, y: lifted ? 3 : 0)
                .animation(Motion.quick, value: lifted)
        }
        // Measured outside the offset: this is the slot, not the lifted card.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frames[app] = $0 }
        .zIndex(lifted ? 1 : 0)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .accessibilityActions {
            let position = dock.layout[column].firstIndex(of: app) ?? 0
            if position > 0 {
                Button("Move up") { withAnimation(Motion.standard) { dock.move(app, toColumn: column, index: position - 1) } }
            }
            if position < dock.layout[column].count - 1 {
                Button("Move down") { withAnimation(Motion.standard) { dock.move(app, toColumn: column, index: position + 1) } }
            }
            Button("Move to the other column") {
                withAnimation(Motion.standard) { dock.move(app, toColumn: 1 - column, index: .max) }
            }
        }
    }

    // MARK: Dragging

    private func liftOffset(_ app: MiniApp) -> CGSize {
        guard let slot = frames[app] else { return .zero }
        return CGSize(width: pointer.x - grab.width - slot.minX, height: pointer.y - grab.height - slot.minY)
    }

    private func dragChanged(_ app: MiniApp, _ value: DragGesture.Value) {
        if dragging != app {
            guard let slot = frames[app] else { return }
            grab = CGSize(width: value.startLocation.x - slot.minX, height: value.startLocation.y - slot.minY)
            dragging = app
            watchMouseUp()
        }
        // Held inside the drawer: dragged past its edge, the card was cut off.
        // Kept a little in from the top and bottom, where the edge fades,
        // so the card's title stays in sight while the list scrolls under it.
        pointer = CGPoint(x: min(max(value.location.x, 0), viewport.width),
                          y: min(max(value.location.y, 24), max(24, viewport.height - 24)))
        reorder(app)
        updateAutoScroll()
    }

    private func dragEnded() {
        guard dragging != nil else { return }
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        mouseUp = nil
        autoScroll?.cancel()
        autoScroll = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { dragging = nil }
    }

    /// The gesture can be cancelled without telling anyone — the view it was
    /// on replaced, the drawer closed under it. The mouse button coming up is
    /// the one thing that always ends a drag.
    private func watchMouseUp() {
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        mouseUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            DispatchQueue.main.async { dragEnded() }
            return event
        }
    }

    /// Makes room where the lifted card is: the column under the pointer, and
    /// the place among that column's cards where the card's middle now is.
    private func reorder(_ app: MiniApp) {
        guard frames[app] != nil, viewport.width > 0 else { return }
        let leftHalf = pointer.x < viewport.width / 2
        // Visual left is the far column on the right edge, the near one on the left.
        let column = (dock.edge == .right) == leftHalf ? 1 : 0
        // Where the hand is, not the card's middle: a tall card held by its
        // title would otherwise land a slot lower than it was dropped.
        let middle = pointer.y
        // Counted in the column without the card, which is how `move` inserts.
        let rest = dock.layout[column].filter { $0 != app }
        let others = rest.filter { !dock.hidden.contains($0) }
        let before = others.filter { (frames[$0]?.midY ?? .infinity) < middle }.count
        // Hidden cards keep their places: insert right after the last card passed.
        let index = before == 0 ? 0 : (rest.firstIndex(of: others[before - 1]) ?? before - 1) + 1
        guard dock.layout[column].firstIndex(of: app) != index else { return }
        withAnimation(Motion.standard) { dock.move(app, toColumn: column, index: index) }
    }

    /// Near the top or bottom of the drawer, the content scrolls on its own
    /// while a card is held there.
    private func updateAutoScroll() {
        let zone: CGFloat = 48
        let speed: CGFloat = pointer.y < zone ? -1 : pointer.y > viewport.height - zone ? 1 : 0
        guard speed != 0 else {
            autoScroll?.cancel()
            autoScroll = nil
            return
        }
        guard autoScroll == nil else { return }
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, dragging != nil {
                let edge = pointer.y < zone ? -1.0 : pointer.y > viewport.height - zone ? 1.0 : 0
                guard edge != 0 else { break }
                let limit = max(0, contentHeight - viewport.height)
                let next = min(limit, max(0, scrollY + edge * 9))
                if next == scrollY { break }
                scroll.scrollTo(y: next)
                if let dragging { reorder(dragging) }
                try? await Task.sleep(for: .milliseconds(16))
            }
            autoScroll = nil
        }
    }

    @ViewBuilder
    private func miniApp(_ app: MiniApp) -> some View {
        switch app {
        case .note: NoteMini(dock: dock)
        case .tasks: TasksMini(dock: dock)
        case .bills: BillsMini(dock: dock)
        case .transcribe: TranscribeMini()
        case .spend: SpendMini(dock: dock)
        case .ask: AskMini(dock: dock)
        }
    }
}

/// The customize menu's button, drawn like the header's other round buttons.
private struct HeaderMenuLabel: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let icon: String

    var body: some View {
        Icon(icon, size: 15)
            .foregroundStyle(hovering ? d.text : d.secondary)
            .frame(width: 30, height: 30)
            .background(hovering ? d.hair : d.fill, in: Circle())
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

// MARK: - Two columns in one container

private struct ColumnKey: LayoutValueKey {
    static let defaultValue = 0
}

/// Cards stacked in two columns, each card in the column its `ColumnKey`
/// names. Moving a card between columns changes only where it is placed, so
/// the card — and a drag in progress on it — stays the same view.
private struct TwoColumns: Layout {
    var spacing: CGFloat

    private func columnWidth(_ width: CGFloat) -> CGFloat { max(0, (width - spacing) / 2) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 708
        let heights = stack(subviews, width: columnWidth(width)).heights
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(bounds.width)
        for (view, origin) in zip(subviews, stack(subviews, width: width).origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                       proposal: ProposedViewSize(width: width, height: nil))
        }
    }

    /// Where each view goes, top to bottom in its column, and how tall each
    /// column ends up.
    private func stack(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], heights: [CGFloat]) {
        var heights: [CGFloat] = [0, 0]
        var counts = [0, 0]
        var origins: [CGPoint] = []
        for view in subviews {
            let column = min(1, max(0, view[ColumnKey.self]))
            if counts[column] > 0 { heights[column] += spacing }
            origins.append(CGPoint(x: CGFloat(column) * (width + spacing), y: heights[column]))
            heights[column] += view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            counts[column] += 1
        }
        return (origins, heights)
    }
}
