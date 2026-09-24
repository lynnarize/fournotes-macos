import AppKit
import SwiftUI

// The text on an open sticky.
//
// A note's `content` is plain text with its structure written into it — "# "
// before a heading, "> " before a quote — which the note editor turns into
// real headings and quotes (NoteDocument). The sticky shows that structure
// too, but keeps editing the plain text: a heading or quote carries the exact
// characters its line started with, hidden, and gets them back when the text
// is read out. So a sticky that isn't typed in reads back character for
// character what it was given, and one that is changes only where it was
// typed.
//
// Bullets, numbers and checkboxes stay as they're written: "•", "1." and "☐"
// already read as what they are.

enum StickyText {
    /// On a heading's or quote's text: the characters its line started with
    /// in `content` ("# ", "  > "), which the sticky doesn't show.
    static let marker = NSAttributedString.Key("fournotes.stickyMarker")

    struct Palette: Equatable {
        let text: NSColor
        let faint: NSColor

        init(_ paper: StickyPaper) {
            // In sRGB, so the same paper compares equal from one update to the next.
            text = NSColor(paper.text).usingColorSpace(.sRGB) ?? .textColor
            faint = NSColor(paper.faint).usingColorSpace(.sRGB) ?? .secondaryLabelColor
        }
    }

    static let bodySize: CGFloat = 13

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: 16, weight: .bold)
        case 2: .systemFont(ofSize: 14.5, weight: .bold)
        default: .systemFont(ofSize: bodySize, weight: .bold)
        }
    }

    private static var quoteStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 10
        style.headIndent = 10
        return style
    }

    /// How a line looks, from the marker it carries (nil for ordinary text).
    static func attributes(_ prefix: String?, palette: Palette) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bodySize),
            .foregroundColor: palette.text,
        ]
        guard let prefix else { return attributes }
        attributes[marker] = prefix
        // A marker is either a heading's #s or a quote's >.
        let level = prefix.count(where: { $0 == "#" })
        if level > 0 {
            attributes[.font] = headingFont(level)
        } else {
            attributes[.foregroundColor] = palette.faint
            attributes[.paragraphStyle] = quoteStyle
        }
        return attributes
    }

    // MARK: - Content -> what the sticky shows

    static func attributed(_ content: String, palette: Palette) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        // Only "\n" ends a line, here and in `plainText`, so a "\r" survives.
        for (index, line) in content.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            if let (prefix, text) = split(line) {
                out.append(NSAttributedString(string: String(text), attributes: [marker: prefix]))
            } else {
                out.append(NSAttributedString(string: line))
            }
        }
        restyle(out, palette: palette)
        return out
    }

    /// A heading's or quote's marker as written, and the text after it —
    /// only when there is text after it: an empty line has nothing to keep
    /// its marker on, so "# " alone stays as it's written.
    static func split(_ line: String) -> (prefix: String, text: Substring)? {
        guard let (_, text) = NoteDocument.lineMarker(line),
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return (String(line[..<text.startIndex]), text)
    }

    // MARK: - What the sticky shows -> content

    static func plainText(from shown: NSAttributedString) -> String {
        let string = shown.string as NSString
        return lines(in: string).map { line in
            let text = string.substring(with: line)
            guard line.length > 0,
                  let prefix = shown.attribute(marker, at: line.location, effectiveRange: nil) as? String
            else { return text }
            return prefix + text
        }.joined(separator: "\n")
    }

    // MARK: - Lines

    /// Each line's range, without its newline.
    static func lines(in string: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        while true {
            let rest = NSRange(location: start, length: string.length - start)
            let newline = string.range(of: "\n", range: rest)
            guard newline.location != NSNotFound else {
                out.append(rest)
                return out
            }
            out.append(NSRange(location: start, length: newline.location - start))
            start = NSMaxRange(newline)
        }
    }

    /// The lines `range` touches, counting the line either end of it is on.
    static func lines(in string: NSString, touching range: NSRange) -> [NSRange] {
        lines(in: string).filter { $0.location <= NSMaxRange(range) && NSMaxRange($0) >= range.location }
    }

    /// Styles each line by what its first character says it is, and makes the
    /// whole line say the same: text typed or joined into a heading becomes
    /// part of it, and a heading's words moved onto another line don't take
    /// the heading with them.
    static func restyle(_ text: NSMutableAttributedString, palette: Palette, touching range: NSRange? = nil) {
        let string = text.string as NSString
        let lines = range.map { lines(in: string, touching: $0) } ?? lines(in: string)
        text.beginEditing()
        for line in lines {
            let prefix = line.length > 0
                ? text.attribute(marker, at: line.location, effectiveRange: nil) as? String
                : nil
            let attributes = attributes(prefix, palette: palette)
            text.setAttributes(attributes, range: line)
            // The newline keeps the line's paragraph style but not its marker
            // or font, so the line typed below a heading isn't one.
            if NSMaxRange(line) < string.length {
                var newline = self.attributes(nil, palette: palette)
                newline[.paragraphStyle] = attributes[.paragraphStyle]
                text.setAttributes(newline, range: NSRange(location: NSMaxRange(line), length: 1))
            }
        }
        text.endEditing()
    }
}

