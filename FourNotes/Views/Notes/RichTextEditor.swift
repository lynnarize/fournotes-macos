import AppKit
import SwiftUI

// The note editor's writing surface: an NSTextView with real NSTextLists and
// clickable checkboxes. What it stores is in NoteDocument.swift.
//
// Two rules hold this together, and both were broken before:
//
//   - Every mutation goes through shouldChangeText/didChangeText, so undo
//     stays in step with the document.
//   - SwiftUI only pushes text in when it came from outside the editor — a
//     note being opened — never the editor's own text coming back to it.
//     Comparing contents instead overwrote what AppKit holds without saying
//     so: the character just typed, an inline prediction, characters
//     half-typed with an input method.

/// What the toolbar needs to know about the current selection.
struct RichTextState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var superscript = false
    var `subscript` = false
    var fontFamily = ""
    var fontSize: CGFloat = NoteDocument.bodySize
    var color = ""
    var highlight = ""
    var alignment: NSTextAlignment = .natural
    var headingLevel: Int?
    var isBulletList = false
    var isNumberedList = false
    var isChecklist = false
    var isQuote = false
    var isCode = false
    var canUndo = false
    var canRedo = false

    var inList: Bool { isBulletList || isNumberedList || isChecklist }
}

@MainActor
final class RichTextController: ObservableObject {
    @Published var state = RichTextState()
    fileprivate weak var textView: NSTextView?

    func focus() { textView?.window?.makeFirstResponder(textView) }
    func undo() { textView?.undoManager?.undo(); refreshState() }
    func redo() { textView?.undoManager?.redo(); refreshState() }

    /// macOS's own dictation, into this note. It is what the web app's mic
    /// button approximates with the Web Speech API — here it is the real thing,
    /// with its own permission prompt and on-device recognition.
    func startDictation() {
        focus()
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }

    /// The selection, or nil when nothing is selected.
    var selection: (range: NSRange, text: String)? {
        guard let tv = textView, let storage = tv.textStorage else { return nil }
        let range = tv.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let text = NoteDocument.plainText(from: storage.attributedSubstring(from: range))
        return text.isEmpty ? nil : (range, text)
    }

