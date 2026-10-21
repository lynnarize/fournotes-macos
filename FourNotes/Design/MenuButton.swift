import AppKit
import SwiftUI

// Menus and dialogs drawn the way the web app draws them.
//
// The web app's dropdowns (src/components/notes/Dropdown.tsx) are rounded
// cards with a soft shadow, a check on the chosen row and a hover tint, and its
// dialogs (Modal in ui.tsx) are centred cards over a dimmed page. AppKit's
// NSMenu and window sheets look nothing like that, so both are drawn here in
// SwiftUI, on a layer over the whole window:
//
// - A `MenuButton` or `.fnSheet` publishes what it wants shown as a preference.
// - `.popupHost()` on the window's root reads those and draws them on top, so a
//   menu is never clipped by the toolbar or scroll view it was opened from.
//
// Keyboard use is kept: arrows move through a menu, Return picks, Escape closes
// the topmost menu or dialog. Where there is no host — the edge dock and the
// sticky notes are small floating panels a menu could not fit in — the real
// NSMenu and sheet are used instead.

/// One row of a `MenuButton`'s menu.
struct MenuEntry {
    enum Kind {
        case action(@MainActor () -> Void)
        case submenu([MenuEntry])
        case divider
        case header
    }

    var title: String
    var kind: Kind
    var checked = false
    var destructive = false
    var enabled = true
    /// A colour chip shown before the title, for colour pickers.
    var swatch: NSColor?

    static func item(_ title: String, checked: Bool = false, destructive: Bool = false,
                     enabled: Bool = true, swatch: NSColor? = nil,
                     action: @escaping @MainActor () -> Void) -> MenuEntry {
        MenuEntry(title: title, kind: .action(action), checked: checked,
                  destructive: destructive, enabled: enabled, swatch: swatch)
    }

    static func menu(_ title: String, _ children: [MenuEntry]) -> MenuEntry {
        MenuEntry(title: title, kind: .submenu(children))
    }

    static func header(_ title: String) -> MenuEntry { MenuEntry(title: title, kind: .header) }

    static var divider: MenuEntry { MenuEntry(title: "", kind: .divider) }

    /// Rows the keyboard can land on.
    fileprivate var selectable: Bool {
        guard enabled else { return false }
        switch kind {
        case .action, .submenu: return true
        case .divider, .header: return false
        }
    }
}

enum MenuAlign { case leading, trailing }

struct MenuButton<Label: View>: View {
    @Environment(\.popupHostAvailable) private var hosted
    var help: String?
    var align: MenuAlign = .leading
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: () -> Label

    @State private var isOpen = false
    @State private var anchor = MenuAnchor()
    @State private var id = UUID()

    init(help: String? = nil, align: MenuAlign = .leading, entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping () -> Label) {
        self.help = help
        self.align = align
        self.entries = entries
        self.label = label
    }

