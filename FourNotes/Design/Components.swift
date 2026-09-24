import SwiftUI

// The shared UI kit, ported from src/components/ui.tsx.

// MARK: - Card

/// The rounded box every tab uses (Notes editor, task panel, Today, Finance).
struct Card<Content: View>: View {
    @Environment(\.palette) private var p
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.bg)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(p.line, lineWidth: 1))
            .shadow(color: p.shadow, radius: 8, y: 2)
            .entrance()
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
                Icon(icon, size: 18)
                    .foregroundStyle(p.text)
                    .frame(width: 40, height: 40)
                    .background(p.hover, in: Circle())
            }
            Text(title)
                .font(FN.serif(18))
                .foregroundStyle(p.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            if let onOpen {
                IconButton("arrowUpRight", size: 18, help: openLabel, action: onOpen)
            }
        }
        .frame(minHeight: 40)
    }
}

// MARK: - Small pieces

struct SectionTitle: View {
    @Environment(\.palette) private var p
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(FN.font(11, .semibold))
            .tracking(0.6)
            .foregroundStyle(p.muted)
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
        .overlay(
            RoundedRectangle(cornerRadius: FN.radius, style: .continuous)
                .strokeBorder(p.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

/// The small rounded label used for tags, counts and inline metadata.
struct Chip<Content: View>: View {
    @Environment(\.palette) private var p
    var tone: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .font(FN.small)
            .foregroundStyle(tone ?? p.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tone ?? p.muted).opacity(tone == nil ? 0 : 0.12))
            .background(tone == nil ? p.hover : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
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
                .foregroundStyle(tone ?? (hovering ? p.text : p.muted))
                .frame(width: box, height: box)
                .background(hovering ? p.hover : .clear,
                            in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
                .scaleEffect(hovering ? 1.04 : 1)
                .motion(hovering, Motion.quick)
                .contentShape(Rectangle())
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
                .foregroundStyle(tone ?? (hovering ? p.text : p.muted))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? p.hover : .clear,
                            in: RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous))
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
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background((tone ?? p.accent).opacity(disabled ? 0.4 : (hovering ? 0.88 : 1)),
                        in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
            .motion(hovering, Motion.quick)
            .scaleEffect(hovering && !disabled ? 1.02 : 1)
            .contentShape(Rectangle())
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
            .foregroundStyle(p.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(hovering ? p.hover : .clear,
                        in: RoundedRectangle(cornerRadius: FN.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FN.radius, style: .continuous).stroke(p.line, lineWidth: 1))
            .motion(hovering, Motion.quick)
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
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
            .foregroundStyle(p.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                    .stroke(focused ? p.accent.opacity(0.55) : p.line, lineWidth: 1)
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
                Capsule().fill(p.finRest)
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
            .padding(.horizontal, boxed ? 8 : 0)
            .padding(.vertical, boxed ? 5 : 0)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background {
                if boxed {
                    RoundedRectangle(cornerRadius: FN.radiusSmall, style: .continuous)
                        .stroke(focused ? p.accent.opacity(0.55) : p.line, lineWidth: 1)
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
