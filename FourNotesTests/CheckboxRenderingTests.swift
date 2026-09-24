import AppKit
import SwiftUI
import Testing
@testable import FourNotes

// Checklist boxes drew nothing and took no room: the attachment only answered
// TextKit 1, and the editor runs on TextKit 2. The round-trip suite could not
// see that — the text was right, the screen was not — so these draw it.

@MainActor
@Suite("Checklist boxes on screen", .serialized)
struct CheckboxRenderingTests {

    /// A text view as the editor sets one up, holding `text`.
    private func textView(_ text: String, appearance: NSAppearance.Name,
                          accent: NSColor = .controlAccentColor) -> (NSWindow, NoteTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        view.drawsBackground = false
        view.textContainer?.lineFragmentPadding = 0
        view.checkboxAccent = accent
        window.contentView = view
        view.textStorage?.setAttributedString(NoteDocument.attributed(fromPlainText: text))
        view.layOutEverything()
        return (window, view)
    }

    /// The first line's layout fragment and the checkbox's frame within it.
    private func firstBox(in view: NoteTextView) throws -> (NSTextLayoutFragment, CGRect) {
        let manager = try #require(view.textLayoutManager, "the editor should be on TextKit 2")
        let start = manager.documentRange.location
        let fragment = try #require(manager.textLayoutFragment(for: start))
        return (fragment, fragment.frameForTextAttachment(at: start))
    }

    /// Draws the view as it draws itself, under the window's appearance, and
    /// returns the pixels inside the first box.
    private func boxPixels(_ view: NoteTextView, in window: NSWindow) throws -> [NSColor] {
        let (fragment, frame) = try firstBox(in: view)
        let box = frame.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                 dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        var pixels: [NSColor] = []
        // The view is flipped, and bitmap rows run top down: the same way.
        for y in Int(box.minY * scale)..<Int(box.maxY * scale) {
            for x in Int(box.minX * scale)..<Int(box.maxX * scale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 {
                    pixels.append(color)
                }
            }
        }
        return pixels
    }

    private func brightness(_ color: NSColor) -> CGFloat {
        (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    @Test("a checklist item leaves room for its box")
    func boxHasRoom() throws {
        let (_, view) = textView("☐ Book the villa", appearance: .aqua)
        let (_, box) = try firstBox(in: view)
        #expect(box.width == CheckboxAttachment.bounds.width)
        #expect(box.height == CheckboxAttachment.bounds.height)
    }

    @Test("the box is drawn, in a colour the theme's page shows",
          arguments: [(ThemeChoice.light, NSAppearance.Name.aqua),
                      (.paper, .aqua),
                      (.dark, .darkAqua)])
    func boxIsVisible(_ theme: ThemeChoice, _ appearance: NSAppearance.Name) throws {
        let palette = theme.palette(for: appearance == .darkAqua ? .dark : .light)
        let page = try #require(NSColor(palette.bg).usingColorSpace(.sRGB))
        for text in ["☐ Book the villa", "☑ Jacket"] {
            let (window, view) = textView(text, appearance: appearance, accent: NSColor(palette.accent))
            let pixels = try boxPixels(view, in: window)
            #expect(pixels.count > 40, "\(text) drew \(pixels.count) pixels in \(theme.label)")
            // Ink that stands out from the page, not black on the dark theme.
            let contrast = pixels.map { abs(brightness($0) - brightness(page)) }.max() ?? 0
            #expect(contrast > 0.3, "\(text) in \(theme.label) is too close to the page colour")
        }
    }

    @Test("a ticked box is filled with the theme's accent, not the system's")
    func tickedUsesAccent() throws {
        // Teal: no system accent colour is, so only the view's can draw it.
        let teal = NSColor(srgbRed: 0.05, green: 0.6, blue: 0.6, alpha: 1)
        let (window, view) = textView("☑ Jacket", appearance: .aqua, accent: teal)
        let pixels = try boxPixels(view, in: window)
        let tealish = pixels.filter {
            // Colour management moves it a little; the hue is what counts.
            $0.greenComponent - $0.redComponent > 0.2 && abs($0.greenComponent - $0.blueComponent) < 0.1
        }
        #expect(tealish.count > pixels.count / 2)
    }

    @Test("clicking a box ticks it, and the plain text follows")
    func clickToggles() throws {
        let controller = RichTextController()
        let editor = RichTextEditor(attributed: .constant(NoteDocument.attributed(fromPlainText: "☐ Item\n☑ Done")),
                                    controller: controller, onTextChange: { _ in }, header: Text("Packing"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(window.contentView?.firstDescendant(of: NSScrollView.self))
        let document = try #require(scroll.documentView as? NoteDocumentView)
        document.layoutSubtreeIfNeeded()
        let view = document.textView
        #expect(controller.plainText == "☐ Item\n☑ Done")

        // Click the middle of each box, where it is drawn on screen.
        func click(_ index: Int) {
            let screen = view.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
            let point = window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
            // Should the click miss, NSTextView's own tracking ends on this.
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 0) {
                NSApp.postEvent(up, atStart: false)
            }
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) {
                view.mouseDown(with: down)
            }
        }
        let second = (view.string as NSString).range(of: "\n").location + 1
        click(0)
        #expect(controller.plainText == "☑ Item\n☑ Done")
        click(second)
        #expect(controller.plainText == "☑ Item\n☐ Done")
        click(0)
        #expect(controller.plainText == "☐ Item\n☐ Done")
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}
