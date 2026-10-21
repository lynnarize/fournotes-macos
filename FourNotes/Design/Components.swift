import SwiftUI

// The shared UI kit, ported from src/components/ui.tsx.

// MARK: - Card

/// The rounded box every tab uses (Notes editor, task panel, Today, Finance): the kit's
/// `.card`. Cards rest on a hairline border, never a shadow.
struct Card<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface)
            .clipShape(RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FN.radiusPanel, style: .continuous)
                    .strokeBorder(p.border, lineWidth: 1))
            .entrance()
    }
}

extension View {
    /// The kit's `.floating`: a card that sits over the page (menus, popovers, the
    /// composer), with the one shadow the kit allows.
    func floating(_ p: Palette, radius: CGFloat = FN.radiusPanel) -> some View {
        // The shadow belongs to the background shape alone: on the whole view it
        // would fall from every line of text and every card inside.
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(p.surface)
                .shadow(color: p.shadowStrong, radius: 24, y: 10)
                .shadow(color: p.shadow, radius: 5, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(p.border, lineWidth: 1))
    }
}

/// A card's title row: optional round icon, title, extra controls, and an "open" arrow.
struct CardHead<Trailing: View>: View {
    @Environment(\.palette) private var p
    var icon: String?
    var title: String
    var onOpen: (() -> Void)?
    var openLabel: String?
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String? = nil, title: String, onOpen: (() -> Void)? = nil, openLabel: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.title = title; self.onOpen = onOpen
        self.openLabel = openLabel; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Icon(icon, size: 16)
                    .foregroundStyle(p.textSecondary)
            }
            Text(title)
                .font(FN.font(16, .medium))
                .foregroundStyle(p.foreground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            if let onOpen {
                HeadLink(title: openLabel ?? "Open", action: onOpen)
            }
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Small pieces

struct SectionTitle: View {
    @Environment(\.palette) private var p
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        // The kit's group label: small and grey, never uppercase.
        Text(text)
            .font(FN.small)
            .foregroundStyle(p.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
    }
}

struct EmptyStateView: View {
    @Environment(\.palette) private var p
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(FN.bodyMedium).foregroundStyle(p.text)
            Text(hint).font(FN.body).foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .background(p.surfaceMuted.opacity(0.5), in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
                .strokeBorder(p.border, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// The small rounded label used for tags, counts and inline metadata: the kit's
/// `.badge`, neutral, or in a status tone (always with words).
struct Chip<Content: View>: View {
    @Environment(\.palette) private var p
    var tone: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .font(FN.small)
            .foregroundStyle(tone ?? p.textSecondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .background(tone.map { $0.opacity(0.12) } ?? p.surfaceMuted, in: Capsule())
            // One line, truncated when there is no room — the chip used to
            // insist on its full width and spill out of whatever held it.
            .lineLimit(1)
    }
}

extension Chip where Content == Text {
    init(_ text: String, tone: Color? = nil) {
        self.tone = tone
        self.content = { Text(text) }
    }
}

/// A status label with words (the kit's `.badge-info` and friends): the accent for
/// "new" or "beta", status colours for status.
struct Badge: View {
    @Environment(\.palette) private var p
    let text: String
    var tone: Color?
    var subtle: Color?

    var body: some View {
        Text(text)
            .font(FN.font(11, .medium))
            .foregroundStyle(tone ?? p.accent)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(subtle ?? p.accentSubtle, in: Capsule())
            .fixedSize()
    }
}

/// The quiet link at the end of a card's title row: "All tasks", "Finance".
struct HeadLink: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FN.font(13))
                .foregroundStyle(hovering ? p.foreground : p.textSecondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
    }
}

/// The kit's `.pill`: a suggestion or a filter, round, on a hairline.
struct PillButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    var icon: String?
    let title: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Icon(icon, size: 15) }
                Text(title).lineLimit(1)
            }
            .font(FN.font(13, selected ? .medium : .regular))
            .foregroundStyle(selected || hovering ? p.foreground : p.textSecondary)
            .padding(.leading, icon == nil ? 13 : 11)
            .padding(.trailing, 13)
            .frame(height: 32)
            .background(selected ? p.accentSubtle : (hovering ? p.hover : .clear), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? p.accent : p.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .motion(hovering, Motion.quick)
    }
}

