import SwiftUI

// The edge dock's own small design language: soft cards on a deeper surface,
// a coloured circle for each kind of thing, one violet primary button per
// card, and a darker footer band for the card's actions. It borrows the
// app's type and motion; the colours are its own, tuned for a panel that
// sits over other apps' windows.

struct DockStyle {
    let surface, card, footer, field, raised, line: Color
    /// Cards lift off the surface by tone in the dark; in the light they need an edge.
    let cardEdge: Color
    let text, muted, faint: Color
    let primary, primaryHover: Color
    let violet, teal, sky, amber, rose: Color

    static let dark = DockStyle(
        surface: .hex(0x141417), card: .hex(0x28282D), footer: .hex(0x212125), field: .hex(0x1C1C20),
        raised: .hex(0x35353C), line: .hex(0x34343B), cardEdge: .clear,
        // faint is 4.6:1 on the card: timestamps and hints stay readable.
        text: .hex(0xEDEDF0), muted: .hex(0xA3A3AD), faint: .hex(0x8A8A94),
        primary: .hex(0x6258F0), primaryHover: .hex(0x6F66F3),
        violet: .hex(0x7D6FF6), teal: .hex(0x3CC6A3), sky: .hex(0x3BA5F1), amber: .hex(0xF0A23B),
        rose: .hex(0xF2616E))

    static let light = DockStyle(
        surface: .hex(0xEBEBEF), card: .hex(0xFFFFFF), footer: .hex(0xF6F6F9), field: .hex(0xF2F2F5),
        raised: .hex(0xEDEDF1), line: .hex(0xE1E1E7), cardEdge: .hex(0xE4E4EA),
        text: .hex(0x1D1D21), muted: .hex(0x62626C), faint: .hex(0x7A7A84),
        primary: .hex(0x5B50E9), primaryHover: .hex(0x6A60EC),
        violet: .hex(0x6F61F2), teal: .hex(0x23AE8B), sky: .hex(0x2A93E0), amber: .hex(0xE08F1F),
        rose: .hex(0xE34B59))

    /// The Paper theme: cards on warm paper.
    static let paper = DockStyle(
        surface: .hex(0xEEE5CD), card: .hex(0xFCF8EC), footer: .hex(0xF5EEDA), field: .hex(0xF4EDD8),
        raised: .hex(0xEAE0C6), line: .hex(0xE0D4B6), cardEdge: .hex(0xE3D8BC),
        text: .hex(0x2F291E), muted: .hex(0x62594A), faint: .hex(0x7A705C),
        primary: .hex(0xA4502A), primaryHover: .hex(0xB35C33),
        violet: .hex(0x8466C9), teal: .hex(0x3E9476), sky: .hex(0x4A8CB8), amber: .hex(0xD08A22),
        rose: .hex(0xC9503E))

    static func style(for theme: ThemeChoice, scheme: ColorScheme) -> DockStyle {
        if scheme == .dark { return .dark }
        return theme == .paper ? .paper : .light
    }

