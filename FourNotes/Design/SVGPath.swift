import SwiftUI

/// Parses the `d` attribute of an SVG path into a SwiftUI `Path`.
/// The app's icon set is hand-written SVG (src/components/ui.tsx); porting the
/// path data keeps every icon identical to the web app instead of approximating
/// it with a system symbol.
enum SVGPath {
    static func path(from d: String, in rect: CGRect, viewBox: CGSize = CGSize(width: 24, height: 24)) -> Path {
        parse(d, in: rect, viewBox: viewBox).path
    }

    /// True when every command in `d` was understood. A path the parser gives
    /// up on part-way still draws — just the part before the problem — so a
    /// broken icon shows up as a blank or a stray dot, not as an error.
    static func isComplete(_ d: String) -> Bool {
        parse(d, in: CGRect(x: 0, y: 0, width: 24, height: 24), viewBox: CGSize(width: 24, height: 24)).complete
    }

    private static func parse(_ d: String, in rect: CGRect, viewBox: CGSize) -> (path: Path, complete: Bool) {
        var path = Path()
        var tokens = Tokenizer(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "

        // Every command but `Z` consumes at least one number and bails through
        // its own guard. `Z` consumes nothing, so a path like "M0 0 Z5" would
        // otherwise loop forever with no progress.
        var steps = 0
        while let command = tokens.nextCommand(after: lastCommand) {
            steps += 1
            guard steps < 10_000 else { return (scaled(path, rect, viewBox), false) }
            let relative = command.isLowercase
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(command.uppercased()) {
            case "M":
                guard let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                current = point(x, y); start = current
                path.move(to: current)
                lastControl = nil

            case "L":
                guard let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                current = point(x, y)
                path.addLine(to: current)
                lastControl = nil

            case "H":
                guard let x = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil

            case "V":
                guard let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil

            case "C":
                guard let x1 = tokens.number(), let y1 = tokens.number(),
                      let x2 = tokens.number(), let y2 = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                let c1 = point(x1, y1), c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2

            case "S":
                guard let x2 = tokens.number(), let y2 = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                let c1 = reflect(lastControl, around: current)
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2

            case "Q":
                guard let x1 = tokens.number(), let y1 = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                let c = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastControl = c

            case "T":
                guard let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                let c = reflect(lastControl, around: current)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                lastControl = c

            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rotation = tokens.number(),
                      let largeArc = tokens.flag(), let sweep = tokens.flag(),
                      let x = tokens.number(), let y = tokens.number() else { return (scaled(path, rect, viewBox), false) }
                let end = point(x, y)
                addArc(&path, from: current, to: end, rx: rx, ry: ry,
                       rotation: rotation, largeArc: largeArc, sweep: sweep)
                current = end
                lastControl = nil

            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil

            default:
                return (scaled(path, rect, viewBox), false)
            }
            lastCommand = command
        }
        return (scaled(path, rect, viewBox), tokens.atEnd)
    }

    private static func reflect(_ control: CGPoint?, around point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    private static func scaled(_ path: Path, _ rect: CGRect, _ viewBox: CGSize) -> Path {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let dx = rect.minX + (rect.width - viewBox.width * scale) / 2
        let dy = rect.minY + (rect.height - viewBox.height * scale) / 2
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: dx, y: dy)))
    }

    /// Endpoint-parameterised arc -> centre parameterisation (SVG spec, F.6.5),
    /// then approximated with cubic segments of at most 90°.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || (p0 == p1) {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx2 = (p0.x - p1.x) / 2, dy2 = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Scale the radii up if they are too small to span the endpoints.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        let sign: CGFloat = largeArc == sweep ? -1 : 1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            let a = acos(max(-1, min(1, dot / len)))
            return (ux * vy - uy * vx) < 0 ? -a : a
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        var theta = startAngle

        for _ in 0..<segments {
            let next = theta + step
            let t = 4.0 / 3.0 * tan(step / 4)

            func onArc(_ a: CGFloat) -> CGPoint {
                let x = rx * cos(a), y = ry * sin(a)
                return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
            }
            func derivative(_ a: CGFloat) -> CGPoint {
                let x = -rx * sin(a), y = ry * cos(a)
                return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
            }

            let p = onArc(theta), q = onArc(next)
            let dp = derivative(theta), dq = derivative(next)
            path.addCurve(
                to: q,
                control1: CGPoint(x: p.x + t * dp.x, y: p.y + t * dp.y),
                control2: CGPoint(x: q.x - t * dq.x, y: q.y - t * dq.y))
            theta = next
        }
    }

    // MARK: - Tokenizer

    private struct Tokenizer {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        var atEnd: Bool {
            mutating get { skipSeparators(); return i >= chars.count }
        }

        private mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" {
                i += 1
            }
        }

        /// Returns the next command letter, or repeats the previous one for
        /// implicit repetitions ("M4 7 8 9" means a moveto then a lineto).
        mutating func nextCommand(after previous: Character) -> Character? {
            skipSeparators()
            guard i < chars.count else { return nil }
            if chars[i].isLetter {
                let c = chars[i]
                i += 1
                return c
            }
            guard previous != " " else { return nil }
            // An implicit repeat of "M" continues as "L" (spec), preserving case.
            if previous == "M" { return "L" }
            if previous == "m" { return "l" }
            return previous
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var s = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            // A second "." starts the next number: compact SVG writes ".8.8"
            // for 0.8, 0.8. Reading it as one token made the parse stop there,
            // which left icons like "more" drawing nothing at all.
            var seenDot = false
            while i < chars.count, chars[i].isNumber || (chars[i] == "." && !seenDot) {
                if chars[i] == "." { seenDot = true }
                s.append(chars[i]); i += 1
            }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                s.append(chars[i]); i += 1
                if i < chars.count, chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
                while i < chars.count, chars[i].isNumber { s.append(chars[i]); i += 1 }
            }
            guard let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        /// Arc flags are single characters and may be written without separators.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            let v = chars[i] == "1"
            i += 1
            return v
        }
    }
}
