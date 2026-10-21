import SwiftUI

// The "/" menu: type "/" at the start of a line, or after a space, and a card under
// the caret offers what this line can become elsewhere in the app (a task, a
// reminder, spending, a quick note, a question for the assistant), then ways to
// shape it. Arrows move, Return or Tab picks, Escape closes; typing narrows it.
// As the web app's (src/components/notes/NoteEditor.tsx, SLASH).

enum SlashCommand: String, CaseIterable, Identifiable {
    case todo, remind, expense, sticky, ask
    case checklist, bullet, numbered, heading, quote, divider, date, time

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "To-do"
        case .remind: return "Remind me tomorrow"
        case .expense: return "Expense"
        case .sticky: return "Sticky"
        case .ask: return "Ask AI"
        case .checklist: return "Checklist"
        case .bullet: return "Bulleted list"
        case .numbered: return "Numbered list"
        case .heading: return "Heading"
        case .quote: return "Quote"
        case .divider: return "Divider"
        case .date: return "Today's date"
        case .time: return "Time"
        }
    }

    var hint: String {
        switch self {
        case .todo: return "A task linked to this note"
        case .remind: return "A task with a reminder at 9:00"
        case .expense: return "Log what you spent, like lunch 45k"
        case .sticky: return "Pin this line to the top"
        case .ask: return "Send this line to the assistant"
        case .checklist: return "Items to tick off"
        case .bullet: return "A plain list"
        case .numbered: return "A list in order"
        case .heading: return "A section title"
        case .quote: return "Set a passage apart"
        case .divider: return "A line between sections"
        case .date: return "Insert the date"
        case .time: return "Insert the time now"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "todo"
        case .remind: return "bell"
        case .expense: return "finance"
        case .sticky: return "pin"
        case .ask: return "sparkle"
        case .checklist: return "checklist"
        case .bullet: return "listBullet"
        case .numbered: return "listOrdered"
        case .heading: return "textSize"
        case .quote: return "quote"
        case .divider: return "divider"
        case .date: return "calendar"
        case .time: return "clock"
        }
    }

    /// The line becomes something elsewhere, or gets shaped here.
    var acts: Bool { [.todo, .remind, .expense, .sticky, .ask].contains(self) }

    /// What matches what's typed after the "/".
    static func matching(_ query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return allCases }
        return allCases.filter { $0.rawValue.hasPrefix(q) || $0.label.lowercased().contains(q) }
    }
}

/// The card itself.
struct SlashMenuView: View {
    @Environment(\.palette) private var p
    let commands: [SlashCommand]
    let active: Int
    let onPick: (SlashCommand) -> Void
    let onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Turn this line into")
                .font(FN.small).foregroundStyle(p.faint)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                            if index > 0, command.acts != commands[index - 1].acts {
                                Rectangle().fill(p.borderSubtle).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 6)
                            }
                            row(command, on: index == active)
                                .id(command.id)
                                .onHover { if $0 { onHover(index) } }
                                .onTapGesture { onPick(command) }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 320)
                .onChange(of: active) { _, index in
                    guard commands.indices.contains(index) else { return }
                    scroller.scrollTo(commands[index].id, anchor: nil)
                }
            }

            Rectangle().fill(p.borderSubtle).frame(height: 1).padding(.top, 6)
            Text("↑ ↓ to move, Return to insert")
                .font(FN.small).foregroundStyle(p.faint)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 320)
        .background(p.surfaceRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .shadow(color: p.shadow, radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turn this line into")
    }

    private func row(_ command: SlashCommand, on: Bool) -> some View {
        HStack(spacing: 12) {
            Icon(command.icon, size: 18).foregroundStyle(on ? p.accent : p.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.label).font(on ? FN.bodyMedium : FN.body).foregroundStyle(p.text)
                Text(command.hint).font(FN.small).foregroundStyle(p.faint).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("/\(command.rawValue)").font(FN.small).foregroundStyle(p.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(on ? p.accentSubtle : .clear, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}
