import AppKit
import SwiftUI

// The edge dock's own small design language: a native Mac panel with Arc's
// restraint. The desktop shows through a translucent material, cards sit on
// it a shade lighter, edges are 1px hairlines, and type is the system font
// in regular and medium. One accent — neutral ink — is kept for the primary
// action, what's selected and progress; colour otherwise means status only:
// red for recording and overdue, green for done and settled.

struct DockStyle {
    /// Laid over the blurred desktop: the drawer's and the handle's body.
    let material: Color
    /// The same, opaque: the sticky notes' bubbles, which can't be blurred.
    let materialSolid: Color
    /// A card, a shade lighter than the material under it.
    let card: Color
    /// The chosen part of a segmented control.
    let segment: Color
    /// A faint fill: fields, round buttons, a segmented control's track.
    let fill: Color
    let hair, hairStrong: Color
    let text, secondary, muted: Color
    /// The one accent: the primary button, what's selected, progress.
    let accent, accentSubtle, onAccent: Color
    let success, successSubtle, danger: Color
    /// The empty part of a ring.
    let track: Color
    /// Categories' dots, so the same category always looks the same.
    let series: [Color]
    /// A card picked up to be moved.
    let lift: Color

    static let light = DockStyle(
        material: Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 244 / 255, opacity: 0.82),
        materialSolid: .hex(0xF2F2F4),
        card: .white.opacity(0.8), segment: .white, fill: .black.opacity(0.045),
        hair: .black.opacity(0.085), hairStrong: .black.opacity(0.2),
        // muted is 6:1 on a card: timestamps and hints stay readable.
        text: .hex(0x0F0F0F), secondary: .hex(0x4D4D4D), muted: .hex(0x606060),
        accent: .hex(0x292929), accentSubtle: Color.hex(0x2E2E2E).opacity(0.08), onAccent: .white,
        success: .hex(0x00793D), successSubtle: Color.hex(0x25984D).opacity(0.12), danger: .hex(0xCC272E),
        track: .black.opacity(0.1),
        series: [.hex(0x2E2E2E), .hex(0x4081D2), .hex(0xE3AD4B), .hex(0x78A3CF), .hex(0x53AD81)],
        lift: .black.opacity(0.22))

    /// The Paper theme: the same, on warm paper.
    static let paper = DockStyle(
        material: Color(.sRGB, red: 248 / 255, green: 242 / 255, blue: 226 / 255, opacity: 0.85),
        materialSolid: .hex(0xF8F2E2),
        card: Color(.sRGB, red: 1, green: 252 / 255, blue: 242 / 255, opacity: 0.82),
        segment: .hex(0xFFFCF4), fill: Color.hex(0x463214).opacity(0.06),
        hair: Color.hex(0x463214).opacity(0.12), hairStrong: Color.hex(0x463214).opacity(0.24),
        text: .hex(0x2D251C), secondary: .hex(0x584A3D), muted: .hex(0x695B4D),
        accent: .hex(0x443428), accentSubtle: Color.hex(0x5A4530).opacity(0.1), onAccent: .white,
        success: .hex(0x00793D), successSubtle: Color.hex(0x25984D).opacity(0.12), danger: .hex(0xCC272E),
        track: Color.hex(0x463214).opacity(0.12),
        series: [.hex(0x443428), .hex(0x4081D2), .hex(0xE3AD4B), .hex(0x78A3CF), .hex(0x53AD81)],
        lift: Color.hex(0x3C2A0E).opacity(0.22))

    static let dark = DockStyle(
        material: Color(.sRGB, red: 40 / 255, green: 40 / 255, blue: 43 / 255, opacity: 0.8),
        materialSolid: .hex(0x28282B),
        card: .white.opacity(0.06), segment: .white.opacity(0.16), fill: .white.opacity(0.07),
        hair: .white.opacity(0.1), hairStrong: .white.opacity(0.24),
        text: .hex(0xF2F2F2), secondary: .hex(0xBEBEBE), muted: .hex(0x989898),
        accent: .hex(0xE8E8E8), accentSubtle: Color.hex(0xE8E8E8).opacity(0.12), onAccent: .hex(0x141414),
        success: .hex(0x56D57B), successSubtle: Color.hex(0x37BB62).opacity(0.16), danger: .hex(0xFF6A65),
        track: .white.opacity(0.14),
        series: [.hex(0xE8E8E8), .hex(0x589AED), .hex(0xE3AD4B), .hex(0x577594), .hex(0x57BC8A)],
        lift: .black.opacity(0.55))

    static func style(for theme: ThemeChoice, scheme: ColorScheme) -> DockStyle {
        if scheme == .dark { return .dark }
        return theme == .paper ? .paper : .light
    }

    /// A finance category's dot, so the same category always looks the same.
    func tone(forCategory category: String) -> Color {
        switch category {
        case "Food & Drink": return series[2]
        case "Groceries": return series[4]
        case "Transport": return series[3]
        case "Bills & Utilities": return series[0]
        case "Shopping": return series[1]
        case "Income": return success
        default:
            let seed = category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return series[seed % series.count]
        }
    }
}

