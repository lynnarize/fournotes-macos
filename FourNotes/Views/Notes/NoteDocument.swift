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

/// A checkbox in a note. Carries its own state so toggling one is a local edit.
///
/// The image is drawn on demand rather than stored on the attachment: setting
/// `image` puts the whole bitmap into the note's archive, which took a
/// three-line checklist from 39 bytes of text to 46KB on disk.
final class CheckboxAttachment: NSTextAttachment {
    override class var supportsSecureCoding: Bool { true }

    var isChecked: Bool

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
        isChecked = coder.decodeBool(forKey: "isChecked")
        super.init(coder: coder)
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

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }

    static var codeFont: NSFont { .monospacedSystemFont(ofSize: 14, weight: .regular) }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    /// Heading levels, as the toolbar offers them.
    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return .systemFont(ofSize: 28, weight: .bold)
        case 2: return .systemFont(ofSize: 22, weight: .bold)
        case 3: return .systemFont(ofSize: 18, weight: .semibold)
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
        style.paragraphSpacing = 2
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
        style.paragraphSpacing = 2
        return style
    }

    /// How deeply a checklist item is nested, read back from its indent.
    static func checklistDepth(_ style: NSParagraphStyle?) -> Int {
        guard let style else { return 0 }
        return min(maxDepth, max(0, Int((style.firstLineHeadIndent / indentStep).rounded())))
    }

    /// A divider. Stored as `---`, which is what the web app writes and reads.
    static let dividerGlyphs = "———"

    static func divider() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: dividerGlyphs, attributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    static func quoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = 16
        style.firstLineHeadIndent = 16
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
        let text = document.string as NSString
        guard text.length > 0, text.character(at: text.length - 1) != 0x0A,
              !(text as String).hasSuffix(dividerGlyphs) else {
            // An empty line, or a divider, whose centring must not carry on
            // into what is typed below it: a plain newline.
            return NSAttributedString(string: "\n", attributes: baseAttributes)
        }
        // Only the paragraph style: a heading's font on the newline would make
        // anything typed on the empty line below it heading-sized.
        var attributes = baseAttributes
        attributes[.paragraphStyle] = document.attribute(.paragraphStyle, at: text.length - 1,
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

    // MARK: - Storage

    /// True when the document carries formatting the plain-text form cannot
    /// express — bold, colour, a link, an unusual size. Structure (lists,
    /// checklists, headings, quotes) does not count, because the plain text
    /// carries that already.
    static func hasInlineFormatting(_ attributed: NSAttributedString) -> Bool {
        let full = NSRange(location: 0, length: attributed.length)
        var found = false
        let manager = NSFontManager.shared

        attributed.enumerateAttributes(in: full, options: []) { attributes, _, stop in
            if attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil
                || attributes[.link] != nil || attributes[.backgroundColor] != nil
                || (attributes[.superscript] as? Int ?? 0) != 0 {
                found = true; stop.pointee = true; return
            }
            if let color = attributes[.foregroundColor] as? NSColor,
               color != .labelColor, color != .secondaryLabelColor {
                found = true; stop.pointee = true; return
            }
            if let font = attributes[.font] as? NSFont {
                let traits = manager.traits(of: font)
                let styled = traits.contains(.boldFontMask) || traits.contains(.italicFontMask)
                let sized = headingLevel(of: font) == nil && font.pointSize != bodySize
                // Serif, monospace, a code block: plain text has no way to say so.
                let family = font.familyName != NSFont.systemFont(ofSize: font.pointSize).familyName
                if styled || sized || family { found = true; stop.pointee = true; return }
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               style.alignment != .natural, style.alignment != .left {
                found = true; stop.pointee = true; return
            }
        }
        return found
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

    /// Reads a note written by the web app's editor. Used once, when a note has
    /// HTML but no native archive yet.
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
            var replacement = NSFont.systemFont(ofSize: size)
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