    /// Replaces `range` (or the whole note) with plain text, as one undo step.
    func replace(_ range: NSRange?, withPlainText text: String) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let target = range.flatMap { NSMaxRange($0) <= storage.length ? $0 : nil }
            ?? NSRange(location: 0, length: storage.length)
        let replacement = NoteDocument.attributed(fromPlainText: text)
        guard tv.shouldChangeText(in: target, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: target, with: replacement)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: target.location + replacement.length, length: 0))
        refreshState()
    }

    /// Adds plain text as new paragraphs after `range` (or at the end).
    func insertBelow(_ range: NSRange?, plainText text: String) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let string = storage.string as NSString
        var at = storage.length
        if let range, NSMaxRange(range) <= storage.length {
            at = NSMaxRange(string.paragraphRange(for: range))
        }
        let block = NSMutableAttributedString()
        // Start on a fresh line, with a blank one between it and what was there.
        if at > 0, string.character(at: at - 1) != 0x0A {
            block.append(NSAttributedString(string: "\n", attributes: NoteDocument.baseAttributes))
        }
        if at > 0 { block.append(NSAttributedString(string: "\n", attributes: NoteDocument.baseAttributes)) }
        block.append(NoteDocument.attributed(fromPlainText: text))
        if at < storage.length {
            block.append(NSAttributedString(string: "\n", attributes: NoteDocument.baseAttributes))
        }
        let insertion = NSRange(location: at, length: 0)
        guard tv.shouldChangeText(in: insertion, replacementString: block.string) else { return }
        storage.replaceCharacters(in: insertion, with: block)
        tv.didChangeText()
        tv.scrollRangeToVisible(NSRange(location: at + block.length, length: 0))
        refreshState()
    }

    var plainText: String {
        guard let storage = textView?.textStorage else { return "" }
        return NoteDocument.plainText(from: storage)
    }

    // MARK: - Inline marks

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    func toggleUnderline() {
        toggleAttribute(.underlineStyle, on: NSUnderlineStyle.single.rawValue) { ($0 as? Int ?? 0) != 0 }
    }

    func toggleStrikethrough() {
        toggleAttribute(.strikethroughStyle, on: NSUnderlineStyle.single.rawValue) { ($0 as? Int ?? 0) != 0 }
    }

    func toggleSuperscript() { toggleAttribute(.superscript, on: 1) { ($0 as? Int ?? 0) > 0 } }
    func toggleSubscript() { toggleAttribute(.superscript, on: -1) { ($0 as? Int ?? 0) < 0 } }

    /// "Default" is the theme's text colour, as the note's text starts out.
    /// Removing the colour instead left text with none, drawn black whatever
    /// the theme.
    func setColor(_ hex: String) {
        apply(.foregroundColor, hex.isEmpty ? NSColor.labelColor : NSColor(hex: hex) ?? .labelColor)
    }

    func setHighlight(_ hex: String) {
        hex.isEmpty ? remove(.backgroundColor) : apply(.backgroundColor, NSColor(hex: hex) ?? .clear)
    }

    /// The toolbar's name for the system's rounded face. It is not a family
    /// that can be asked for by name — "SF Pro Rounded" is only there when the
    /// SF fonts have been installed, so choosing Rounded did nothing.
    nonisolated static let roundedFamily = "SF Pro Rounded"

    /// The system font's rounded design, under the family name AppKit gives it.
    private static let roundedSystemFamily = NSFont.systemFont(ofSize: NoteDocument.bodySize).fontDescriptor
        .withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: NoteDocument.bodySize) }?.familyName

    /// The family a toolbar choice means: "" is the system font.
    private static func familyName(for choice: String, size: CGFloat) -> String? {
        switch choice {
        case "": return NSFont.systemFont(ofSize: size).familyName
        case roundedFamily: return roundedSystemFamily
        default: return choice
        }
    }

    func setFontFamily(_ family: String) {
        mutateFonts { font, manager in
            guard let name = Self.familyName(for: family, size: font.pointSize) else { return font }
            return manager.convert(font, toFamily: name)
        }
    }

    func setFontSize(_ size: CGFloat) {
        mutateFonts { font, manager in manager.convert(font, toSize: size) }
    }

    // MARK: - Paragraphs

    /// A heading level, or with nil, normal text — which also takes a
    /// paragraph out of a quote, since the menu's "Normal text" is the one
    /// without either.
    func setHeading(_ level: Int?) {
        editParagraphs { paragraph in
            var change: [NSAttributedString.Key: Any] = [.font: NoteDocument.headingFont(level ?? 0)]
            if level == nil, paragraph.isQuote {
                change[.paragraphStyle] = NSParagraphStyle.default
                change[.foregroundColor] = NSColor.labelColor
            }
            return change
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        editParagraphs { paragraph in
            let updated = (paragraph.style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            updated.alignment = alignment
            return [.paragraphStyle: updated]
        }
    }

    func toggleQuote() {
        let on = state.isQuote
        editParagraphs { _ in
            [.paragraphStyle: on ? NSParagraphStyle.default : NoteDocument.quoteParagraphStyle(),
             .foregroundColor: on ? NSColor.labelColor : NSColor.secondaryLabelColor]
        }
    }

    func toggleBulletList() { toggleList(.disc, isOn: state.isBulletList) }
    func toggleNumberedList() { toggleList(.decimal, isOn: state.isNumberedList) }

    /// Puts the selection in a list of this kind, or takes it out of one.
    /// A list of the other kind changes kind; a nested item keeps its level.
    private func toggleList(_ format: NSTextList.MarkerFormat, isOn: Bool) {
        // A checklist and a bullet list are different things; leaving one enters
        // the other.
        if state.isChecklist { toggleChecklist() }
        // Continue a list just above or below rather than starting a new one,
        // so a numbered item added under "1." becomes "2.".
        let list = neighbourList(format) ?? NSTextList(markerFormat: format, options: 0)
        // Siblings changing kind together stay one list.
        var changed: [ObjectIdentifier: NSTextList] = [:]
        editParagraphs { paragraph in
            if isOn { return [.paragraphStyle: NSParagraphStyle.default] }
            var lists = paragraph.style.textLists
            guard lists.count > 1, let own = lists.last else {
                return [.paragraphStyle: NoteDocument.listParagraphStyle(list)]
            }
            if own.markerFormat != format {
                let key = ObjectIdentifier(own)
                let replacement = changed[key] ?? NSTextList(markerFormat: format, options: 0)
                changed[key] = replacement
                lists[lists.count - 1] = replacement
            }
            return [.paragraphStyle: NoteDocument.listParagraphStyle(lists)]
        }
    }

    /// The top-level list of this kind next to the selection: the paragraph
    /// above it, or failing that, the one below.
    private func neighbourList(_ format: NSTextList.MarkerFormat) -> NSTextList? {
        guard let storage = textView?.textStorage else { return nil }
        let paragraphs = paragraphRanges()
        guard let first = paragraphs.first, let last = paragraphs.last else { return nil }
        for index in [first.location - 1, NSMaxRange(last)] where index >= 0 && index < storage.length {
            let style = storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
            if let list = style?.textLists.first, list.markerFormat == format { return list }
        }
        return nil
    }

    /// Nests list items one level deeper — or, with `-1`, brings them back out.
    /// Checklist items move by indent, since their checkbox is not a marker.
    func shiftDepth(_ delta: Int) {
        settleMarkedText()
        guard let storage = textView?.textStorage else { return }
        guard state.inList else { return }
        // Siblings indented together join one nested list rather than each
        // starting its own at "1.".
        var nested: [ObjectIdentifier: NSTextList] = [:]
        let above = paragraphRanges().first.flatMap { first -> NSParagraphStyle? in
            guard first.location > 0 else { return nil }
            return storage.attribute(.paragraphStyle, at: first.location - 1,
                                     effectiveRange: nil) as? NSParagraphStyle
        }

        editParagraphs { paragraph in
            if paragraph.isChecklist {
                let depth = NoteDocument.checklistDepth(paragraph.style) + delta
                guard (0...NoteDocument.maxDepth).contains(depth) else { return [:] }
                return [.paragraphStyle: NoteDocument.checklistParagraphStyle(depth: depth)]
            }
            var lists = paragraph.style.textLists
            guard let parent = lists.last else { return [:] }
            if delta > 0 {
                guard lists.count <= NoteDocument.maxDepth else { return [:] }
                let key = ObjectIdentifier(parent)
                if nested[key] == nil {
                    // Join the item above if it is already one level in.
                    if let above, above.textLists.count == lists.count + 1,
                       zip(above.textLists, lists).allSatisfy({ $0 === $1 }) {
                        nested[key] = above.textLists.last
                    } else {
                        nested[key] = NSTextList(markerFormat: parent.markerFormat, options: 0)
                    }
                }
                lists.append(nested[key]!)
            } else {
                guard lists.count > 1 else { return [:] }
                lists.removeLast()
            }
            return [.paragraphStyle: NoteDocument.listParagraphStyle(lists)]
        }
    }

    /// A code block: the paragraph in a monospaced face. Plain text keeps the
    /// lines; the native archive keeps the face.
    func toggleCode() {
        let on = state.isCode
        editParagraphs { _ in [.font: on ? NoteDocument.bodyFont : NoteDocument.codeFont] }
    }

    /// Checkboxes are attachments rather than list markers, because a marker
    /// cannot be clicked.
    func toggleChecklist() {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let paragraphs = paragraphRanges()
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let adding = !state.isChecklist

        // Built aside and put in as one replacement. This adds and removes
        // characters, and undo has to be told what they become: declared as a
        // change of attributes, an undo put the old style back and left the
        // box in the text.
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let edited = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: whole))
        /// Where characters went in or out, to keep the selection on its text.
        var changes: [(at: Int, removed: Int, inserted: Int)] = []
        // Back to front, so earlier ranges stay valid as lengths change.
        for paragraph in paragraphs.reversed() {
            let range = NSRange(location: paragraph.location - whole.location, length: paragraph.length)
            if adding {
                // A nested list item stays at its level as a checklist item.
                let lists = (edited.length > range.location
                    ? edited.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                    : nil)?.textLists.count ?? 0
                edited.addAttribute(.paragraphStyle,
                                    value: NoteDocument.checklistParagraphStyle(depth: max(0, lists - 1)),
                                    range: range)
                let box = NSAttributedString(attachment: CheckboxAttachment(checked: false))
                let prefix = NSMutableAttributedString(attributedString: box)
                prefix.append(NSAttributedString(string: " "))
                prefix.addAttributes(NoteDocument.baseAttributes,
                                     range: NSRange(location: 0, length: prefix.length))
                edited.insert(prefix, at: range.location)
                changes.append((paragraph.location, 0, prefix.length))
            } else if let boxRange = checkboxRange(in: range, of: edited) {
                // Take the space after it too.
                var cut = boxRange
                let after = NSMaxRange(boxRange)
                if after < edited.length,
                   (edited.string as NSString).substring(with: NSRange(location: after, length: 1)) == " " {
                    cut.length += 1
                }
                edited.deleteCharacters(in: cut)
                let remaining = NSRange(location: range.location,
                                        length: max(0, range.length - cut.length))
                edited.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: remaining)
                changes.append((cut.location + whole.location, cut.length, 0))
            }
        }

        let selected = tv.selectedRange()
        guard tv.shouldChangeText(in: whole, replacementString: edited.string) else { return }
        storage.replaceCharacters(in: whole, with: edited)
        tv.didChangeText()

        func moved(_ location: Int) -> Int {
            changes.reduce(location) { result, change in
                guard location >= change.at else { return result }
                return result + change.inserted - min(change.removed, location - change.at)
            }
        }
        let start = moved(selected.location)
        tv.setSelectedRange(NSRange(location: start, length: max(0, moved(NSMaxRange(selected)) - start)))
        // What is typed next takes the item's new indent, not the one it had.
        if selected.length == 0 {
            let paragraph = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
            tv.typingAttributes[.paragraphStyle] = paragraph.length > 0
                ? storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                : NSParagraphStyle.default
        }
        refreshState()
    }

    /// Return in a checklist item starts the next item with an empty box, as
    /// Return does in a bulleted list; Return on an item with nothing written
    /// in it ends the checklist instead. False when the caret is not in a
    /// checklist item, for an ordinary newline.
    func insertNewlineInChecklist() -> Bool {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let selection = tv.selectedRange()
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
        guard let box = checkboxRange(in: paragraph, of: storage), box.location == paragraph.location else {
            return false
        }
        let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle

        // In front of the box: a plain line goes in above the item.
        if selection.location <= box.location {
            var attributes = NoteDocument.baseAttributes
            attributes[.paragraphStyle] = NSParagraphStyle.default
            let line = NSAttributedString(string: "\n", attributes: attributes)
            guard tv.shouldChangeText(in: selection, replacementString: line.string) else { return true }
            storage.replaceCharacters(in: selection, with: line)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            refreshState()
            return true
        }

        let written = text.substring(with: NSRange(location: NSMaxRange(box),
                                                   length: NSMaxRange(textRange(of: paragraph, in: text))
                                                       - NSMaxRange(box)))
        if selection.length == 0, written.trimmingCharacters(in: .whitespaces).isEmpty {
            refreshState()
            // A nested item comes out a level first, as a list item does.
            NoteDocument.checklistDepth(style) > 0 ? shiftDepth(-1) : toggleChecklist()
            return true
        }

        var attributes = tv.typingAttributes
        attributes[.link] = nil
        attributes[.attachment] = nil
        attributes[.paragraphStyle] = NoteDocument.checklistParagraphStyle(depth: NoteDocument.checklistDepth(style))
        let item = NSMutableAttributedString(string: "\n", attributes: attributes)
        let prefix = NSMutableAttributedString(attachment: CheckboxAttachment(checked: false))
        prefix.append(NSAttributedString(string: " "))
        var boxAttributes = NoteDocument.baseAttributes
        boxAttributes[.paragraphStyle] = attributes[.paragraphStyle]
        prefix.addAttributes(boxAttributes, range: NSRange(location: 0, length: prefix.length))
        item.append(prefix)

        guard tv.shouldChangeText(in: selection, replacementString: item.string) else { return true }
        storage.replaceCharacters(in: selection, with: item)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: selection.location + item.length, length: 0))
        tv.typingAttributes = attributes
        tv.scrollRangeToVisible(tv.selectedRange())
        refreshState()
        return true
    }

    /// The caret is at the end of a heading — one of the toolbar's, not just
    /// large text.
    var caretEndsHeading: Bool {
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let selection = tv.selectedRange()
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: selection)
        guard selection.length == 0, paragraph.length > 0,
              selection.location == NSMaxRange(textRange(of: paragraph, in: text)),
              let font = tv.typingAttributes[.font] as? NSFont,
              let level = NoteDocument.headingLevel(of: font) else { return false }
        return font == NoteDocument.headingFont(level)
    }

    /// Backspace at the very start of a list or checklist item takes its
    /// bullet, number or box away — a nested item comes out a level — and
    /// leaves the text as a plain line, rather than joining it to the line
    /// above. False anywhere else, for an ordinary backspace.
    func deleteMarkerBeforeCaret() -> Bool {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return false }
        let selection = tv.selectedRange()
        guard selection.length == 0 else { return false }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: selection)
        guard paragraph.length > 0 else { return false }
        let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle

        if let box = checkboxRange(in: paragraph, of: storage), box.location == paragraph.location {
            var start = NSMaxRange(box)
            if start < text.length, text.character(at: start) == 0x20 { start += 1 }
            guard selection.location == start else { return false }
            refreshState()
            NoteDocument.checklistDepth(style) > 0 ? shiftDepth(-1) : toggleChecklist()
            return true
        }

        guard selection.location == paragraph.location, let lists = style?.textLists, !lists.isEmpty else {
            return false
        }
        refreshState()
        if lists.count > 1 {
            shiftDepth(-1)
        } else {
            editParagraphs { _ in [.paragraphStyle: NSParagraphStyle.default] }
        }
        return true
    }

    func toggleCheckbox(at index: Int) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage, index < storage.length,
              let box = storage.attribute(.attachment, at: index, effectiveRange: nil)
                  as? CheckboxAttachment else { return }
        let range = NSRange(location: index, length: 1)
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        box.isChecked.toggle()
        // The attachment is drawn from its own state, so the layout has to be
        // told the glyph changed.
        storage.edited(.editedAttributes, range: range, changeInLength: 0)
        tv.didChangeText()
    }

    func insertDivider() {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let string = storage.string as NSString
        let block = NSMutableAttributedString()
        if range.location > 0, string.character(at: range.location - 1) != 0x0A {
            block.append(NSAttributedString(string: "\n", attributes: NoteDocument.baseAttributes))
        }
        block.append(NoteDocument.divider())
        block.append(NSAttributedString(string: "\n", attributes: NoteDocument.baseAttributes))
        guard tv.shouldChangeText(in: range, replacementString: block.string) else { return }
        storage.replaceCharacters(in: range, with: block)
        tv.didChangeText()
        // Typing carries on in plain body text, not in the divider's style.
        tv.typingAttributes = NoteDocument.baseAttributes
    }
    func insertText(_ text: String) { insert(text) }

    /// What the link field's text means as a link: "example.com" is a web
    /// address, "someone@example.com" an email. Nil when it can't be one.
    static func linkURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), url.scheme != nil { return url }
        let scheme = text.contains("@") && !text.contains("/") ? "mailto:" : "https://"
        return URL(string: scheme + text)
            ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap { URL(string: scheme + $0) }
    }

    /// Links the selected text — keeping its formatting — or, with nothing
    /// selected, puts `title` in as a link.
    func insertLink(_ url: String, title: String) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage, let link = Self.linkURL(url) else { return }
        let range = tv.selectedRange()
        let look: [NSAttributedString.Key: Any] = [
            .link: link,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        if range.length > 0 {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.addAttributes(look, range: range)
            tv.didChangeText()
            refreshState()
            return
        }
        var attributes = typingAttributes(of: tv)
        let plain = attributes
        attributes.merge(look) { $1 }
        let label = NSAttributedString(string: title.isEmpty ? url : title, attributes: attributes)
        guard tv.shouldChangeText(in: range, replacementString: label.string) else { return }
        storage.replaceCharacters(in: range, with: label)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + label.length, length: 0))
        // Typing on after it is ordinary text, not more of the link.
        tv.typingAttributes = plain
        refreshState()
    }

    /// Takes the look off the text — face, size, colour, highlight, marks,
    /// links, alignment — and leaves its structure: a list's markers and a
    /// checklist's boxes stay. Setting plain attributes over a checkbox used
    /// to strip it to a bare "￼" character.
    func clearFormatting() {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = effectiveRange()
        let text = storage.string as NSString

        func plain(_ attributes: [NSAttributedString.Key: Any], in paragraph: NSRange) -> [NSAttributedString.Key: Any] {
            var cleared = NoteDocument.baseAttributes
            cleared[.attachment] = attributes[.attachment]
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               !style.textLists.isEmpty || checkboxRange(in: paragraph, of: storage) != nil {
                let kept = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                kept.alignment = .natural
                cleared[.paragraphStyle] = kept
            }
            return cleared
        }

        if range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) {
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            storage.enumerateAttributes(in: range, options: []) { attributes, run, _ in
                runs.append((run, plain(attributes, in: text.paragraphRange(for: run))))
            }
            storage.beginEditing()
            for (run, attributes) in runs { storage.setAttributes(attributes, range: run) }
            storage.endEditing()
            tv.didChangeText()
        }
        // What is typed next is plain too.
        if tv.selectedRange().length == 0 {
            let paragraph = text.paragraphRange(for: tv.selectedRange())
            tv.typingAttributes = plain(paragraph.length > 0
                                            ? storage.attributes(at: paragraph.location, effectiveRange: nil)
                                            : tv.typingAttributes,
                                        in: paragraph)
        }
        refreshState()
    }

    // MARK: - Ranges

    private func effectiveRange() -> NSRange {
        guard let tv = textView else { return NSRange(location: 0, length: 0) }
        let selected = tv.selectedRange()
        return selected.length > 0 ? selected : currentParagraph()
    }

    private func currentParagraph() -> NSRange {
        guard let tv = textView, let storage = tv.textStorage else {
            return NSRange(location: 0, length: 0)
        }
        return (storage.string as NSString).paragraphRange(for: tv.selectedRange())
    }

    /// Every paragraph the selection touches, each with the newline that ends
    /// it, so that an empty line is a paragraph too. The empty last line of a
    /// note that ends in a newline, or of an empty note, has no characters at
    /// all: it comes back as an empty range at the end of the text.
    ///
    /// A selection that ends just after a newline stops there; it does not
    /// take in the paragraph that follows.
    private func paragraphRanges() -> [NSRange] {
        guard let tv = textView, let storage = tv.textStorage else { return [] }
        let text = storage.string as NSString
        let selection = tv.selectedRange()
        var ranges: [NSRange] = []
        var location = min(selection.location, text.length)
        while true {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
            guard range.length > 0, location < NSMaxRange(selection) else { return ranges }
        }
    }

    /// A paragraph without the newline that ends it.
    private func textRange(of paragraph: NSRange, in text: NSString) -> NSRange {
        var range = paragraph
        while range.length > 0,
              let scalar = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)),
              CharacterSet.newlines.contains(scalar) {
            range.length -= 1
        }
        return range
    }

    private func checkboxRange(in range: NSRange, of text: NSAttributedString) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.attachment, in: range, options: []) { value, subrange, stop in
            if value is CheckboxAttachment { found = subrange; stop.pointee = true }
        }
        return found
    }

    // MARK: - Editing primitives

    /// Settles text still being composed before an edit: an inline
    /// prediction is turned down, characters half-typed with an input method
    /// are kept. Every edit works out its ranges after this, from the text as
    /// it then is — clearing a prediction shortens the text, and a range
    /// worked out beforehand could run past its end.
    private func settleMarkedText() {
        guard let tv = textView, tv.hasMarkedText() else { return }
        NSSpellChecker.shared.dismissCorrectionIndicator(for: tv)
        if tv.hasMarkedText() { tv.unmarkText() }
    }

    /// A paragraph as a paragraph-level change sees it.
    private struct Paragraph {
        /// Its first character's attributes — or, on the empty last line,
        /// what will be typed there.
        let attributes: [NSAttributedString.Key: Any]
        let isChecklist: Bool

        var style: NSParagraphStyle { attributes[.paragraphStyle] as? NSParagraphStyle ?? .default }
        var isQuote: Bool { !isChecklist && style.textLists.isEmpty && style.firstLineHeadIndent > 0 }
    }

    /// Applies a paragraph-level change to every paragraph the selection
    /// touches, as one undo step. `change` returns the attributes to set: a
    /// paragraph style goes on the whole paragraph, newline and all, so an
    /// empty line takes it; anything else goes on its text only, since a
    /// heading's font on the newline made the line typed below it a heading.
    ///
    /// With only a caret, what is typed next changes too. It used to be left
    /// as it was — and the toolbar reads it, so after Bulleted list it still
    /// said "no list", and a second click put the list on again instead of
    /// taking it off.
    private func editParagraphs(_ change: (Paragraph) -> [NSAttributedString.Key: Any]) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        let selection = tv.selectedRange()
        let typing = tv.typingAttributes
        let paragraphs = paragraphRanges()
        guard let first = paragraphs.first, let last = paragraphs.last else { return }

        var edits: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        for range in paragraphs {
            let attributes = range.length > 0
                ? storage.attributes(at: range.location, effectiveRange: nil)
                : typing
            let isChecklist = range.length > 0 && checkboxRange(in: range, of: storage) != nil
            edits.append((range, change(Paragraph(attributes: attributes, isChecklist: isChecklist))))
        }

        // The empty last line has no character to hold a list, and a marker
        // is only drawn for a paragraph that has one: it gets its newline, as
        // AppKit gives it one when Return is pressed at the end of a list.
        let lastChange = edits[edits.count - 1].attributes
        let addsBreak = last.length == 0
            && (lastChange[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty == false
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)

        // Only the empty last line, and nothing to add: all there is to
        // change is what will be typed.
        guard whole.length > 0 || addsBreak else {
            tv.typingAttributes = typing.merging(lastChange) { $1 }
            refreshState()
            return
        }
        guard tv.shouldChangeText(in: whole,
                                  replacementString: addsBreak ? text.substring(with: whole) + "\n" : nil)
        else { return }

        storage.beginEditing()
        for (range, attributes) in edits where range.length > 0 {
            var attributes = attributes
            if let style = attributes.removeValue(forKey: .paragraphStyle) {
                storage.addAttribute(.paragraphStyle, value: style, range: range)
            }
            let body = textRange(of: range, in: text)
            if !attributes.isEmpty, body.length > 0 { storage.addAttributes(attributes, range: body) }
        }
        if addsBreak {
            var attributes = typing.merging(lastChange) { $1 }
            attributes[.attachment] = nil
            storage.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        storage.endEditing()
        tv.didChangeText()

        if selection.length == 0 {
            // The caret stays in front of a newline just added for it.
            if addsBreak { tv.setSelectedRange(selection) }
            tv.typingAttributes = typing.merging(edits[0].attributes) { $1 }
        }
        refreshState()
    }

    /// What typing at the caret would use, without a link or attachment it
    /// happens to sit next to.
    private func typingAttributes(of tv: NSTextView) -> [NSAttributedString.Key: Any] {
        var attributes = tv.typingAttributes
        for key in [NSAttributedString.Key.link, .attachment] { attributes[key] = nil }
        if attributes[.foregroundColor] as? NSColor == NSColor.linkColor {
            attributes[.foregroundColor] = NSColor.labelColor
            attributes[.underlineStyle] = nil
        }
        return attributes
    }

    /// Puts text in at the caret in the style being typed — a date inserted
    /// into a heading is heading-sized.
    private func insert(_ text: String) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let attributes = typingAttributes(of: tv)
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        tv.typingAttributes = attributes
        refreshState()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        settleMarkedText()
        let manager = NSFontManager.shared
        let isOn = currentFont().map { manager.traits(of: $0).contains(trait) } ?? false
        mutateFonts { font, manager in
            isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
    }

    private func mutateFonts(_ transform: (NSFont, NSFontManager) -> NSFont) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        let manager = NSFontManager.shared

        if tv.selectedRange().length == 0 {
            if let font = currentFont() {
                tv.typingAttributes[.font] = transform(font, manager)
            }
            refreshState()
            return
        }

        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? NoteDocument.bodyFont
            storage.addAttribute(.font, value: transform(font, manager), range: subrange)
        }
        storage.endEditing()
        tv.didChangeText()
        refreshState()
    }

    private func apply(_ key: NSAttributedString.Key, _ value: Any) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        if tv.selectedRange().length == 0 {
            tv.typingAttributes[key] = value
            refreshState()
            return
        }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(key, value: value, range: range)
        storage.endEditing()
        tv.didChangeText()
        refreshState()
    }

    private func remove(_ key: NSAttributedString.Key) {
        settleMarkedText()
        guard let tv = textView, let storage = tv.textStorage else { return }
        tv.typingAttributes[key] = nil
        let range = tv.selectedRange()
        guard range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) else {
            refreshState()
            return
        }
        storage.beginEditing()
        storage.removeAttribute(key, range: range)
        storage.endEditing()
        tv.didChangeText()
        refreshState()
    }

    private func toggleAttribute(_ key: NSAttributedString.Key, on value: Any,
                                 isOn: (Any?) -> Bool) {
        settleMarkedText()
        guard let tv = textView else { return }
        let range = tv.selectedRange()
        let current = range.length > 0
            ? tv.textStorage?.attribute(key, at: range.location, effectiveRange: nil)
            : tv.typingAttributes[key]
        isOn(current) ? remove(key) : apply(key, value)
    }

    private func currentFont() -> NSFont? {
        guard let tv = textView else { return nil }
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage, range.location < storage.length {
            return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        return tv.typingAttributes[.font] as? NSFont ?? NoteDocument.bodyFont
    }

    // MARK: - State

    fileprivate func attach(_ textView: NSTextView) {
        self.textView = textView
        refreshState()
    }

    func refreshState() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var next = RichTextState()
        let range = tv.selectedRange()

        let attributes: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attributes = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attributes = tv.typingAttributes
        }

        let font = (attributes[.font] as? NSFont) ?? NoteDocument.bodyFont
        let traits = NSFontManager.shared.traits(of: font)
        next.bold = traits.contains(.boldFontMask)
        next.italic = traits.contains(.italicFontMask)
        next.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
        next.strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
        let script = attributes[.superscript] as? Int ?? 0
        next.superscript = script > 0
        next.subscript = script < 0
        next.fontSize = font.pointSize
        next.headingLevel = NoteDocument.headingLevel(of: font)
        switch font.familyName {
        case NSFont.systemFont(ofSize: font.pointSize).familyName: next.fontFamily = ""
        case Self.roundedSystemFamily: next.fontFamily = Self.roundedFamily
        default: next.fontFamily = font.familyName ?? ""
        }
        next.color = (attributes[.foregroundColor] as? NSColor).flatMap(\.hexString) ?? ""
        next.highlight = (attributes[.backgroundColor] as? NSColor).flatMap(\.hexString) ?? ""

        // Read the paragraph off the storage rather than copying the whole
        // document into a Swift String, which this used to do three times per
        // keystroke and again on every arrow key.
        let paragraph = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
        // The paragraph's own style, from the text when it has any. The
        // typing attributes can trail behind it — AppKit ending a list on
        // Return updates them only once the caret next moves — and the
        // toolbar lit the list button for a line that was no longer one.
        let style = paragraph.length > 0
            ? storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            : attributes[.paragraphStyle] as? NSParagraphStyle
        if let style {
            next.alignment = style.alignment
            // The item's own list: in a numbered list nested in a bulleted
            // one, the item is numbered.
            switch style.textLists.last?.markerFormat {
            case .some(.decimal): next.isNumberedList = true
            case .some: next.isBulletList = true
            case nil: break
            }
            next.isQuote = style.textLists.isEmpty && style.firstLineHeadIndent > 0
        }
        next.isCode = font.familyName == NoteDocument.codeFont.familyName

        next.isChecklist = checkboxRange(in: paragraph, of: storage) != nil
        // A nested checklist item is indented too, but it is not a quote.
        if next.isChecklist { next.isQuote = false }

        next.canUndo = tv.undoManager?.canUndo ?? false
        next.canRedo = tv.undoManager?.canRedo ?? false

        if next != state { state = next }
    }
}