/// The sticky's writing surface: an NSTextView over `StickyText`, bound to the
/// note's plain text.
struct StickyTextView: NSViewRepresentable {
    @Binding var text: String
    /// Whether it has the keyboard; set to move the keyboard to it or away.
    @Binding var editing: Bool
    let editable: Bool
    let palette: StickyText.Palette
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = StickyScrollView()
        scroll.documentView = Self.makeTextView(context.coordinator)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        return scroll
    }

    static func makeTextView(_ coordinator: Coordinator) -> StickyNSTextView {
        // TextKit 1: under TextKit 2 an undo changes the text without telling
        // the delegate, so an undone edit was never saved.
        let textView = StickyNSTextView(usingTextLayoutManager: false)
        textView.delegate = coordinator
        textView.onFocus = { [weak coordinator] on in coordinator?.focusChanged(on) }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = coordinator.parent.editable
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.writingToolsBehavior = .none
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        coordinator.load(coordinator.parent.text, into: textView)
        return textView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? StickyNSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self
        textView.isEditable = editable
        textView.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        textView.insertionPointColor = palette.text

        if text != coordinator.shown {
            // Changed somewhere else: in the app, by the assistant.
            coordinator.load(text, into: textView)
        } else if palette != coordinator.palette, let storage = textView.textStorage {
            coordinator.palette = palette
            StickyText.restyle(storage, palette: palette)
            coordinator.fixTypingAttributes(textView)
        }

        // Only a change asked for here moves the keyboard. The text view's own
        // reports of it arrive a turn later, and must not be undone meanwhile.
        if editing != coordinator.lastEditing {
            coordinator.lastEditing = editing
            let focused = textView.window?.firstResponder === textView
            if editing != focused, let window = textView.window {
                coordinator.movingFocus = true
                window.makeFirstResponder(editing ? textView : nil)
                coordinator.movingFocus = false
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StickyTextView
        /// The content the text view shows, as last put in or read out.
        private(set) var shown: String?
        var palette: StickyText.Palette?
        var lastEditing = false
        var movingFocus = false
        /// Where the edits since the last change landed, to restyle just those lines.
        private var edited: NSRange?
        /// Set while tidying up after an edit, which edits too.
        private var tidying = false

        init(_ parent: StickyTextView) { self.parent = parent }

        func load(_ text: String, into textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selected = textView.selectedRange()
            palette = parent.palette
            storage.setAttributedString(StickyText.attributed(text, palette: parent.palette))
            shown = text
            // NSRange counts UTF-16 units, as the storage does.
            textView.setSelectedRange(NSRange(location: min(selected.location, storage.length), length: 0))
            fixTypingAttributes(textView)
        }

        func focusChanged(_ on: Bool) {
            guard !movingFocus else { return }
            DispatchQueue.main.async { [self] in
                if parent.editing != on { parent.editing = on }
            }
        }

        // MARK: - Editing

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString: String?) -> Bool {
            guard !tidying else { return true }
            let landed = NSRange(location: range.location,
                                 length: replacementString.map { ($0 as NSString).length } ?? range.length)
            edited = edited.map { NSUnionRange($0, landed) } ?? landed
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !tidying, let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            let range = clamp(edited ?? NSRange(location: 0, length: storage.length), to: storage)
            edited = nil
            // Text still being composed (an input method's marked text) is
            // left alone until it's committed, which changes it again.
            if !textView.hasMarkedText() {
                tidying = true
                let touched = convertMarkers(textView, in: range)
                StickyText.restyle(storage, palette: parent.palette, touching: touched)
                tidying = false
                fixTypingAttributes(textView)
            }
            let plain = StickyText.plainText(from: storage)
            guard plain != shown else { return }
            shown = plain
            parent.text = plain
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !tidying, let textView = notification.object as? NSTextView else { return }
            fixTypingAttributes(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                return unmark(textView)
            default:
                return false
            }
        }

        /// What's typed takes the look of the line it's typed into; on an
        /// empty line, ordinary text.
        func fixTypingAttributes(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let caret = textView.selectedRange()
            guard caret.length == 0 else { return }
            let string = storage.string as NSString
            let line = StickyText.lines(in: string, touching: NSRange(location: caret.location, length: 0))
                .last ?? NSRange(location: 0, length: 0)
            let prefix = line.length > 0
                ? storage.attribute(StickyText.marker, at: line.location, effectiveRange: nil) as? String
                : nil
            textView.typingAttributes = StickyText.attributes(prefix, palette: parent.palette)
        }

        /// A marker typed or pasted at the front of a line — "# ", "> " —
        /// becomes the heading or quote it spells, as it would on reopening.
        /// Not while undoing, which would only do it again. Returns the edited
        /// range, less what was taken out.
        private func convertMarkers(_ textView: NSTextView, in range: NSRange) -> NSRange {
            guard let storage = textView.textStorage else { return range }
            if let undo = textView.undoManager, undo.isUndoing || undo.isRedoing { return range }
            var touched = range
            let string = storage.string as NSString
            // Last first, so the ranges before it stay put.
            for line in StickyText.lines(in: string, touching: range).reversed() where line.length > 0 {
                guard storage.attribute(StickyText.marker, at: line.location, effectiveRange: nil) == nil,
                      let (prefix, text) = StickyText.split(string.substring(with: line)) else { continue }
                // The whole line in one replacement, marker and all, so undo
                // and redo put back exactly what was there.
                let replacement = NSAttributedString(
                    string: String(text), attributes: StickyText.attributes(prefix, palette: parent.palette))
                let cut = (prefix as NSString).length
                let selection = textView.selectedRange()
                // Its own undo step, not folded into the typing before it.
                textView.breakUndoCoalescing()
                guard textView.shouldChangeText(in: line, replacementString: replacement.string) else { continue }
                storage.replaceCharacters(in: line, with: replacement)
                textView.didChangeText()
                textView.breakUndoCoalescing()
                textView.setSelectedRange(shifted(selection, removing: NSRange(location: line.location, length: cut)))
                touched.length = max(0, touched.length - cut)
            }
            return clamp(touched, to: storage)
        }

        /// Backspace at the start of a heading or quote takes off its marker,
        /// as it would the "# " the line started with — turning it back into
        /// ordinary text, rather than joining it to the line above.
        private func unmark(_ textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage else { return false }
            let caret = textView.selectedRange()
            let string = storage.string as NSString
            guard caret.length == 0,
                  let line = StickyText.lines(in: string, touching: caret).last,
                  line.location == caret.location, line.length > 0,
                  storage.attribute(StickyText.marker, at: line.location, effectiveRange: nil) != nil
            else { return false }
            let plain = NSAttributedString(string: string.substring(with: line),
                                           attributes: StickyText.attributes(nil, palette: parent.palette))
            guard textView.shouldChangeText(in: line, replacementString: plain.string) else { return true }
            storage.replaceCharacters(in: line, with: plain)
            textView.didChangeText()
            textView.setSelectedRange(caret)
            return true
        }

        private func shifted(_ selection: NSRange, removing cut: NSRange) -> NSRange {
            var location = selection.location
            if location >= NSMaxRange(cut) {
                location -= cut.length
            } else if location > cut.location {
                location = cut.location
            }
            return NSRange(location: location, length: selection.length)
        }

        private func clamp(_ range: NSRange, to storage: NSTextStorage) -> NSRange {
            let location = min(range.location, storage.length)
            return NSRange(location: location, length: min(range.length, storage.length - location))
        }
    }
}

final class StickyNSTextView: NSTextView {
    var onFocus: (@MainActor (Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }
}

/// Keeps the text at least as tall as the sheet, so a click anywhere below
/// the last line puts the caret at the end.
private final class StickyScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let textView = documentView as? NSTextView,
              textView.minSize.height != contentSize.height else { return }
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.sizeToFit()
    }
}
