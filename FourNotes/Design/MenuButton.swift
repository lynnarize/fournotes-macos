import AppKit
import SwiftUI

// A menu opened from any SwiftUI label.
//
// SwiftUI's `Menu` on macOS hands its label to AppKit, which only draws text
// and system images. Every menu whose label was one of the app's own icons —
// Insert, Text style, More actions, the reminder bell, Sort — rendered as an
// empty gap that could still be clicked if you knew where it was. This draws
// the label in SwiftUI and opens a real NSMenu underneath it, so the menus
// themselves stay native: keyboard navigation, type-select, submenus.

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
}

struct MenuButton<Label: View>: View {
    var help: String?
    let entries: () -> [MenuEntry]
    @ViewBuilder let label: () -> Label

    @State private var anchor = MenuAnchor()

    init(help: String? = nil, entries: @escaping () -> [MenuEntry],
         @ViewBuilder label: @escaping () -> Label) {
        self.help = help
        self.entries = entries
        self.label = label
    }

    var body: some View {
        // Built when clicked, not when drawn: the checkmarks read state that
        // changes between openings.
        Button { anchor.open(entries()) } label: { label() }
            .buttonStyle(.fn)
            .background(MenuAnchorView(anchor: anchor))
            .help(help ?? "")
            .accessibilityLabel(help ?? "Menu")
    }
}

/// An icon that opens a menu, styled like `IconButton`.
struct IconMenu: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let name: String
    var size: CGFloat = 18
    var box: CGFloat = 30
    var tone: Color?
    var help: String
    let entries: () -> [MenuEntry]

    init(_ name: String, size: CGFloat = 18, box: CGFloat = 30, tone: Color? = nil,
         help: String, entries: @escaping () -> [MenuEntry]) {
        self.name = name; self.size = size; self.box = box
        self.tone = tone; self.help = help; self.entries = entries
    }

    var body: some View {
        MenuButton(help: help, entries: entries) {
            Icon(name, size: size)
                .foregroundStyle(tone ?? (hovering ? p.text : p.muted))
                .frame(width: box, height: box)
                .background(hovering ? p.hover : .clear,
                            in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                .motion(hovering, Motion.quick)
                .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
    }
}

/// A text label that opens a menu, for the toolbar's Font / Size / More.
struct TextMenu: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let title: String
    var width: CGFloat?
    var help: String
    let entries: () -> [MenuEntry]

    var body: some View {
        MenuButton(help: help, entries: entries) {
            HStack(spacing: 3) {
                Text(title).lineLimit(1)
                Icon("chevronDown", size: 10).opacity(0.7)
            }
            .font(FN.body)
            .monospacedDigit()
            .foregroundStyle(hovering ? p.text : p.muted)
            .padding(.horizontal, 8)
            .frame(minWidth: width, alignment: .leading)
            .frame(height: 30)
            .background(hovering ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
            .motion(hovering, Motion.quick)
            .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - AppKit plumbing

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