// MARK: - A text view that knows about checkboxes

final class NoteTextView: NSTextView {
    weak var controller: RichTextController?

    /// What a ticked checklist box is filled with: the theme's accent.
    var checkboxAccent: NSColor = .controlAccentColor {
        didSet {
            guard checkboxAccent.hexString != oldValue.hexString, let manager = textLayoutManager else { return }
            // The boxes are drawn from this; lay them out again so they redraw.
            manager.invalidateLayout(for: manager.documentRange)
            layOutEverything()
        }
    }

    /// Tab nests a list item and Shift-Tab brings it back out, as in the web
    /// editor. Outside a list Tab is still a tab.
    override func insertTab(_ sender: Any?) {
        if let controller, controller.state.inList {
            controller.shiftDepth(1)
            return
        }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if let controller, controller.state.inList {
            controller.shiftDepth(-1)
            return
        }
        super.insertBacktab(sender)
    }

    /// Return carries a checklist on, as AppKit carries a bulleted list on.
    /// After a heading it goes back to body text: AppKit carried the
    /// heading's font on, so every line typed below a heading was one too.
    override func insertNewline(_ sender: Any?) {
        guard let controller else { return super.insertNewline(sender) }
        if controller.insertNewlineInChecklist() { return }
        let endsHeading = controller.caretEndsHeading
        super.insertNewline(sender)
        if endsHeading {
            typingAttributes[.font] = NoteDocument.bodyFont
            controller.refreshState()
        }
    }

