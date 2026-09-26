import AppKit

// Converts a note between the two forms it actually needs:
//
//   attributed  what NSTextView edits — real NSTextLists, real checkboxes
//   plain text  what search, the assistant, the daily brief and the web app read
//
// HTML is no longer in the middle of this. Round-tripping AppKit's HTML
// converters lost lists, checklists and dividers in both directions, and ran on
// the main thread on every keystroke. HTML is now produced only on export, from
// the plain text, by the converter both apps already share (NoteText).

/// A checkbox in a note. Carries its own state; ticking one puts a new box in
/// its place, so undo, and every copy of the text made before, keep the old.
///
/// The image is drawn on demand rather than stored on the attachment: setting
/// `image` puts the whole bitmap into the note's archive, which took a
/// three-line checklist from 39 bytes of text to 46KB on disk.
final class CheckboxAttachment: NSTextAttachment {
    override class var supportsSecureCoding: Bool { true }

    private(set) var isChecked: Bool

    init(checked: Bool) {
        self.isChecked = checked
        super.init(data: nil, ofType: nil)
    }

    /// NSTextAttachment's designated initializer. Unarchiving goes through it,
    /// so it has to exist even though nothing in the app calls it directly.
    override init(data contentData: Data?, ofType uti: String?) {
        isChecked = false
        super.init(data: contentData, ofType: uti)
    }

    required init?(coder: NSCoder) {
        let checked = coder.decodeBool(forKey: "isChecked")
        isChecked = checked
        super.init(coder: coder)
        // Set again: NSTextAttachment's own decoding goes through
        // `init(data:ofType:)`, whose override above unticks the box. Every
        // ticked box in a note saved with formatting came back unticked.
        isChecked = checked
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(isChecked, forKey: "isChecked")
    }

    /// Where the box sits: a 15pt square, dropped 3pt below the baseline so it
    /// centres on the text beside it.
    static let bounds = CGRect(x: 0, y: -3, width: 15, height: 15)

    /// No cell. On macOS an attachment makes itself a default one, and while
    /// it has one TextKit 2 draws the cell — which draws `image`, nil here —
    /// and never asks for the image below. Both TextKit versions draw a
    /// cell-less attachment from these methods.
    override var attachmentCell: (any NSTextAttachmentCellProtocol)? {
        get { nil }
        set {}
    }

    // TextKit 2, which the editor uses. It never asks the TextKit 1 methods
    // below, so without these the box had no size and drew nothing.

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any],
                        location: any NSTextLocation, textContainer: NSTextContainer?) -> NSImage? {
        image(in: textContainer)
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        Self.bounds
    }

    // TextKit 1, should the view ever fall back to it.

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?,
                        characterIndex charIndex: Int) -> NSImage? {
        image(in: textContainer)
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        Self.bounds
    }

    private func image(in textContainer: NSTextContainer?) -> NSImage {
        // The theme's accent, as the web editor's `accent-color: var(--accent)`.
        // Text layout calls this on the main thread; anywhere else, the system's.
        let view = textContainer?.textView
        let accent = Thread.isMainThread
            ? MainActor.assumeIsolated { (view as? NoteTextView)?.checkboxAccent }
            : nil
        return Self.image(checked: isChecked, accent: accent ?? .controlAccentColor)
    }

    /// The SF Symbols are templates, which draw black unless tinted — invisible
    /// on the dark theme. The tint is resolved in the drawing handler, which
    /// runs when the text is drawn and under the view's own appearance, so
    /// `labelColor` is right in every theme. Never cached, so a theme change
    /// can't leave a box drawn for the previous one.
    private static func image(checked: Bool, accent: NSColor) -> NSImage {
        let name = checked ? "checkmark.square.fill" : "square"
        let label = checked ? "Done" : "To do"
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            let colors: [NSColor] = checked ? [.white, accent] : [.labelColor]
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: colors)) else { return false }
            symbol.draw(in: rect)
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = label
        return image
    }
}

enum NoteDocument {
    static let bodySize: CGFloat = 16