    var body: some View {
        // Built while open, not when drawn: the checkmarks read state that
        // changes between openings.
        let open = isOpen
        let rows = open ? entries() : []
        let binding = $isOpen
        let id = id
        let align = align
        Button {
            if hosted { isOpen.toggle() } else { anchor.open(entries()) }
        } label: {
            label().environment(\.menuIsOpen, open)
        }
        .buttonStyle(.fn)
        .background(MenuAnchorView(anchor: anchor))
        .transformAnchorPreference(key: PopupKey.self, value: .bounds) { items, bounds in
            guard open else { return }
            items.append(PopupItem(id: id, kind: .menu(trigger: bounds, entries: rows, align: align),
                                   close: { binding.wrappedValue = false }))
        }
        .help(help ?? "")
        .accessibilityLabel(help ?? "Menu")
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// An icon that opens a menu, styled like `IconButton`.
struct IconMenu: View {
    let name: String
    var size: CGFloat = 18
    var box: CGFloat = 30
    var tone: Color?
    var help: String
    var align: MenuAlign = .leading
    let entries: () -> [MenuEntry]

    init(_ name: String, size: CGFloat = 18, box: CGFloat = 30, tone: Color? = nil,
         help: String, align: MenuAlign = .leading, entries: @escaping () -> [MenuEntry]) {
        self.name = name; self.size = size; self.box = box
        self.tone = tone; self.help = help; self.align = align; self.entries = entries
    }

    var body: some View {
        MenuButton(help: help, align: align, entries: entries) {
            IconMenuLabel(name: name, size: size, box: box, tone: tone)
        }
    }
}

private struct IconMenuLabel: View {
    @Environment(\.palette) private var p
    @Environment(\.menuIsOpen) private var open
    @State private var hovering = false
    let name: String
    let size: CGFloat
    let box: CGFloat
    let tone: Color?

    var body: some View {
        let lit = hovering || open
        Icon(name, size: size)
            .foregroundStyle(tone ?? (lit ? p.foreground : p.textSecondary))
            .frame(width: box, height: box)
            .background(lit ? p.hover : .clear, in: Circle())
            .motion(lit, Motion.quick)
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

/// A text label that opens a menu, for the toolbar's Font / Size / More.
struct TextMenu: View {
    let title: String
    var width: CGFloat?
    var help: String
    let entries: () -> [MenuEntry]

    var body: some View {
        MenuButton(help: help, entries: entries) {
            TextMenuLabel(title: title, width: width)
        }
    }
}

private struct TextMenuLabel: View {
    @Environment(\.palette) private var p
    @Environment(\.menuIsOpen) private var open
    @State private var hovering = false
    let title: String
    let width: CGFloat?

    var body: some View {
        let lit = hovering || open
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            Icon("chevronDown", size: 10).opacity(0.7)
        }
        .font(FN.body)
        .monospacedDigit()
        .foregroundStyle(lit ? p.text : p.muted)
        .padding(.horizontal, 8)
        .frame(minWidth: width, alignment: .leading)
        .frame(height: 30)
        .background(lit ? (open ? p.accentSubtle : p.hover) : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .motion(lit, Motion.quick)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A bordered dropdown for picking one value — the web app's `<select>`.
struct SelectMenu<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var width: CGFloat?
    var help: String?

    var body: some View {
        let current = options.first { $0.value == selection }?.label ?? ""
        MenuButton(help: help, entries: {
            options.map { option in
                .item(option.label, checked: option.value == selection) { selection = option.value }
            }
        }) {
            SelectLabel(title: current, width: width)
        }
    }
}

private struct SelectLabel: View {
    @Environment(\.palette) private var p
    @Environment(\.menuIsOpen) private var open
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let title: String
    let width: CGFloat?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Icon("chevronDown", size: 12).foregroundStyle(p.faint)
        }
        .font(FN.body)
        .foregroundStyle(p.foreground)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(width: width)
        .frame(minWidth: 72)
        .frame(height: 30)
        .background(p.surface, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
            .strokeBorder(open || (hovering && enabled) ? p.borderStrong : p.border, lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .motion(hovering || open, Motion.quick)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Dialogs

extension View {
    /// A dialog in the web app's style: a card over the dimmed window. Closes
    /// on Escape or a click outside it.
    func fnSheet<Modal: View>(isPresented: Binding<Bool>,
                              @ViewBuilder content: @escaping () -> Modal) -> some View {
        modifier(ModalPresenter(isPresented: isPresented, modal: content))
    }

    func fnSheet<Item: Identifiable, Modal: View>(item: Binding<Item?>,
                                                  @ViewBuilder content: @escaping (Item) -> Modal) -> some View {
        modifier(ItemModalPresenter(item: item, modal: content))
    }

    /// Draws the menus and dialogs opened anywhere inside this view, over it.
    /// Put it on a window's root, under anything that should stay on top
    /// (the toasts).
    func popupHost() -> some View { modifier(PopupHostModifier()) }
}

extension EnvironmentValues {
    /// Set inside a view hosted by `.popupHost()`.
    @Entry var popupHostAvailable = false
    /// Closes the dialog this view is in. `nil` outside a dialog.
    @Entry var closeModal: CloseModalAction?
    /// The tallest a dialog may be, from the window's height.
    @Entry var modalMaxHeight: CGFloat?
    /// True for a menu button's label while its menu is showing.
    @Entry var menuIsOpen = false
}

/// Closes the dialog a view is in; call it like a function.
struct CloseModalAction {
    let run: @MainActor () -> Void
    @MainActor func callAsFunction() { run() }
}

private struct ModalPresenter<Modal: View>: ViewModifier {
    @Environment(\.popupHostAvailable) private var hosted
    @Binding var isPresented: Bool
    let modal: () -> Modal
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if hosted {
            let item = isPresented
                ? PopupItem(id: id, kind: .modal(AnyView(modal())), close: { [binding = $isPresented] in
                    binding.wrappedValue = false
                })
                : nil
            content.transformPreference(PopupKey.self) { items in
                if let item { items.append(item) }
            }
        } else {
            content.sheet(isPresented: $isPresented, content: modal)
        }
    }
}

private struct ItemModalPresenter<Item: Identifiable, Modal: View>: ViewModifier {
    @Environment(\.popupHostAvailable) private var hosted
    @Binding var item: Item?
    let modal: (Item) -> Modal
    @State private var id = UUID()

    func body(content: Content) -> some View {
        if hosted {
            // A different item is a different dialog, with fresh state.
            let popup = item.map { value in
                PopupItem(id: "\(id)-\(value.id)", kind: .modal(AnyView(modal(value))),
                          close: { [binding = $item] in binding.wrappedValue = nil })
            }
            content.transformPreference(PopupKey.self) { items in
                if let popup { items.append(popup) }
            }
        } else {
            content.sheet(item: $item, content: modal)
        }
    }
}

// MARK: - The layer

struct PopupItem: Identifiable {
    enum Kind {
        case modal(AnyView)
        case menu(trigger: Anchor<CGRect>, entries: [MenuEntry], align: MenuAlign)
    }

    let id: AnyHashable
    let kind: Kind
    let close: @MainActor () -> Void
}

struct PopupKey: PreferenceKey {
    static var defaultValue: [PopupItem] { [] }
    static func reduce(value: inout [PopupItem], nextValue: () -> [PopupItem]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PopupHostModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.popupHostAvailable, true)
            .overlayPreferenceValue(PopupKey.self) { items in PopupLayer(items: items) }
            // What this host shows is its own; a host further out must not
            // show it again.
            .transformPreference(PopupKey.self) { $0 = [] }
    }
}

/// The host's NSView, for turning mouse events into layer coordinates.
@MainActor
final class PopupHostView {
    weak var view: NSView?

    /// Where `event` happened, in the layer's top-left coordinates, or `nil`
    /// for another window.
    func point(of event: NSEvent) -> CGPoint? {
        guard let view, event.window === view.window else { return nil }
        let local = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: view.isFlipped ? local.y : view.bounds.height - local.y)
    }
}

private struct PopupHostReader: NSViewRepresentable {
    let host: PopupHostView
    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        host.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { host.view = view }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct PopupLayer: View {
    let items: [PopupItem]
    @State private var host = PopupHostView()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(items) { item in
                    switch item.kind {
                    case .modal(let content):
                        ModalLayer(content: content, close: item.close, size: proxy.size)
                            .transition(.opacity)
                    case .menu(let trigger, let entries, let align):
                        MenuLayer(entries: entries, trigger: proxy[trigger], align: align,
                                  size: proxy.size, host: host, close: item.close)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background(PopupHostReader(host: host))
            .animation(Motion.quick, value: items.map(\.id))
        }
    }
}

/// Routes keys and clicks to the topmost menu or dialog. One event monitor
/// for all of them, so a menu inside a dialog gets Escape first.
@MainActor
final class PopupEvents {
    static let shared = PopupEvents()
    private var handlers: [(id: UUID, handle: @MainActor (NSEvent) -> Bool)] = []
    private var monitor: Any?

    /// `handle` returns true to swallow the event.
    func push(_ id: UUID, _ handle: @escaping @MainActor (NSEvent) -> Bool) {
        handlers.removeAll { $0.id == id }
        handlers.append((id, handle))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            let swallow = MainActor.assumeIsolated { PopupEvents.shared.route(event) }
            return swallow ? nil : event
        }
    }

    func pop(_ id: UUID) {
        handlers.removeAll { $0.id == id }
        if handlers.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func route(_ event: NSEvent) -> Bool {
        handlers.last?.handle(event) ?? false
    }
}

// MARK: - Dialog layer

private struct ModalLayer: View {
    @Environment(\.palette) private var p
    let content: AnyView
    let close: @MainActor () -> Void
    let size: CGSize
    @State private var shown = false
    @State private var id = UUID()

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)

            content
                .environment(\.closeModal, CloseModalAction(run: close))
                .environment(\.modalMaxHeight, max(200, size.height * 0.8))
                .background(p.surface)
                .clipShape(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous)
                    .strokeBorder(p.border, lineWidth: 1))
                .shadow(color: p.shadow, radius: 5, y: 2)
                .shadow(color: p.shadowStrong, radius: 24, y: 10)
                .scaleEffect(shown || Motion.reduce ? 1 : 0.97, anchor: .top)
                .opacity(shown ? 1 : 0)
                .padding(.top, max(16, size.height * 0.1))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isModal)
        }
        .frame(width: size.width, height: size.height)
        .popupHost()
        .onAppear {
            withAnimation(Motion.standard) { shown = true }
            PopupEvents.shared.push(id) { event in
                guard event.type == .keyDown, event.keyCode == 53 else { return false }
                close()
                return true
            }
        }
        .onDisappear { PopupEvents.shared.pop(id) }
    }
}