    /// A colour for a finance category, so the same category always looks the same.
    func tone(forCategory category: String) -> Color {
        switch category {
        case "Food & Drink": return amber
        case "Groceries": return teal
        case "Transport": return sky
        case "Bills & Utilities": return violet
        case "Shopping": return rose
        case "Income": return teal
        default:
            let seed = category.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return [violet, teal, sky, amber, rose][seed % 5]
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
    /// The footer band shows only when there is something to do in it.
    var footerVisible = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    init(title: String, accessory: AnyView? = nil, footerVisible: Bool = true,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer) {
        self.title = title
        self.accessory = accessory
        self.footerVisible = footerVisible
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(FN.serif(18))
                    .foregroundStyle(d.text)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            // The title bar is the grip: drag it to rearrange the drawer.
            .overlay(alignment: .leading) {
                if drag != nil {
                    GripDots()
                        .foregroundStyle(d.faint)
                        .padding(.leading, 6)
                        .padding(.top, 4)
                        .opacity(overTitle || held ? 1 : 0)
                        .animation(Motion.quick, value: overTitle || held)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { overTitle = $0 }
            .pointerStyle(drag == nil ? nil : held ? .grabActive : .grabIdle)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("dock.drawer"))
                .onChanged { value in drag?.changed(value) }
                .onEnded { _ in drag?.ended() })
            .accessibilityHint(drag == nil ? "" : "Drag the title to move this card")

            content()
                .padding(.horizontal, 18)
                .padding(.bottom, 16)

            if Footer.self != EmptyView.self && footerVisible {
                footer()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(d.footer)
                    .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: footerVisible)
        .background(d.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(d.cardEdge, lineWidth: 1))
    }
}

extension DockCard where Footer == EmptyView {
    init(title: String, accessory: AnyView? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
        self.footer = { EmptyView() }
    }
}

// MARK: - Pieces

/// The round grey button in a card's title row.
struct DockRoundButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let icon: String
    let help: String
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: size * 0.5)
                .foregroundStyle(hovering ? d.text : d.muted)
                .frame(width: size, height: size)
                .background(hovering ? d.line : d.raised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A coloured circle with an icon: what kind of thing a row is.
struct DockBadgeIcon: View {
    let icon: String
    let tone: Color
    var size: CGFloat = 34

    var body: some View {
        Icon(icon, size: size * 0.46, weight: 1.9)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone, in: Circle())
    }
}

/// The reference's rounded-square checkbox.
struct DockCheckbox: View {
    @Environment(\.dock) private var d
    let checked: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(checked ? d.muted.opacity(0.35) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(checked ? Color.clear : d.faint, lineWidth: 1.2))
            .overlay(Icon("check", size: 13, weight: 2.4).foregroundStyle(d.text).opacity(checked ? 1 : 0))
            .frame(width: 20, height: 20)
            .animation(Motion.quick, value: checked)
    }
}

struct DockPrimaryButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 13, weight: 2) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(FN.font(13, .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(hovering ? d.primaryHover : d.primary,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(disabled ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

struct DockSecondaryButton: View {
    @Environment(\.dock) private var d
    @State private var hovering = false
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 13) }
                Text(title).lineLimit(1)
            }
            .fixedSize()
            .font(FN.font(13, .medium))
            .foregroundStyle(d.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(hovering ? d.raised : d.raised.opacity(0.7),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(disabled ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

/// A plain text button with a chevron, for the footer's left side.
struct DockDisclosure: View {
    @Environment(\.dock) private var d
    let title: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Icon("chevronDown", size: 12)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(FN.font(13))
            .foregroundStyle(d.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .animation(Motion.quick, value: open)
    }
}

/// Two or three options in a pill, the selected one raised.
struct DockSegments<Value: Hashable>: View {
    @Environment(\.dock) private var d
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button { withAnimation(Motion.standard) { selection = value } } label: {
                    Text(label)
                        .font(FN.font(12.5, .medium))
                        .foregroundStyle(selection == value ? d.text : d.muted)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if selection == value {
                                Capsule().fill(d.raised)
                                    .matchedGeometryEffect(id: "segment", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.fn)
            }
        }
        .padding(3)
        .background(d.field, in: Capsule())
        .overlay(Capsule().stroke(d.line, lineWidth: 1))
    }
}

/// A single-line field on the card's inset colour.
struct DockField: View {
    @Environment(\.dock) private var d
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Icon(icon, size: 14).foregroundStyle(d.faint)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(d.faint))
                .textFieldStyle(.plain)
                .font(FN.font(13))
                .foregroundStyle(d.text)
                .focused($focused)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(d.field, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(focused ? d.primary.opacity(0.8) : d.line, lineWidth: 1))
        .animation(Motion.quick, value: focused)
    }
}

/// A small status word in a coloured box, like "Overdue".
struct DockTag: View {
    let text: String
    let tone: Color

    var body: some View {
        Text(text)
            .font(FN.font(11, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(tone, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
        .foregroundStyle(tone ?? d.teal)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// Six dots: the sign that something can be picked up.
private struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.6, height: 2.6)
                    Circle().frame(width: 2.6, height: 2.6)
                }
            }
        }
    }
}