// MARK: - Buttons

/// The square icon button from the web app's `.tap-target`, sized for a pointer.
struct IconButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let name: String
    var size: CGFloat = 18
    var box: CGFloat = 30
    var tone: Color?
    var help: String?
    let action: () -> Void

    init(_ name: String, size: CGFloat = 18, box: CGFloat = 30, tone: Color? = nil,
         help: String? = nil, action: @escaping () -> Void) {
        self.name = name; self.size = size; self.box = box
        self.tone = tone; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(name, size: size)
                .foregroundStyle(tone ?? (hovering ? p.foreground : p.textSecondary))
                .frame(width: box, height: box)
                .background(hovering ? p.hover : .clear, in: Circle())
                .motion(hovering, Motion.quick)
                .contentShape(Circle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(help ?? name)
    }
}

/// A ghost text button: muted until hovered.
struct GhostButton<Label: View>: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    var tone: Color?
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .font(FN.body)
                .foregroundStyle(tone ?? (hovering ? p.foreground : p.textSecondary))
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(hovering ? p.hover : .clear, in: Capsule())
                .motion(hovering, Motion.quick)
                .contentShape(Rectangle())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
    }
}

/// The solid accent button used for primary actions.
struct PrimaryButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let title: String
    var icon: String?
    var tone: Color?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 15) }
                Text(title)
            }
            .font(FN.bodyMedium)
            .foregroundStyle(tone == nil ? p.accentForeground : .white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(tone ?? (hovering ? p.accentStrong : p.accent), in: Capsule())
            .opacity(disabled ? 0.45 : 1)
            .motion(hovering, Motion.quick)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .disabled(disabled)
        .onHover { hovering = $0 && !disabled }
    }
}

/// A bordered secondary button.
struct SecondaryButton: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Icon(icon, size: 15) }
                Text(title)
            }
            .font(FN.bodyMedium)
            .foregroundStyle(p.foreground)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(hovering ? p.surfaceMuted : p.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
            .motion(hovering, Motion.quick)
            .contentShape(Capsule())
        }
        .buttonStyle(.fn)
        .onHover { hovering = $0 }
    }
}

// MARK: - Inputs

/// The borderless text field the app uses inside cards and rows.
struct PlainField: View {
    @Environment(\.palette) private var p
    let placeholder: String
    @Binding var text: String
    var font: Font = FN.body
    var onSubmit: (() -> Void)?

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(p.text)
            .onSubmit { onSubmit?() }
    }
}

/// A bordered input box (`inputBox` in the web app).
struct BoxedField: View {
    @Environment(\.palette) private var p
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(FN.body)
            .foregroundStyle(p.foreground)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(width: width)
            .background(p.surface, in: RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FN.radiusControl, style: .continuous)
                    .strokeBorder(focused ? p.borderStrong : p.border, lineWidth: 1)
            )
            .motion(focused, Motion.quick)
            .onSubmit { onSubmit?() }
            .focused($focused)
    }
}

// MARK: - Progress

/// The budget / board progress bar.
struct ProgressBar: View {
    @Environment(\.palette) private var p
    var ratio: Double
    var tone: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(p.controlTrack)
                Capsule().fill(tone)
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
                    .motion(ratio, Motion.data)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Hover highlight

/// A row that tints on hover, like the web app's `hover:bg-[var(--hover)]`.
struct HoverRow<Content: View>: View {
    @Environment(\.palette) private var p
    @State private var hovering = false
    var cornerRadius: CGFloat = FN.radiusSmall
    @ViewBuilder var content: (Bool) -> Content

    var body: some View {
        content(hovering)
            .background(hovering ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .motion(hovering, Motion.quick)
            .onHover { hovering = $0 }
    }
}

// MARK: - Text fields that do not fight the caret

/// A text field that edits a local copy and writes back on a pause or on blur.
///
/// Binding a `TextField` straight to the store sends every keystroke through a
/// published value and gets the whole string back, which on macOS drops the
/// insertion point to the end — so the middle of a title could not be edited at
/// all. Keeping the draft local leaves the caret alone, and also stops one
/// keystroke re-rendering every view that reads the store.
struct CommittedField: View {
    @Environment(\.palette) private var p