// MARK: - Menu layer

@MainActor @Observable
private final class MenuState {
    /// Indexes into the entries, one per submenu opened.
    var path: [Int] = []
    var highlight: Int?
    var size: CGSize = .zero
    var frame: CGRect = .zero
}

private struct MenuLayer: View {
    let entries: [MenuEntry]
    let trigger: CGRect
    let align: MenuAlign
    let size: CGSize
    let host: PopupHostView
    let close: @MainActor () -> Void

    @State private var state = MenuState()
    @State private var id = UUID()

    var body: some View {
        let below = size.height - trigger.maxY - 12
        let above = trigger.minY - 12
        // Near the bottom of the window (the assistant's composer), open upwards.
        let openUp = below < 220 && above > below
        let maxHeight = max(120, (openUp ? above : below) - 6)
        let menu = state.size
        let height = min(menu.height, maxHeight)
        let wanted = align == .trailing ? trigger.maxX - menu.width : trigger.minX
        let x = min(max(8, wanted), size.width - menu.width - 8)
        let y = openUp ? trigger.minY - 6 - height : trigger.maxY + 6

        MenuPanel(entries: entries, state: state, maxHeight: maxHeight, choose: choose)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { state.size = $0 }
            .offset(x: x, y: y)
            .opacity(menu == .zero ? 0 : 1)
            .onChange(of: CGRect(x: x, y: y, width: menu.width, height: height), initial: true) { _, frame in
                state.frame = frame
            }
            .onAppear { PopupEvents.shared.push(id, handle) }
            .onDisappear { PopupEvents.shared.pop(id) }
    }