    /// Open Sans, the web editor's face, so a note reads the same in both
    /// apps. Bundled in Resources/Fonts (SIL Open Font License, OFL.txt there)
    /// and loaded through ATSApplicationFontsPath in Info.plist.
    static let bodyFamily = "Open Sans"

    /// The notes' face at a size and weight, or the system font should the
    /// bundled one ever be missing.
    static func sans(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: bodyFamily,
            // Width 0: the variable font also has condensed instances.
            .traits: [NSFontDescriptor.TraitKey.weight: weight, NSFontDescriptor.TraitKey.width: 0],
        ])
        if let font = NSFont(descriptor: descriptor, size: size), font.familyName == bodyFamily { return font }
        return .systemFont(ofSize: size, weight: weight)
    }

    static var bodyFont: NSFont { sans(bodySize) }

    /// Notes saved before Open Sans was the face used the system font for
    /// ordinary text. That was the default, never a choice, so it becomes the
    /// new default; bold, italic and size stay as they were.
    static func usingBodyFont(_ document: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: document)
        let manager = NSFontManager.shared
        let full = NSRange(location: 0, length: out.length)
        out.beginEditing()
        out.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let font = value as? NSFont,
                  font.familyName == NSFont.systemFont(ofSize: font.pointSize).familyName else { return }
            let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight]
                as? CGFloat ?? 0
            var replacement = sans(font.pointSize, weight: NSFont.Weight(weight))
            if manager.traits(of: font).contains(.italicFontMask) {
                replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
            }
            out.addAttribute(.font, value: replacement, range: range)
        }
        out.endEditing()
        return out
    }

    static var codeFont: NSFont { .monospacedSystemFont(ofSize: 14, weight: .regular) }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraphStyle]
    }

    // MARK: - Spacing

    // The web editor's rhythm (.fn-editor in globals.css): lines 1.75× the
    // text size, 0.55em between paragraphs, 0.2em between list items. AppKit's
    // defaults — about 1.2× and nothing between paragraphs — made the same note
    // look cramped next to the web app.

    /// Line height as a multiple of the body font's own, so a line is 1.75× the text size.
    static let lineHeightMultiple: CGFloat = {
        let natural = bodyFont.ascender - bodyFont.descender + bodyFont.leading
        return natural > 0 ? (bodySize * 1.75 / natural * 100).rounded() / 100 : 1.5
    }()
    static let paragraphGap: CGFloat = (bodySize * 0.55).rounded()
    static let itemGap: CGFloat = (bodySize * 0.2).rounded()

    /// An ordinary paragraph: what a plain line, a heading and a reset use.
    static var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphGap
        return style
    }

    /// The web's spacing, on a note saved before it was used here or read from
    /// elsewhere. Every paragraph keeps its own style otherwise.
    static func spaced(_ document: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: document)
        let text = out.string as NSString
        var paragraphs: [(range: NSRange, isItem: Bool)] = []
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard range.length > 0 else { break }
            location = NSMaxRange(range)
            let style = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let isItem = style?.textLists.isEmpty == false || text.character(at: range.location) == 0xFFFC
            paragraphs.append((range, isItem))
        }
        out.beginEditing()
        for (index, paragraph) in paragraphs.enumerated() {
            let current = out.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil)
                as? NSParagraphStyle ?? .default
            let style = (current.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            // Items sit close together; the last one before other text gets a paragraph's gap.
            let nextIsItem = index + 1 < paragraphs.count && paragraphs[index + 1].isItem
            style.lineHeightMultiple = lineHeightMultiple
            style.paragraphSpacing = paragraph.isItem && nextIsItem ? itemGap : paragraphGap
            if text.substring(with: paragraph.range).trimmingCharacters(in: .newlines) == dividerGlyphs {
                out.addAttribute(.kern, value: dividerKern,
                                 range: NSRange(location: paragraph.range.location, length: (dividerGlyphs as NSString).length))
            }
            guard style != current else { continue }
            out.addAttribute(.paragraphStyle, value: style.copy(), range: paragraph.range)
        }
        out.endEditing()
        return out
    }

    /// Heading levels, as the toolbar offers them.
    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return sans(28, weight: .bold)
        case 2: return sans(22, weight: .bold)
        case 3: return sans(18, weight: .semibold)
        default: return bodyFont
        }
    }

    static func headingLevel(of font: NSFont) -> Int? {
        switch font.pointSize {
        case 26...: return 1
        case 20..<26: return 2
        case 17.5..<20: return 3
        default: return nil
        }
    }

    // MARK: - Lists

    static func bulletList() -> NSTextList { NSTextList(markerFormat: .disc, options: 0) }
    static func numberedList() -> NSTextList { NSTextList(markerFormat: .decimal, options: 0) }

    /// How far each nesting level moves a list in.
    static let indentStep: CGFloat = 24
    /// Deeper than this and a note stops being readable.
    static let maxDepth = 5

    /// The paragraph style a list item uses, with the indents AppKit expects.
    ///
    /// `lists` is the chain from the outermost list to this item's own. Items
    /// only count as one list — "1. 2. 3." rather than "1. 1. 1." — when they
    /// share the same NSTextList objects, so callers pass the same instances
    /// for consecutive siblings.
    static func listParagraphStyle(_ lists: [NSTextList]) -> NSParagraphStyle {
        let depth = CGFloat(max(0, lists.count - 1))
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        style.headIndent = indentStep * (depth + 1)
        style.firstLineHeadIndent = 4 + indentStep * depth
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = itemGap
        return style
    }

    static func listParagraphStyle(_ list: NSTextList) -> NSParagraphStyle {
        listParagraphStyle([list])
    }

    /// The paragraph style a checklist item uses. Checkboxes are attachments
    /// rather than list markers, because a marker cannot be clicked.
    static func checklistParagraphStyle(depth: Int = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indentStep * CGFloat(depth)
        style.headIndent = 20 + indentStep * CGFloat(depth)
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = itemGap
        return style
    }

    /// How deeply a checklist item is nested, read back from its indent.
    static func checklistDepth(_ style: NSParagraphStyle?) -> Int {
        guard let style else { return 0 }
        return min(maxDepth, max(0, Int((style.firstLineHeadIndent / indentStep).rounded())))
    }

    /// A divider. Stored as `---`, which is what the web app writes and reads.
    static let dividerGlyphs = "———"
    /// Open Sans leaves a gap between em dashes; pulled together they read as one rule.
    static let dividerKern: CGFloat = -2

    static func divider() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphGap
        return NSAttributedString(string: dividerGlyphs, attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
            .kern: dividerKern,
        ])
    }

    static func quoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphGap
        return style
    }

    // MARK: - Plain text -> attributed

    /// Builds an editable document from the plain-text form the assistant, the
    /// web app and older notes all use.
    static func attributed(fromPlainText text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // The list open at each nesting level, so consecutive items share it.
        var open: [NSTextList] = []

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            if index > 0 { out.append(lineBreak(after: out)) }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Two spaces per level, as the web app writes nested lists.
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
            let leading = indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let depth = min(maxDepth, leading / 2)

            if let match = line.firstMatch(of: /^(☐|☑)\s*(.*)$/) {
                open = []
                out.append(checklistItem(String(match.2), checked: String(match.1) == "☑", depth: depth))
            } else if let match = line.firstMatch(of: /^[•\-\*]\s+(.*)$/) {
                let lists = chain(.disc, depth: depth, open: &open)
                out.append(listItem(String(match.1), lists: lists))
            } else if let match = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                let lists = chain(.decimal, depth: depth, open: &open)
                out.append(listItem(String(match.1), lists: lists))
            } else if let (marker, body) = lineMarker(line) {
                open = []
                switch marker {
                case .heading(let level):
                    out.append(NSAttributedString(string: String(body), attributes: [
                        .font: headingFont(level),
                        .foregroundColor: NSColor.labelColor,
                    ]))
                case .quote:
                    out.append(NSAttributedString(string: String(body), attributes: [
                        .font: bodyFont,
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: quoteParagraphStyle(),
                    ]))
                }
            } else if line.firstMatch(of: /^(-{3,}|_{3,}|\*{3,}|—{3,})$/) != nil {
                open = []
                out.append(divider())
            } else {
                open = []
                out.append(NSAttributedString(string: rawLine, attributes: baseAttributes))
            }
        }
        return out
    }

    enum LineMarker: Equatable {
        case heading(Int)
        case quote
    }

    /// A heading's `#`s or a quote's `>` at the front of a line: what they make
    /// the line, and the text after them. The text is a slice of `line`, so
    /// `line[..<text.startIndex]` is exactly the marker as written — the edge
    /// stickies hide it and put it back character for character.
    static func lineMarker(_ line: String) -> (LineMarker, text: Substring)? {
        if let match = line.firstMatch(of: /^\s*(#{1,3})\s+/) {
            return (.heading(match.1.count), line[match.range.upperBound...])
        }
        if let match = line.firstMatch(of: /^\s*>\s?/) {
            return (.quote, line[match.range.upperBound...])
        }
        return nil
    }

    /// The newline ending the last line, carrying that line's paragraph style.
    ///
    /// A paragraph's style has to cover its newline too. Without it a list is
    /// broken into one-item pieces — AppKit numbered every item "1." — and
    /// pressing Return at the end of an item left the list.
    private static func lineBreak(after document: NSAttributedString) -> NSAttributedString {
        // Only its last characters are read. Its `string` is a copy of all of
        // it, and this runs once a line: a 3,000-line note took over half a
        // second to open, more the longer it got.
        func ends(with suffix: String) -> Bool {
            let length = (suffix as NSString).length
            guard document.length >= length else { return false }
            return document.attributedSubstring(from: NSRange(location: document.length - length, length: length))
                .string == suffix
        }
        guard document.length > 0, !ends(with: "\n"), !ends(with: dividerGlyphs) else {
            // An empty line, or a divider, whose centring must not carry on
            // into what is typed below it: a plain newline.
            return NSAttributedString(string: "\n", attributes: baseAttributes)
        }
        // Only the paragraph style: a heading's font on the newline would make
        // anything typed on the empty line below it heading-sized.
        var attributes = baseAttributes
        attributes[.paragraphStyle] = document.attribute(.paragraphStyle, at: document.length - 1,
                                                         effectiveRange: nil)
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    /// The lists an item at `depth` belongs to, reusing the ones already open
    /// so that siblings number as one list.
    private static func chain(_ format: NSTextList.MarkerFormat, depth: Int,
                              open: inout [NSTextList]) -> [NSTextList] {
        if open.count > depth + 1 { open.removeSubrange((depth + 1)...) }
        if open.count == depth + 1, open[depth].markerFormat != format { open.removeLast() }
        while open.count <= depth { open.append(NSTextList(markerFormat: format, options: 0)) }
        return open
    }

    static func listItem(_ text: String, lists: [NSTextList]) -> NSAttributedString {
        var attributes = baseAttributes
        attributes[.paragraphStyle] = listParagraphStyle(lists)
        return NSAttributedString(string: text, attributes: attributes)
    }

    static func checklistItem(_ text: String, checked: Bool, depth: Int = 0) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString:
            NSAttributedString(attachment: CheckboxAttachment(checked: checked)))
        out.append(NSAttributedString(string: " " + text))
        var attributes = baseAttributes
        attributes[.paragraphStyle] = checklistParagraphStyle(depth: depth)
        out.addAttributes(attributes, range: NSRange(location: 0, length: out.length))
        return out
    }

    // MARK: - Attributed -> plain text

    /// The plain-text form: what search, the assistant and the brief read, and
    /// what the web app stores in `content`.
    static func plainText(from attributed: NSAttributedString) -> String {
        let text = attributed.string as NSString
        var lines: [String] = []

        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            lines.append(line(in: attributed, paragraph: paragraph))
            location = NSMaxRange(paragraph)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func line(in document: NSAttributedString, paragraph range: NSRange) -> String {
        let paragraph = document.attributedSubstring(from: range)
        var text = paragraph.string.trimmingCharacters(in: .newlines)
        let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        // A checkbox attachment sits at the head of a checklist item.
        if let checkbox = firstCheckbox(in: paragraph) {
            // Strip the attachment character and the space after it.
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: "  ", count: checklistDepth(style))
            return pad + (checkbox.isChecked ? "☑ " : "☐ ") + text
        }

        guard !text.isEmpty else { return "" }

        if let style, let list = style.textLists.last {
            // A marker left in the text by AppKit's HTML reader is not part of the item.
            if let match = text.firstMatch(of: /^\t[^\t]{0,8}\t/) { text.removeSubrange(match.range) }
            let pad = String(repeating: "  ", count: min(maxDepth, style.textLists.count - 1))
            if list.markerFormat == .decimal {
                // What the reader sees: AppKit's own count of this list's items.
                let number = max(1, document.itemNumber(in: list, at: range.location))
                return "\(pad)\(number). \(text)"
            }
            return "\(pad)• \(text)"
        }

        if text == dividerGlyphs { return "---" }
        if let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
           let level = headingLevel(of: font) {
            return String(repeating: "#", count: level) + " " + text
        }
        if let style, style.firstLineHeadIndent > 0, style.textLists.isEmpty {
            return "> " + text
        }
        return text
    }

    static func firstCheckbox(in paragraph: NSAttributedString) -> CheckboxAttachment? {
        var found: CheckboxAttachment?
        paragraph.enumerateAttribute(.attachment, in: NSRange(location: 0, length: paragraph.length),
                                     options: []) { value, _, stop in
            if let checkbox = value as? CheckboxAttachment {
                found = checkbox
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Pasted text

    /// Rich text pasted from elsewhere — a web page, Mail, Pages — in the
    /// note's own style. It keeps what the text says and how it is built:
    /// bold, italic, code, links, headings, lists. It drops how the page
    /// looked: its fonts, colours, backgrounds and spacing.
    ///
    /// AppKit's HTML reader also writes each list item's marker into the
    /// text — "\t•\t", "\t1\t" — besides making it a list item, so pasted
    /// lists showed two bullets.
    static func pasted(_ source: NSAttributedString) -> NSAttributedString {
        let text = source.string as NSString
        let full = NSRange(location: 0, length: text.length)

        // The size most of the text is in; larger runs are headings.
        var sizes: [CGFloat: Int] = [:]
        source.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            sizes[(value as? NSFont)?.pointSize ?? 12, default: 0] += range.length
        }
        let usual = sizes.max { $0.value < $1.value }?.key ?? 12

        struct Block {
            var content: NSAttributedString
            var style: NSParagraphStyle?
            /// The top-level list it is an item of, if any.
            var list: ObjectIdentifier?
            var spacedAfter: Bool
        }
        var blocks: [Block] = []
        // The page's lists, each rebuilt once, so items stay one list.
        var rebuilt: [ObjectIdentifier: NSTextList] = [:]

        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            var body = paragraph
            while body.length > 0,
                  let last = Unicode.Scalar(text.character(at: NSMaxRange(body) - 1)),
                  CharacterSet.newlines.contains(last) {
                body.length -= 1
            }
            let sourceStyle = source.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle
            let lists = Array((sourceStyle?.textLists ?? []).prefix(maxDepth + 1))

            if !lists.isEmpty, let marker = text.substring(with: body).firstMatch(of: /^\t[^\t\n]*\t/) {
                let length = (String(marker.0) as NSString).length
                body = NSRange(location: body.location + length, length: body.length - length)
            }

            let content = NSMutableAttributedString()
            source.enumerateAttributes(in: body, options: []) { attributes, run, _ in
                // A page's images don't come along; they would be a bare "￼".
                guard attributes[.attachment] == nil else { return }
                content.append(NSAttributedString(string: text.substring(with: run),
                                                  attributes: pastedAttributes(attributes, usualSize: usual)))
            }

            var style: NSParagraphStyle?
            if !lists.isEmpty {
                style = listParagraphStyle(lists.map { list in
                    let key = ObjectIdentifier(list)
                    if let known = rebuilt[key] { return known }
                    let made = NSTextList(markerFormat: list.markerFormat == .decimal ? .decimal : .disc, options: 0)
                    rebuilt[key] = made
                    return made
                })
            } else if let alignment = sourceStyle?.alignment, alignment == .center || alignment == .right {
                let aligned = NSMutableParagraphStyle()
                aligned.alignment = alignment
                style = aligned
            }
            let spacing = (sourceStyle?.paragraphSpacing ?? 0) + (sourceStyle?.paragraphSpacingBefore ?? 0)
            blocks.append(Block(content: content, style: style, list: lists.first.map(ObjectIdentifier.init),
                                spacedAfter: spacing > 1))
        }

        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let isEmpty = block.content.length == 0
            // One blank line at a time.
            if isEmpty, index > 0, blocks[index - 1].content.length == 0 { continue }
            let start = out.length
            out.append(block.content)
            guard index < blocks.count - 1 else {
                if let style = block.style {
                    out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
                }
                break
            }
            // The newline carries the paragraph's style, so a list stays one list.
            var breakAttributes = baseAttributes
            breakAttributes[.paragraphStyle] = block.style
            out.append(NSAttributedString(string: "\n", attributes: breakAttributes))
            if let style = block.style {
                out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: out.length - start))
            }
            // Space the page put between blocks becomes a blank line, as a note
            // writes it — but not between items of one list.
            let next = blocks[index + 1]
            let sameList = block.list != nil && block.list == next.list
            let kindChanges = (block.list == nil) != (next.list == nil)
            if !isEmpty, next.content.length > 0, !sameList, block.spacedAfter || kindChanges {
                out.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            }
        }
        // In the note's rhythm, as it will be once reopened. Without it a
        // pasted paragraph had AppKit's line height and no gap after it.
        return spaced(out)
    }

    /// A pasted run's attributes in the note's terms.
    private static func pastedAttributes(_ attributes: [NSAttributedString.Key: Any],
                                         usualSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var clean: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
        let font = attributes[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let ratio = (font?.pointSize ?? usualSize) / max(1, usualSize)
        if let font, font.isFixedPitch || traits.contains(.fixedPitchFontMask) {
            clean[.font] = codeFont
        } else if ratio >= 1.12 {
            clean[.font] = headingFont(ratio >= 1.7 ? 1 : ratio >= 1.35 ? 2 : 3)
        } else {
            var body = bodyFont
            if traits.contains(.boldFontMask) { body = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { body = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask) }
            clean[.font] = body
        }
        if let link = attributes[.link] { clean[.link] = link }
        for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .superscript]
        where (attributes[key] as? Int ?? 0) != 0 {
            clean[key] = attributes[key]
        }
        return clean
    }

    // MARK: - Storage

    /// True when the document carries formatting the plain-text form cannot
    /// express — bold, colour, a link, an unusual size. Structure (lists,
    /// checklists, headings, quotes) does not count, because the plain text
    /// carries that already.
    static func hasInlineFormatting(_ attributed: NSAttributedString) -> Bool {
        let text = attributed.string as NSString
        let manager = NSFontManager.shared
        // A paragraph at a time: what the plain text can say depends on the
        // line, and one run of attributes can reach across two.
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            // A divider is centred and faint, which is how `---` is shown.
            // Counted as formatting, it kept a note in the rich form, which
            // the edge stickies don't edit.
            if paragraph.length <= (dividerGlyphs as NSString).length + 1,
               text.substring(with: paragraph).trimmingCharacters(in: .newlines) == dividerGlyphs { continue }
            let heading = headingFace(of: paragraph, in: attributed)
            var found = false
            attributed.enumerateAttributes(in: paragraph, options: []) { attributes, range, stop in
                found = isFormatted(attributes, text: text.substring(with: range), heading: heading, manager: manager)
                if found { stop.pointee = true }
            }
            if found { return true }
        }
        return false
    }

    /// Whether a run carries what its plain-text line can't. `heading` is the
    /// face the line comes back in when it is written "#".
    private static func isFormatted(_ attributes: [NSAttributedString.Key: Any], text: String,
                                    heading: NSFont?, manager: NSFontManager) -> Bool {
        if attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil
            || attributes[.link] != nil || attributes[.backgroundColor] != nil
            || (attributes[.superscript] as? Int ?? 0) != 0 {
            return true
        }
        if let color = attributes[.foregroundColor] as? NSColor,
           color != .labelColor, color != .secondaryLabelColor {
            return true
        }
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
           style.alignment != .natural, style.alignment != .left {
            return true
        }
        // A line break's face shows nowhere.
        guard let font = attributes[.font] as? NSFont,
              !text.trimmingCharacters(in: .newlines).isEmpty else { return false }
        if let heading {
            // Written "#": a heading's own face, bold and all, is structure.
            // Counted as formatting, every note with a heading was kept in the
            // rich form. Words in another face would come back in the heading's.
            return font != heading
        }
        let traits = manager.traits(of: font)
        let styled = traits.contains(.boldFontMask) || traits.contains(.italicFontMask)
        // Only a line written "#" comes back larger.
        let sized = font.pointSize != bodySize
        // Serif, monospace, a code block: plain text has no way to say so.
        let family = font.familyName != bodyFamily
        return styled || sized || family
    }

    /// The heading face a paragraph comes back in from its plain-text line:
    /// its first character's, when that is a heading's own and the line is
    /// written as nothing else first — not a list or checklist item, not a
    /// quote (see `line(in:paragraph:)`).
    private static func headingFace(of paragraph: NSRange, in document: NSAttributedString) -> NSFont? {
        guard paragraph.length > 0,
              let lead = document.attribute(.font, at: paragraph.location, effectiveRange: nil) as? NSFont,
              let level = headingLevel(of: lead), lead == headingFont(level) else { return nil }
        let style = document.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle
        guard style?.textLists.isEmpty ?? true, (style?.firstLineHeadIndent ?? 0) == 0 else { return nil }
        return lead
    }

    /// The native archive stored on the note.
    ///
    /// A keyed archive rather than RTF or RTFD: those formats only carry
    /// attributes they know about, so a checkbox came back as an anonymous
    /// attachment and the item stopped being a checklist item at all. This
    /// document does not need to be readable by other apps — the plain-text
    /// form is what travels.
    static func archive(_ attributed: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: attributed, requiringSecureCoding: true)
    }

    static func unarchive(_ data: Data) -> NSAttributedString? {
        let allowed: [AnyClass] = [
            NSAttributedString.self, NSMutableAttributedString.self,
            CheckboxAttachment.self, NSTextAttachment.self, NSTextAttachmentCell.self,
            NSParagraphStyle.self, NSMutableParagraphStyle.self,
            NSTextList.self, NSTextTab.self, NSTextBlock.self,
            NSFont.self, NSColor.self, NSImage.self, NSURL.self,
            NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSValue.self,
        ]
        return try? NSKeyedUnarchiver.unarchivedObject(ofClasses: allowed, from: data)
            as? NSAttributedString
    }

    /// Reads a note written by the web app's editor: its structure from the
    /// plain text, its inline styling from the HTML.
    ///
    /// AppKit's HTML reader can't be trusted with structure. It writes each
    /// list marker into the text ("\t•\tItem") as well as marking the line as
    /// a list item, so the editor drew a second bullet; it turns checklists
    /// into bullets and drops dividers and quotes. The web app's `content`
    /// carries all of that already ("• ", "1. ", "☐ ", "#", "---", ">", nested
    /// by indent), and reads back exactly. What it can't carry — bold, italic,
    /// underline, strikethrough, links — is copied over from the HTML, line
    /// by line where the text matches.
    static func attributed(fromHTML html: String, plain: String) -> NSAttributedString {
        let base = NSMutableAttributedString(attributedString: attributed(fromPlainText: plain))
        guard let styled = attributed(fromHTML: html) else { return base }
        overlayInlineStyles(from: styled, onto: base)
        return base
    }

    /// Paragraphs of `document` as (range of the visible text, the text).
    private static func lines(of document: NSAttributedString, skippingMarkers: Bool) -> [(NSRange, String)] {
        let text = document.string as NSString
        var out: [(NSRange, String)] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)
            var start = paragraph.location
            var end = NSMaxRange(paragraph)
            while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if skippingMarkers {
                // The HTML reader's marker: "\t•\t", "\t1\t", "\t◦\t" at the head of a list item.
                let head = text.substring(with: NSRange(location: start, length: end - start))
                if let match = head.firstMatch(of: /^\t[^\t]{0,8}\t/) {
                    start += (String(head[match.range]) as NSString).length
                }
            } else if end > start, text.character(at: start) == 0xFFFC {
                // A checkbox attachment and the space after it.
                start += 1
                if end > start, text.character(at: start) == 0x20 { start += 1 }
            }
            let range = NSRange(location: start, length: max(0, end - start))
            out.append((range, text.substring(with: range).replacingOccurrences(of: "\u{00A0}", with: " ")))
        }
        return out
    }

    private static func overlayInlineStyles(from styled: NSAttributedString, onto base: NSMutableAttributedString) {
        let manager = NSFontManager.shared
        let sources = lines(of: styled, skippingMarkers: true)
        var next = 0
        for (target, text) in lines(of: base, skippingMarkers: false) where !text.isEmpty {
            // Lines come in the same order; allow a few the HTML reader added or dropped.
            guard let found = sources[next...].prefix(8).firstIndex(where: { $0.1 == text }) else { continue }
            let source = sources[found].0
            next = found + 1
            styled.enumerateAttributes(in: source, options: []) { attributes, run, _ in
                let range = NSRange(location: target.location + run.location - source.location, length: run.length)
                if let font = attributes[.font] as? NSFont {
                    let traits = manager.traits(of: font)
                    for trait in [NSFontTraitMask.boldFontMask, .italicFontMask] where traits.contains(trait) {
                        base.enumerateAttribute(.font, in: range, options: []) { value, sub, _ in
                            let current = value as? NSFont ?? bodyFont
                            base.addAttribute(.font, value: manager.convert(current, toHaveTrait: trait), range: sub)
                        }
                    }
                }
                for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .link] {
                    if let value = attributes[key] { base.addAttribute(key, value: value, range: range) }
                }
            }
        }
    }

    /// Removes list markers written into the text of a list item ("\t•\t"),
    /// which AppKit's HTML reader leaves behind. Notes opened from the web app
    /// before that was handled were saved with them and showed two bullets.
    static func removingLiteralListMarkers(_ document: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: document)
        let text = out.string as NSString
        var cuts: [NSRange] = []
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = NSMaxRange(paragraph)
            let style = out.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
            guard style?.textLists.isEmpty == false,
                  let match = text.substring(with: paragraph).firstMatch(of: /^\t[^\t\n]{0,8}\t/) else { continue }
            cuts.append(NSRange(location: paragraph.location, length: (String(match.output) as NSString).length))
        }
        for cut in cuts.reversed() { out.deleteCharacters(in: cut) }
        return out
    }

    /// AppKit's reading of the web editor's HTML, with web fonts swapped for
    /// the system font. Only for inline styling; see above.
    static func attributed(fromHTML html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let imported = try? NSMutableAttributedString(
            data: data, options: options, documentAttributes: nil) else { return nil }
        normalise(imported)
        return imported
    }

    /// Replaces web fonts with the system font and re-bases sizes, since the
    /// HTML reader works from a 12pt baseline.
    private static func normalise(_ attributed: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: attributed.length)
        let manager = NSFontManager.shared
        let scale = attributed.string.isEmpty ? 1 : bodySize / 12

        attributed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            guard let font = value as? NSFont else {
                attributed.addAttribute(.font, value: bodyFont, range: range)
                return
            }
            let size = (font.pointSize * scale).rounded()
            let traits = manager.traits(of: font)
            var replacement = sans(size)
            if traits.contains(.boldFontMask) {
                replacement = manager.convert(replacement, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
            }
            attributed.addAttribute(.font, value: replacement, range: range)
        }
        // The HTML reader hard-codes black; let the theme decide.
        attributed.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
            if let color = value as? NSColor, color.isEffectivelyBlack {
                attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
    }
}
