import AppKit

/// What a gauge measures. The strip maps `.shortWindow` to a line's top half
/// and `.longWindow` to its bottom half, so providers only have to tag their
/// gauges correctly and the layout follows.
enum GaugeKind: String, Codable, Sendable { case shortWindow, longWindow, other }

enum BarColourScheme: String, Codable, Sendable, CaseIterable {
    /// Hue identifies the service; red is held back and means "nearly spent".
    case provider
    /// Hue identifies the window: red = 5-hour, blue = weekly, teal = single.
    case window
}

/// One line of the strip: one service, split into a 5-hour half above and a
/// weekly half below. A service with only one window draws a single merged bar,
/// which is itself the signal that it has only one.
struct StripLine {
    var provider: String
    var top: Double?
    var bottom: Double?
    var merged: Double?
    var state: ReadingState = .off
    var stale: Bool = false

    var hasData: Bool { top != nil || bottom != nil || merged != nil }

    static func noData(_ provider: String, state: ReadingState = .off) -> StripLine {
        StripLine(provider: provider, top: nil, bottom: nil, merged: nil, state: state)
    }
}

/// Draws the menu bar strip.
///
/// Geometry keeps every edge on the half-point grid so nothing lands between
/// device pixels at 2x. Five lines is the ceiling: at five, each half is 1.5 pt
/// (3 px) and the gaps are down to 0.5 pt, which is the point where the render
/// stops separating cleanly.
enum StatusStrip {
    static let width: CGFloat = 26
    static let height: CGFloat = 18
    static let maxLines = 5
    private static let radius: CGFloat = 1

    /// Fewer lines means fatter bars. Three is where the strip is comfortably
    /// readable at arm's length; five is the point where each half is down to
    /// 3 px and legibility is the thing being spent.
    private static func halfHeight(_ count: Int) -> CGFloat {
        switch count {
        case ...3: return 2.5
        case 4:    return 2
        default:   return 1.5
        }
    }

    private static func gapHeight(_ count: Int) -> CGFloat { count <= 3 ? 1 : 0.5 }

    static func image(lines input: [StripLine], scheme: BarColourScheme) -> NSImage {
        let lines = Array(input.prefix(maxLines))
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard !lines.isEmpty else { return true }
            let half = halfHeight(lines.count)
            let gap = gapHeight(lines.count)
            let pair = half * 2
            let total = CGFloat(lines.count) * pair + CGFloat(lines.count - 1) * gap
            var y = ((height - total) / 2 * 2).rounded() / 2

            for (i, line) in lines.enumerated() {
                draw(line, index: i, at: y, half: half, scheme: scheme)
                y += pair + gap
            }
            return true
        }
        img.isTemplate = false      // a template image can carry only one tint
        return img
    }

    private static func draw(_ line: StripLine, index: Int, at y: CGFloat,
                             half: CGFloat, scheme: BarColourScheme) {
        let pair = half * 2
        guard line.hasData, line.state != .error else {
            drawDots(at: y, height: pair)
            return
        }
        if let merged = line.merged {
            bar(merged, x: y, height: pair, colour: colour(line, .other, merged, scheme))
            return
        }
        if let top = line.top {
            bar(top, x: y, height: half, colour: colour(line, .shortWindow, top, scheme))
        } else {
            dim(y, half)
        }
        if let bottom = line.bottom {
            bar(bottom, x: y + half, height: half, colour: colour(line, .longWindow, bottom, scheme))
        } else {
            dim(y + half, half)
        }
        // Both halves now sit on the light side of the scale, so the split
        // between them needs a line of its own rather than a luminance step.
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: y + half - 0.25, width: width, height: 0.5).fill()
    }

    private static func bar(_ pct: Double, x y: CGFloat, height: CGFloat, colour: NSColor) {
        Palette.colour(Palette.track).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: width, height: height),
                     xRadius: radius, yRadius: radius).fill()
        guard pct > 0 else { return }
        // A 2% fill is under half a point; clamp so "barely used" cannot render
        // as "untouched".
        let w = max(1, min(width, width * CGFloat(pct) / 100))
        colour.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: height),
                     xRadius: radius, yRadius: radius).fill()
    }

    /// Half of a pair whose window this service does not have. Drawn as a bare
    /// track so the line keeps its shape without claiming a measurement.
    private static func dim(_ y: CGFloat, _ height: CGFloat) {
        Palette.colour(Palette.track).withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: width, height: height),
                     xRadius: radius, yRadius: radius).fill()
    }

    private static func drawDots(at y: CGFloat, height: CGFloat) {
        let d: CGFloat = 1.5, spacing: CGFloat = 2
        let span = d * 3 + spacing * 2
        var x = (width - span) / 2
        Palette.text(0.55).setFill()
        for _ in 0..<3 {
            NSBezierPath(ovalIn: NSRect(x: x, y: y + (height - d) / 2, width: d, height: d)).fill()
            x += d + spacing
        }
    }

    // MARK: - colour

    /// Hues live in Palette so the user can change them; the defaults are on the
    /// cool side of the wheel, leaving red and orange free to mean one thing.
    /// The menu bar takes its appearance from the wallpaper tint rather than the
    /// system light/dark setting — measured, not assumed — so they have to hold
    /// up against a mid-luminance coloured bar as well as white and black.

    private static func colour(_ line: StripLine, _ kind: GaugeKind,
                               _ pct: Double, _ scheme: BarColourScheme) -> NSColor {
        var c: NSColor
        switch scheme {
        case .window:
            // systemBlue disappears into both a blue wallpaper and the open-menu
            // highlight, so the weekly half uses a lighter sky blue.
            switch kind {
            case .shortWindow: c = NSColor(srgbRed: 1.0, green: 0.361, blue: 0.310, alpha: 1)
            case .longWindow:  c = NSColor(srgbRed: 0.271, green: 0.761, blue: 1.0, alpha: 1)
            case .other:       c = NSColor(srgbRed: 0.231, green: 0.784, blue: 0.745, alpha: 1)
            }
        case .provider:
            // Red is reserved: it overrides identity so that "nearly spent" is
            // never something the eye has to decode.
            if pct >= 90 { return Palette.colour(Palette.alarm) }
            let base = Palette.colour(Palette.service(line.provider))
            switch kind {
            case .shortWindow: c = base
            case .longWindow:  c = blend(base, with: .white, 0.35)
            case .other:       c = base
            }
        }
        if line.stale { c = c.withAlphaComponent(0.55) }
        return c
    }

    private static func blend(_ a: NSColor, with b: NSColor, _ t: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: x.redComponent * (1 - t) + y.redComponent * t,
                       green: x.greenComponent * (1 - t) + y.greenComponent * t,
                       blue: x.blueComponent * (1 - t) + y.blueComponent * t,
                       alpha: 1)
    }
}