    /// Backspace at the start of a list item takes its marker away first.
    override func deleteBackward(_ sender: Any?) {
        if controller?.deleteMarkerBeforeCaret() == true { return }
        super.deleteBackward(sender)
    }

    /// ⌘B, ⌘I and ⌘U, as the toolbar's tooltips say. Most Mac apps get them
    /// from a Format menu; this one has none, so they did nothing.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let controller, window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": controller.toggleBold()
        case "i": controller.toggleItalic()
        case "u": controller.toggleUnderline()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// TextKit 2 lays out only what it thinks is on screen; clicks on lines
    /// outside that went nowhere. A note is short, so all of it is laid out.
    func layOutEverything() {
        guard let manager = textLayoutManager else { return }
        manager.ensureLayout(for: manager.documentRange)
    }

    override func didChangeText() {
        super.didChangeText()
        layOutEverything()
    }

    /// Scrolls only when the rect is really off screen. In the editor's
    /// SwiftUI scroll view, AppKit counted part of the visible area as
    /// covered, so a click near the top of the note jumped the page.
    override func scrollToVisible(_ rect: NSRect) -> Bool {
        if let clip = enclosingScrollView?.contentView,
           clip.bounds.contains(convert(rect, to: clip)) {
            return false
        }
        return super.scrollToVisible(rect)
    }