    private func choose(_ index: Int) {
        let rows = MenuPanel.rows(entries, state.path)
        guard rows.indices.contains(index), rows[index].selectable else { return }
        switch rows[index].kind {
        case .action(let run):
            close()
            run()
        case .submenu:
            state.path.append(index)
            state.highlight = MenuPanel.rows(entries, state.path).firstIndex { $0.selectable }
        case .divider, .header:
            break
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            let rows = MenuPanel.rows(entries, state.path)
            let selectable = rows.indices.filter { rows[$0].selectable }
            switch event.keyCode {
            case 53: // Escape
                close()
            case 125, 126: // Down, Up
                guard !selectable.isEmpty else { return true }
                let down = event.keyCode == 125
                if let current = state.highlight, let at = selectable.firstIndex(of: current) {
                    state.highlight = selectable[(at + (down ? 1 : selectable.count - 1)) % selectable.count]
                } else {
                    state.highlight = down ? selectable.first : selectable.last
                }
            case 36, 76, 49: // Return, Enter, Space
                if let current = state.highlight { choose(current) }
            case 124: // Right opens a submenu
                if let current = state.highlight, case .submenu = rows[current].kind { choose(current) }
            case 123: // Left goes back out of one
                if let last = state.path.popLast() { state.highlight = last }
            default:
                // Typing goes on to the text it was meant for.
                close()
                return false
            }
            return true
        case .scrollWheel:
            if let point = host.point(of: event), state.frame.contains(point) { return false }
            close()
            return false
        default:
            guard let point = host.point(of: event) else {
                close()
                return false
            }
            if state.frame.contains(point) { return false }
            // Outside, the click only closes the menu, as a Mac menu does —
            // and a click on the button that opened it doesn't reopen it.
            close()
            return true
        }
    }
}

private struct MenuPanel: View {
    @Environment(\.palette) private var p
    let entries: [MenuEntry]
    let state: MenuState
    let maxHeight: CGFloat
    let choose: (Int) -> Void
    @State private var contentHeight: CGFloat = 0