private struct DockStyleKey: EnvironmentKey {
    static let defaultValue = DockStyle.dark
}

extension EnvironmentValues {
    var dock: DockStyle {
        get { self[DockStyleKey.self] }
        set { self[DockStyleKey.self] = newValue }
    }
}

// MARK: - Material

/// The desktop behind the dock, blurred, cut to the dock's shape. Animatable,
/// so the cut follows the shape frame by frame as the handle springs open.
struct DockMaterial: View, Animatable {
    var shape: EdgeTabShape

    nonisolated var animatableData: EdgeTabShape.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            BehindWindowBlur(path: shape.path(in: CGRect(origin: .zero, size: proxy.size)), size: proxy.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An NSVisualEffectView blending with what's behind the window. Cut with a
/// mask image rather than SwiftUI's clip: a layer mask doesn't cut a blur the
/// window server draws, and a rectangle of frosted desktop would show round
/// the shape.
private struct BehindWindowBlur: NSViewRepresentable {
    let path: Path
    let size: CGSize

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = UnclickableEffectView()
        view.blendingMode = .behindWindow
        view.material = .popover
        // Always on: the dock is mostly used while another app is in front,
        // and an inactive material goes flat.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let dark = context.environment.colorScheme == .dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance?.name != appearance?.name { view.appearance = appearance }
        // Redrawn only when the shape moved: the dock redraws as the pointer
        // moves over it, and the shape mostly stays put.
        guard context.coordinator.path != path || context.coordinator.size != size else { return }
        context.coordinator.path = path
        context.coordinator.size = size
        view.maskImage = Self.mask(path, size)
    }

    func makeCoordinator() -> Drawn { Drawn() }

    /// The shape the mask was last drawn for.
    final class Drawn {
        var path: Path?
        var size: CGSize = .zero
    }

    private static func mask(_ path: Path, _ size: CGSize) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let shape = path.cgPath
        // Flipped, so it's drawn in SwiftUI's top-left coordinates.
        return NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(cgPath: shape).fill()
            return true
        }
    }
}

/// Never the target of a click: the SwiftUI drawn over it takes them, and
/// beside the shape they go through to whatever is under the window.
private final class UnclickableEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Card

/// What a card does when its title bar is dragged — set by the drawer, which
/// owns the arrangement.
struct CardDrag {
    /// This card is the one being dragged.
    var lifted: Bool
    var changed: @MainActor (DragGesture.Value) -> Void
    var ended: @MainActor () -> Void
}

extension EnvironmentValues {
    @Entry var cardDrag: CardDrag?
}