    /// A click on a checklist box ticks it.
    ///
    /// Found without `layoutManager`: asking for it moves the view onto the
    /// older TextKit 1 for good, which doesn't draw list bullets — one click
    /// in a note and every bullet vanished. These calls stay on TextKit 2.
    override func mouseDown(with event: NSEvent) {
        guard let storage = textStorage, let window else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndexForInsertion(at: point)

        // The box is the character just before or after the insertion point
        // nearest the click; it counts only when the click is on the box itself.
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard storage.attribute(.attachment, at: candidate, effectiveRange: nil) is CheckboxAttachment else { continue }
            let box = firstRect(forCharacterRange: NSRange(location: candidate, length: 1), actualRange: nil)
            if box.insetBy(dx: -3, dy: -3).contains(screenPoint) {
                controller?.toggleCheckbox(at: candidate)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - The SwiftUI wrapper

/// Where the text sits across the pane: a readable column, as the header's.
struct TextColumn: Equatable {
    var maxWidth: CGFloat = 760
    var padding: CGFloat = 36
    var centered = false
}

/// The note's scroll view. Its content is the header — title, properties,
/// any AI card, drawn by SwiftUI — with the text view below it, so both move
/// in one AppKit scroll: the header can't trail the text by a frame and
/// stutter, and the wheel works over either.
struct RichTextEditor<Header: View>: NSViewRepresentable {
    @Binding var attributed: NSAttributedString
    let controller: RichTextController
    var onTextChange: (NSAttributedString) -> Void
    var column = TextColumn()
    let header: Header

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let textView = Self.makeTextView(controller: controller, coordinator: context.coordinator,
                                         text: attributed)

        let document = NoteDocumentView(textView: textView)
        document.column = column
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        // The scroll bar stops above the round assistant button in the
        // corner. (The last lines get room below them from the document
        // itself: a content inset there swallowed clicks on the text behind it.)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        document.watch(scroll)
        return scroll
    }

    /// The writing surface as the editor sets it up; separate so tests can
    /// drive the real configuration.
    static func makeTextView(controller: RichTextController, coordinator: Coordinator,
                             text: NSAttributedString) -> NoteTextView {
        let textView = NoteTextView()
        textView.controller = controller
        textView.delegate = coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        // Line up with the title above it; AppKit's default pads each line by 5pt.
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = NoteDocument.bodyFont
        textView.typingAttributes = NoteDocument.baseAttributes
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        coordinator.adopt(text, into: textView)
        coordinator.watchUndo(of: textView)
        controller.attach(textView)
        return textView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NoteDocumentView else { return }
        let textView = document.textView
        context.coordinator.adopt(attributed, into: textView)
        // `textColor` is deliberately not assigned: its setter recolours the
        // whole document, which wiped every custom colour on every update.
        textView.insertionPointColor = NSColor(context.environment.palette.text)
        textView.checkboxAccent = NSColor(context.environment.palette.accent)

        // The header is its own SwiftUI hierarchy: it gets the environment
        // values it draws with from here.
        document.header.rootView = AnyView(header
            .environment(\.palette, context.environment.palette)
            .environment(\.colorScheme, context.environment.colorScheme))
        if document.column != column { document.column = column }
        textView.layOutEverything()
        document.needsLayout = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: RichTextEditor
        /// The texts this editor has handed to SwiftUI, or taken from it.
        /// Whatever SwiftUI passes back that is one of these is already in
        /// the text view, however late it arrives.
        private let known = NSHashTable<NSAttributedString>(options: [.weakMemory, .objectPointerPersonality])
        /// Set when an undo or redo has changed the text and not yet been told.
        private var undoneUnsaved = false
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(_ parent: RichTextEditor) { self.parent = parent }

        deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        /// Under TextKit 2 an undo or redo changes the text without posting
        /// didChange, so it would show but never be saved. The storage still
        /// reports the edit; once the undo manager has finished, it goes out
        /// like any other change.
        func watchUndo(of textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let self, let undo = textView?.undoManager, undo.isUndoing || undo.isRedoing,
                          let mask = textView?.textStorage?.editedMask,
                          !mask.intersection([.editedCharacters, .editedAttributes]).isEmpty else { return }
                    self.undoneUnsaved = true
                }
            })
            // The window's undo manager is only known once the view is in one,
            // and is shared with its other fields: filter rather than bind.
            for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [weak self, weak textView] note in
                    let sender = (note.object as AnyObject?).map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        guard let self, let textView, self.undoneUnsaved,
                              sender != nil, sender == textView.undoManager.map(ObjectIdentifier.init) else { return }
                        self.publish(textView)
                    }
                })
            }
        }

        /// Puts text from outside the editor — the note, as it is opened —
        /// into the text view, and nothing else.
        ///
        /// This used to compare contents, and overwrite the text view with
        /// the binding whenever they differed. An inline prediction is text
        /// in the view the binding never hears of, so the next SwiftUI update
        /// replaced it; AppKit, clearing the prediction afterwards at a range
        /// that was gone, threw — up through SwiftUI's update, which left the
        /// window frozen until the app was quit, and crashed it then.
        func adopt(_ text: NSAttributedString, into textView: NSTextView) {
            guard !known.contains(text) else { return }
            known.add(text)
            guard let storage = textView.textStorage, !storage.isEqual(to: text) else { return }
            // Text still being composed goes first, while its range is still
            // the text's.
            if textView.hasMarkedText() { textView.unmarkText() }
            let selected = textView.selectedRange()
            storage.setAttributedString(text)
            // NSRange counts UTF-16 units; String.count counts characters, and
            // the two differ as soon as a note contains an emoji.
            textView.setSelectedRange(NSRange(location: min(selected.location, storage.length), length: 0))
        }

        /// Whether SwiftUI passing `text` back would leave the text view alone.
        func knows(_ text: NSAttributedString) -> Bool { known.contains(text) }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publish(textView)
        }

        /// Hands the text to SwiftUI and the save, marked as the editor's own.
        private func publish(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            undoneUnsaved = false
            let copy = NSAttributedString(attributedString: storage)
            known.add(copy)
            parent.attributed = copy
            parent.onTextChange(copy)
            parent.controller.refreshState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.refreshState()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL { NSWorkspace.shared.open(url); return true }
            return false
        }
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    var isEffectivelyBlack: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return c.redComponent < 0.08 && c.greenComponent < 0.08 && c.blueComponent < 0.08
    }
}