    let placeholder: String
    /// The stored value. Adopted while the field is not being edited.
    let value: String
    var font: Font = FN.body
    var boxed = false
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>?
    var minHeight: CGFloat?
    /// How long to wait after typing stops before writing back. `nil` commits
    /// only when the field loses focus.
    var settle: Duration? = .milliseconds(400)
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var pending: Task<Void, Never>?
    @State private var writeId = UUID()
    @FocusState private var focused: Bool

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(p.text)
            .focused($focused)
            .padding(.horizontal, boxed ? 12 : 0)
            .padding(.vertical, boxed ? 7 : 0)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background {
                if boxed {
                    RoundedRectangle(cornerRadius: axis == .vertical ? 14 : FN.radiusControl, style: .continuous)
                        .fill(p.surface)
                    RoundedRectangle(cornerRadius: axis == .vertical ? 14 : FN.radiusControl, style: .continuous)
                        .strokeBorder(focused ? p.borderStrong : p.border, lineWidth: 1)
                }
            }
            .motion(focused, Motion.quick)
            .onAppear { draft = value }
            .onChange(of: value) { _, latest in
                // Adopt outside changes only when the user is not mid-edit.
                if !focused, latest != draft { draft = latest }
            }
            .onChange(of: draft) { _, latest in
                guard focused else { return }
                pending?.cancel()
                guard let settle else { return }
                PendingWrites.hold(writeId) { onCommit(latest) }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: settle)
                    guard !Task.isCancelled else { return }
                    PendingWrites.release(writeId)
                    onCommit(latest)
                }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onSubmit { commit() }
            .onDisappear { commit() }
    }

    @ViewBuilder
    private var field: some View {
        if let lineLimit {
            TextField(placeholder, text: $draft, axis: axis).lineLimit(lineLimit)
        } else {
            TextField(placeholder, text: $draft, axis: axis)
        }
    }

    private func commit() {
        pending?.cancel()
        pending = nil
        PendingWrites.release(writeId)
        if draft != value { onCommit(draft) }
    }
}

// MARK: - Checkbox

/// The web app's checkbox: a small rounded square that fills with the accent
/// and a white check when on. Replaces AppKit's `.checkbox`.
struct FNCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        FNCheckbox(configuration: configuration)
    }
}

private struct FNCheckbox: View {
    @Environment(\.palette) private var p
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let configuration: ToggleStyleConfiguration

    var body: some View {
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(on ? p.accent : p.surface)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(on ? p.accent : (hovering ? p.textMuted : p.borderStrong), lineWidth: 1.5))
                    .overlay {
                        if on {
                            Icon("check", size: 11)
                                .foregroundStyle(p.accentForeground)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .frame(width: 15, height: 15)
                    .motion(on, Motion.quick)
                configuration.label
            }
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

extension ToggleStyle where Self == FNCheckboxStyle {
    static var fnCheckbox: FNCheckboxStyle { FNCheckboxStyle() }
}

// MARK: - Stepper

/// A number with − and + beside it, in place of AppKit's stepper arrows.
struct NumberStepper: View {
    @Environment(\.palette) private var p
    @Binding var value: Int
    var range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            step("minus", -1)
            Text("\(value)")
                .font(FN.body)
                .monospacedDigit()
                .foregroundStyle(p.text)
                .frame(minWidth: 26)
                .contentTransition(.numericText())
            step("plus", 1)
        }
        .frame(height: 28)
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(1)
            case .decrement: change(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ icon: String, _ delta: Int) -> some View {
        IconButton(icon, size: 12, box: 26, help: delta > 0 ? "More" : "Fewer") { change(delta) }
            .disabled(!range.contains(value + delta))
            .opacity(range.contains(value + delta) ? 1 : 0.4)
    }

    private func change(_ delta: Int) {
        let next = min(range.upperBound, max(range.lowerBound, value + delta))
        if next != value { withAnimation(Motion.quick) { value = next } }
    }
}