struct DockCard<Content: View, Footer: View>: View {
    @Environment(\.dock) private var d
    @Environment(\.cardDrag) private var drag
    @State private var overTitle = false
    /// From the drawer, not the gesture: a cancelled gesture never says it
    /// ended, and a grip left showing would outlive the drag.
    private var held: Bool { drag?.lifted == true }
    let title: String
    var accessory: AnyView?
    /// The row of actions shows only when there is something to do in it.
    var footerVisible = true
    /// Between the title, the content and the actions.
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(title: String, accessory: AnyView? = nil, footerVisible: Bool = true, spacing: CGFloat = 10,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.accessory = accessory
        self.footerVisible = footerVisible
        self.spacing = spacing
        self.content = content
        self.footer = footer
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(FN.font(13, .medium))
                    .foregroundStyle(d.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                accessory
            }
            .frame(height: 26)
            // The title bar is the grip: drag it to rearrange the drawer.
            .overlay(alignment: .leading) {
                if drag != nil {
                    GripDots()
                        .foregroundStyle(d.muted)
                        .offset(x: -10)
                        .opacity(overTitle || held ? 1 : 0)
                        .animation(Motion.quick, value: overTitle || held)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .contentShape(Rectangle())
            .onHover { overTitle = $0 }
            .pointerStyle(drag == nil ? nil : held ? .grabActive : .grabIdle)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("dock.drawer"))
                .onChanged { value in drag?.changed(value) }
                .onEnded { _ in drag?.ended() })
            .accessibilityHint(drag == nil ? "" : "Drag the title to move this card")

            content()
                .padding(.horizontal, 12)

            if Footer.self != EmptyView.self && footerVisible {
                footer()
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, 12)
        .animation(Motion.standard, value: footerVisible)
        .background(d.card, in: shape)
        .overlay(shape.strokeBorder(d.hair, lineWidth: 1))
    }
}

extension DockCard where Footer == EmptyView {
    init(title: String, accessory: AnyView? = nil, spacing: CGFloat = 10,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.spacing = spacing
        self.content = content
        self.footer = { EmptyView() }
    }
}

// MARK: - Buttons

/// A round icon button. Plain in a card's title row, filled in the drawer's
/// header, bordered beside a card's other buttons.
struct DockRoundButton: View {
    enum Look { case plain, filled, bordered }

    @Environment(\.dock) private var d
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let icon: String
    let help: String
    var size: CGFloat = 24
    var look = Look.plain
    let action: () -> Void

    private var iconSize: CGFloat { size >= 30 ? 15 : size <= 24 ? 14 : 13 }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: iconSize)
                .foregroundStyle(hovering ? d.text : look == .plain ? d.muted : d.secondary)
                .frame(width: size, height: size)
                .background(background, in: Circle())
                .overlay(Circle().strokeBorder(look == .bordered ? d.hair : .clear, lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 && enabled }
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        switch look {
        case .plain: return hovering ? d.fill : .clear
        case .filled: return hovering ? d.hair : d.fill
        case .bordered: return hovering ? d.fill : d.card
        }
    }
}

/// The card's one main action: a capsule in the accent.
struct DockPrimaryButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Icon(icon, size: 13, weight: 2) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(FN.font(13, .medium))
            .foregroundStyle(d.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(d.accent.opacity(hovering ? 0.86 : 1), in: Capsule())
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

/// Any other action: a capsule on the card's colour, with a hairline.
struct DockSecondaryButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    var icon: String?
    var disabled = false
    /// Beside a row rather than under a card: a size down.
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Icon(icon, size: 13) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(FN.font(small ? 12 : 13))
            .foregroundStyle(d.text)
            .padding(.horizontal, small ? 10 : 12)
            .frame(height: small ? 26 : 28)
            .background(hovering ? d.fill : d.card, in: Capsule())
            .overlay(Capsule().strokeBorder(d.hair, lineWidth: 1))
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

/// Text only, for the quietest actions: "Clear", "Undo", "Show".
struct DockPlainButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    var icon: String?
    var height: CGFloat = 28
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                if let icon { Icon(icon, size: 12) }
            }
            .fixedSize()
            .font(FN.font(12, .medium))
            .foregroundStyle(hovering ? d.text : d.secondary)
            .padding(.horizontal, 8)
            .frame(height: height)
            .background(hovering ? d.fill : .clear, in: Capsule())
            .opacity(disabled ? 0.4 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

/// A plain text button with a chevron, for the left of a card's actions.
struct DockDisclosure: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Icon("chevronDown", size: 12)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(FN.font(13))
            .foregroundStyle(hovering ? d.text : d.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? d.fill : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: open)
    }
}