// MARK: - The scrolling content

/// The scroll view's content: the header across the top, the text view
/// below it in the reading column, together as tall as they need.
final class NoteDocumentView: NSView {
    /// The header's SwiftUI content. A controller, because it can say how
    /// tall its content is at a given width; it is re-measured on every
    /// SwiftUI update of the editor, which is when that content changes.
    let header = NSHostingController(rootView: AnyView(EmptyView()))
    let textView: NoteTextView
    var column = TextColumn() { didSet { needsLayout = true } }
    /// Room after the last line, so it can scroll clear of the assistant button.
    let bottomRoom: CGFloat = 88
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override var isFlipped: Bool { true }

    init(textView: NoteTextView) {
        self.textView = textView
        super.init(frame: .zero)
        header.sizingOptions = []
        addSubview(header.view)
        addSubview(textView)
        textView.postsFrameChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Lays out again when the pane resizes or the text grows.
    func watch(_ scroll: NSScrollView) {
        scroll.contentView.postsFrameChangedNotifications = true
        for object in [scroll.contentView as NSView, textView] {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: object, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        guard let clip = enclosingScrollView?.contentView else { return }
        let width = clip.bounds.width
        let headerHeight = ceil(header.sizeThatFits(in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height)
        header.view.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)

        // The text sits in the same column as the title above it.
        let textWidth = max(120, min(column.maxWidth, width - column.padding * 2))
        let x = column.centered ? floor((width - textWidth) / 2) : column.padding
        // At least the rest of the pane, so clicks below a short note land in it.
        textView.minSize = NSSize(width: textWidth, height: max(80, clip.bounds.height - headerHeight - bottomRoom))
        if abs(textView.frame.width - textWidth) > 0.5 || abs(textView.frame.minX - x) > 0.5
            || abs(textView.frame.minY - headerHeight) > 0.5 {
            textView.frame = NSRect(x: x, y: headerHeight, width: textWidth,
                                    height: max(textView.frame.height, textView.minSize.height))
        }
        textView.sizeToFit()

        let height = headerHeight + textView.frame.height + bottomRoom
        if abs(frame.width - width) > 0.5 || abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: width, height: height))
        }
    }
}