    static func rows(_ entries: [MenuEntry], _ path: [Int]) -> [MenuEntry] {
        var rows = entries
        for index in path {
            guard rows.indices.contains(index), case .submenu(let children) = rows[index].kind else { break }
            rows = children
        }
        return rows
    }

    var body: some View {
        let rows = Self.rows(entries, state.path)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if !state.path.isEmpty {
                    backRow
                    separator
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                    row(entry, index: index)
                }
            }
            .padding(6)
            .frame(minWidth: 180, maxWidth: 340, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
        .frame(height: contentHeight == 0 ? nil : min(contentHeight, maxHeight))
        .fixedSize(horizontal: true, vertical: false)
        .background(p.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .shadow(color: p.shadow, radius: 5, y: 2)
        .shadow(color: p.shadowStrong, radius: 22, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Menu")
    }

    private var separator: some View {
        Rectangle().fill(p.borderSubtle).frame(height: 1).padding(.vertical, 5).padding(.horizontal, 10)
    }

    private var backRow: some View {
        Button {
            if let last = state.path.popLast() { state.highlight = last }
        } label: {
            HStack(spacing: 8) {
                Icon("chevron", size: 13).rotationEffect(.degrees(180))
                Text(Self.rows(entries, Array(state.path.dropLast()))[state.path.last ?? 0].title)
                    .font(FN.bodyMedium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(p.muted)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ entry: MenuEntry, index: Int) -> some View {
        switch entry.kind {
        case .divider:
            separator
        case .header:
            Text(entry.title)
                .font(FN.small)
                .foregroundStyle(p.textMuted)
                .padding(.horizontal, 10)
                .padding(.top, index == 0 ? 4 : 8)
                .padding(.bottom, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action, .submenu:
            let lit = state.highlight == index && entry.enabled
            Button { choose(index) } label: {
                HStack(spacing: 10) {
                    if let swatch = entry.swatch {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(nsColor: swatch))
                            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(p.line, lineWidth: 1))
                            .frame(width: 14, height: 14)
                    }
                    Text(entry.title)
                        .font(FN.body)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    if case .submenu = entry.kind {
                        Icon("chevron", size: 13).foregroundStyle(p.faint)
                    } else if entry.checked {
                        Icon("check", size: 14).foregroundStyle(p.accent)
                    }
                }
                .foregroundStyle(entry.destructive ? p.danger : p.foreground)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(lit ? (entry.destructive ? p.dangerSubtle : p.hover) : .clear,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .opacity(entry.enabled ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!entry.enabled)
            .onHover { inside in
                if inside { state.highlight = index } else if state.highlight == index { state.highlight = nil }
            }
            .accessibilityAddTraits(entry.checked ? .isSelected : [])
        }
    }
}

// MARK: - AppKit fallback

@MainActor
final class MenuAnchor {
    fileprivate weak var view: NSView?

    func open(_ entries: [MenuEntry]) {
        guard let view else { return }
        let menu = Self.build(entries)
        // Just under the label, left edges aligned, like a pop-up button.
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }

    static func build(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            switch entry.kind {
            case .divider:
                menu.addItem(.separator())
            case .header:
                menu.addItem(.sectionHeader(title: entry.title))
            case .submenu(let children):
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.submenu = build(children)
                item.isEnabled = entry.enabled
                menu.addItem(item)
            case .action(let run):
                let target = MenuTarget(run)
                let item = NSMenuItem(title: entry.title, action: #selector(MenuTarget.fire(_:)),
                                      keyEquivalent: "")
                item.target = target
                // `target` is weak; the item keeps its action alive this way.
                item.representedObject = target
                item.state = entry.checked ? .on : .off
                item.isEnabled = entry.enabled
                if entry.destructive {
                    item.attributedTitle = NSAttributedString(
                        string: entry.title,
                        attributes: [.foregroundColor: NSColor.systemRed,
                                     .font: NSFont.menuFont(ofSize: 0)])
                }
                if let swatch = entry.swatch { item.image = Self.swatch(swatch) }
                menu.addItem(item)
            }
        }
        return menu
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            color.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}

@MainActor
private final class MenuTarget: NSObject {
    private let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire(_ sender: Any?) { run() }
}

/// Hands the button's NSView to the anchor so the menu can be placed under it.
private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