/// What a menu button in a card shows: quiet text and a chevron, like
/// "English ▾" or "On this Mac ▾".
struct DockMenuLabel: View {
    @Environment(\.dock) private var d
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let title: String
    var icon: String?
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Icon(icon, size: 13) }
            Text(title).lineLimit(1)
            Icon("chevronDown", size: 11)
        }
        .font(FN.font(12))
        .foregroundStyle(hovering ? d.text : d.secondary)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(hovering ? d.fill : .clear, in: Capsule())
        .opacity(enabled ? 1 : 0.5)
        .contentShape(Capsule())
        .onHover { hovering = $0 && enabled }
    }
}

// MARK: - Controls

/// A to-do's round check: a ring, filled with the accent once it's done.
struct DockCheckbox: View {
    @Environment(\.dock) private var d
    let checked: Bool

    var body: some View {
        Circle()
            .fill(checked ? d.accent : .clear)
            .overlay(Circle().strokeBorder(checked ? .clear : d.hairStrong, lineWidth: 1.5))
            .overlay(Icon("check", size: 10, weight: 2.8).foregroundStyle(d.onAccent).opacity(checked ? 1 : 0))
            .frame(width: 16, height: 16)
            .animation(Motion.quick, value: checked)
    }
}

/// Two or three options in a track, the chosen one raised.
struct DockSegments<Value: Hashable>: View {
    @Environment(\.dock) private var d
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let chosen = selection == value
                Button { withAnimation(Motion.standard) { selection = value } } label: {
                    Text(label)
                        .font(FN.font(12, chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? d.text : d.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(d.segment)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: ns)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.fn)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(height: 26)
        .background(d.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// A single-line field on a faint fill.
struct DockField: View {
    @Environment(\.dock) private var d
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Icon(icon, size: 13).foregroundStyle(d.muted)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(d.muted))
                .textFieldStyle(.plain)
                .font(FN.font(13))
                .foregroundStyle(d.text)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, icon == nil ? 11 : 10)
        .frame(height: 30)
        .background(d.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? d.hairStrong : d.hair, lineWidth: 1))
        .animation(Motion.quick, value: focused)
    }
}

/// A small status word, like "Overdue", in its status colour.
struct DockTag: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(FN.font(11, .medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(tone.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// A one-line confirmation that fades in under what it confirms.
struct DockNotice: View {
    @Environment(\.dock) private var d
    let text: String
    var tone: Color?
    var icon = "check"

    var body: some View {
        HStack(spacing: 6) {
            Icon(icon, size: 12, weight: 2.2)
            Text(text).lineLimit(2)
        }
        .font(FN.font(12))
        .foregroundStyle(tone ?? d.success)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// A category's small dot.
struct DockDot: View {
    let tone: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(tone).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Rows one under the other, a hairline between each.
struct DockList<Item: Identifiable, Row: View>: View {
    @Environment(\.dock) private var d
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(d.hair).frame(height: 1) }
                    }
            }
        }
    }
}

/// Six dots: the sign that something can be picked up.
private struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.4, height: 2.4)
                    Circle().frame(width: 2.4, height: 2.4)
                }
            }
        }
    }
}
