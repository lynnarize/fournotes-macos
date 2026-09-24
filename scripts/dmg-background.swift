// Draws the DMG window's background: the setup screens' soft light, an arrow
// from the app to Applications, and one line telling you what to do.
// Usage: swift dmg-background.swift <out.png> <scale>
import AppKit

let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let size = NSSize(width: 660, height: 400)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// Paper-white page with a warm glow top-left and a cool one bottom-right.
hex(0xFCFBFA).setFill()
NSRect(origin: .zero, size: size).fill()
func glow(_ color: NSColor, at p: NSPoint, radius: CGFloat) {
    let g = NSGradient(colors: [color, color.withAlphaComponent(0)])!
    g.draw(fromCenter: p, radius: 0, toCenter: p, radius: radius, options: [])
}
glow(hex(0xF6C7B6, 0.75), at: NSPoint(x: 230, y: 330), radius: 330)
glow(hex(0xC9DDF3, 0.7), at: NSPoint(x: 560, y: 60), radius: 300)

// Title and hint, in the app's serif.
let para = NSMutableParagraphStyle(); para.alignment = .center
let serif = NSFont(descriptor: NSFont.systemFont(ofSize: 26).fontDescriptor.withDesign(.serif)!, size: 26)!
("Four Notes" as NSString).draw(in: NSRect(x: 0, y: 318, width: size.width, height: 40), withAttributes: [
    .font: serif, .foregroundColor: hex(0x1F1D1A), .paragraphStyle: para])
("Drag Four Notes into Applications to install" as NSString).draw(
    in: NSRect(x: 0, y: 292, width: size.width, height: 22),
    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: hex(0x6B675F), .paragraphStyle: para])

// A soft arrow between the two icons (icons sit at x 180 and 480, y 190 from the top).
let arrow = NSBezierPath()
let y: CGFloat = size.height - 190
arrow.move(to: NSPoint(x: 268, y: y))
arrow.curve(to: NSPoint(x: 388, y: y), controlPoint1: NSPoint(x: 305, y: y + 18), controlPoint2: NSPoint(x: 350, y: y + 18))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
hex(0xC0643C, 0.85).setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 376, y: y + 10))
head.line(to: NSPoint(x: 390, y: y))
head.line(to: NSPoint(x: 377, y: y - 10))
head.lineWidth = 2.5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
