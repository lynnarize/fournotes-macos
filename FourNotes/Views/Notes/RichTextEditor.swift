import AppKit
import SwiftUI

// The note editor's writing surface: an NSTextView with real NSTextLists and
// clickable checkboxes. What it stores is in NoteDocument.swift.
//
// Two rules hold this together, and both were broken before:
//
//   - Every mutation goes through shouldChangeText/didChangeText, so undo
//     stays in step with the document.
//   - SwiftUI only pushes text in when it is genuinely newer, tracked with a
//     revision counter rather than a flag cleared on an unordered async hop —
//     which used to overwrite the character the user had just typed.

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
    /// Bumped on every local edit. SwiftUI compares against it before pushing
    /// text in, so a pending update can never clobber newer typing.
    fileprivate(set) var revision = 0

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

    func setColor(_ hex: String) {
        hex.isEmpty ? remove(.foregroundColor) : apply(.foregroundColor, NSColor(hex: hex) ?? .labelColor)
    }

    func setHighlight(_ hex: String) {
        hex.isEmpty ? remove(.backgroundColor) : apply(.backgroundColor, NSColor(hex: hex) ?? .clear)
    }

    func setFontFamily(_ family: String) {
        mutateFonts { font, manager in
            let name = family.isEmpty
                ? NSFont.systemFont(ofSize: font.pointSize).familyName
                : family
            return manager.convert(font, toFamily: name ?? font.familyName ?? "Helvetica")
        }
    }

    func setFontSize(_ size: CGFloat) {
        mutateFonts { font, manager in manager.convert(font, toSize: size) }
    }

    // MARK: - Paragraphs

    func setHeading(_ level: Int?) {
        editParagraphs { storage, range, _ in
            storage.addAttribute(.font, value: NoteDocument.headingFont(level ?? 0), range: range)
        }
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        editParagraphs { storage, range, style in
            let updated = (style.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            updated.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: updated, range: range)
        }
    }

    func toggleQuote() {
        let on = state.isQuote
        editParagraphs { storage, range, _ in
            let style = on
                ? NSParagraphStyle.default
                : NoteDocument.quoteParagraphStyle()
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.addAttribute(.foregroundColor,
                                 value: on ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                 range: range)
        }
    }

    func toggleBulletList() { toggleList(.disc, isOn: state.isBulletList) }
    func toggleNumberedList() { toggleList(.decimal, isOn: state.isNumberedList) }

    private func toggleList(_ format: NSTextList.MarkerFormat, isOn: Bool) {
        // A checklist and a bullet list are different things; leaving one enters
        // the other.
        if state.isChecklist { toggleChecklist() }
        // Continue the list just above rather than starting a new one, so a
        // numbered item added under "1." becomes "2.".
        let list = isOn ? nil : (neighbourList(format) ?? NSTextList(markerFormat: format, options: 0))
        editParagraphs { storage, range, _ in
            storage.addAttribute(.paragraphStyle,
                                 value: list.map { NoteDocument.listParagraphStyle($0) } ?? NSParagraphStyle.default,
                                 range: range)
        }
    }

    /// The top-level list of this kind in the paragraph above the selection.
    private func neighbourList(_ format: NSTextList.MarkerFormat) -> NSTextList? {
        guard let first = paragraphRanges().first, first.location > 0,
              let storage = textView?.textStorage else { return nil }
        let style = storage.attribute(.paragraphStyle, at: first.location - 1,
                                      effectiveRange: nil) as? NSParagraphStyle
        guard let list = style?.textLists.first, list.markerFormat == format else { return nil }
        return list
    }

    /// Nests list items one level deeper — or, with `-1`, brings them back out.
    /// Checklist items move by indent, since their checkbox is not a marker.
    func shiftDepth(_ delta: Int) {
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

        editParagraphs { storage, range, style in
            if checkboxRange(in: range, of: storage) != nil {
                let depth = NoteDocument.checklistDepth(style) + delta
                guard (0...NoteDocument.maxDepth).contains(depth) else { return }
                storage.addAttribute(.paragraphStyle,
                                     value: NoteDocument.checklistParagraphStyle(depth: depth), range: range)
                return
            }
            var lists = style.textLists
            guard let parent = lists.last else { return }
            if delta > 0 {
                guard lists.count <= NoteDocument.maxDepth else { return }
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
                guard lists.count > 1 else { return }
                lists.removeLast()
            }
            storage.addAttribute(.paragraphStyle, value: NoteDocument.listParagraphStyle(lists), range: range)
        }
    }

    /// A code block: the paragraph in a monospaced face. Plain text keeps the
    /// lines; the native archive keeps the face.
    func toggleCode() {
        let on = state.isCode
        editParagraphs { storage, range, _ in
            storage.addAttribute(.font,
                                 value: on ? NoteDocument.bodyFont : NoteDocument.codeFont,
                                 range: range)
        }
    }

    /// Checkboxes are attachments rather than list markers, because a marker
    /// cannot be clicked.
    func toggleChecklist() {
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
        refreshState()
    }

    func toggleCheckbox(at index: Int) {
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

    func insertLink(_ url: String, title: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let label = range.length > 0
            ? (storage.string as NSString).substring(with: range)
            : (title.isEmpty ? url : title)
        let link = NSMutableAttributedString(string: label, attributes: NoteDocument.baseAttributes)
        link.addAttributes([
            .link: URL(string: url) as Any,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: NSRange(location: 0, length: link.length))
        guard tv.shouldChangeText(in: range, replacementString: link.string) else { return }
        storage.replaceCharacters(in: range, with: link)
        tv.didChangeText()
    }

    func clearFormatting() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = effectiveRange()
        guard range.length > 0, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.setAttributes(NoteDocument.baseAttributes, range: range)
        storage.endEditing()
        tv.didChangeText()
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

    /// Every paragraph the selection touches, without the trailing newline —
    /// including it added a phantom extra item to every multi-line list.
    private func paragraphRanges() -> [NSRange] {
        guard let tv = textView, let storage = tv.textStorage else { return [] }
        let text = storage.string as NSString
        guard text.length > 0 else { return [NSRange(location: 0, length: 0)] }

        let selection = tv.selectedRange()
        let bounds = text.paragraphRange(for: selection)
        var ranges: [NSRange] = []
        var location = bounds.location
        while location < NSMaxRange(bounds) {
            var range = text.paragraphRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            // Drop the newline; it belongs to the break, not the paragraph.
            if range.length > 0,
               text.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" {
                range.length -= 1
            }
            ranges.append(range)
            if next <= location { break }
            location = next
        }
        return ranges
    }

    private func checkboxRange(in range: NSRange, of text: NSAttributedString) -> NSRange? {
        var found: NSRange?
        text.enumerateAttribute(.attachment, in: range, options: []) { value, subrange, stop in
            if value is CheckboxAttachment { found = subrange; stop.pointee = true }
        }
        return found
    }

    // MARK: - Editing primitives

    /// Applies a paragraph-level change to everything the selection touches,
    /// registering it for undo.
    private func editParagraphs(_ body: (NSTextStorage, NSRange, NSParagraphStyle) -> Void) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let paragraphs = paragraphRanges()
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        let whole = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        guard tv.shouldChangeText(in: whole, replacementString: nil) else { return }

        storage.beginEditing()
        for range in paragraphs where range.length > 0 || storage.length == 0 {
            let style = (storage.length > range.location
                ? storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil) ?? .default
            body(storage, range, style)
        }
        storage.endEditing()
        tv.didChangeText()
        refreshState()
    }

    private func insert(_ text: String) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range,
                                  with: NSAttributedString(string: text,
                                                           attributes: NoteDocument.baseAttributes))
        tv.didChangeText()
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let isOn = currentFont().map { manager.traits(of: $0).contains(trait) } ?? false
        mutateFonts { font, manager in
            isOn ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
        }
    }

    private func mutateFonts(_ transform: (NSFont, NSFontManager) -> NSFont) {
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
        let systemFamily = NSFont.systemFont(ofSize: font.pointSize).familyName
        next.fontFamily = font.familyName == systemFamily ? "" : (font.familyName ?? "")
        next.color = (attributes[.foregroundColor] as? NSColor).flatMap(\.hexString) ?? ""
        next.highlight = (attributes[.backgroundColor] as? NSColor).flatMap(\.hexString) ?? ""

        if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
            next.alignment = style.alignment
            switch style.textLists.first?.markerFormat {
            case .some(.decimal): next.isNumberedList = true
            case .some: next.isBulletList = true
            case nil: break
            }
            next.isQuote = style.textLists.isEmpty && style.firstLineHeadIndent > 0
        }
        next.isCode = font.familyName == NoteDocument.codeFont.familyName

        // Read the paragraph off the storage rather than copying the whole
        // document into a Swift String, which this used to do three times per
        // keystroke and again on every arrow key.
        let paragraph = (storage.string as NSString).paragraphRange(for: tv.selectedRange())
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
        textView.textStorage?.setAttributedString(text)
        coordinator.watchUndo(of: textView)
        controller.attach(textView)
        return textView
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NoteDocumentView else { return }
        let textView = document.textView
        // Only adopt text that did not come from this editor. The revision
        // counter is set when the local edit happens, so a SwiftUI update that
        // arrives late cannot overwrite newer typing.
        if context.coordinator.appliedRevision != controller.revision {
            context.coordinator.appliedRevision = controller.revision
        } else if textView.attributedString() != attributed {
            let selected = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributed)
            // NSRange counts UTF-16 units; String.count counts characters, and
            // the two differ as soon as a note contains an emoji.
            let limit = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
        }
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
        var appliedRevision = 0
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            publish(textView)
        }

        /// Hands the text to SwiftUI and the save, marked as the editor's own.
        private func publish(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            undoneUnsaved = false
            let copy = NSAttributedString(attributedString: storage)
            parent.controller.revision += 1
            appliedRevision = parent.controller.revision
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
