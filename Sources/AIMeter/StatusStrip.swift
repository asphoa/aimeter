import AppKit

enum BarColourScheme: String, Codable, Sendable, CaseIterable {
    case provider

    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer().decode(String.self)
        self = .provider
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.provider.rawValue)
    }
}

/// One line of the strip: one service, split into a 5-hour half above and a
/// weekly half below. A service with only one window draws a single merged bar,
/// which is itself the signal that it has only one.
struct StripLine {
    var provider: String
    var top: Double?
    var bottom: Double?
    var merged: Double?
    /// Which window a merged bar came from, so it takes that window's colour.
    var mergedKind: GaugeKind = .other
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

    static func image(lines input: [StripLine]) -> NSImage {
        let lines = Array(input.prefix(maxLines))
        let img = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard !lines.isEmpty else { return true }
            let half = halfHeight(lines.count)
            let gap = gapHeight(lines.count)
            let pair = half * 2
            let total = CGFloat(lines.count) * pair + CGFloat(lines.count - 1) * gap
            var y = ((height - total) / 2 * 2).rounded() / 2

            for line in lines {
                draw(line, at: y, half: half)
                y += pair + gap
            }
            return true
        }
        img.isTemplate = false      // a template image can carry only one tint
        return img
    }

    private static func draw(_ line: StripLine, at y: CGFloat, half: CGFloat) {
        let pair = half * 2
        // Dots mean "nothing to draw", and `hasData` is the whole of that
        // question. `state` used to be consulted here as well, which quietly
        // made this the opposite of a meter: one error state was two things at once —
        // a fetch that failed, and a gauge past 90% — so crossing 90% replaced
        // a service's bar with the same three dots that mean "no reading", at
        // exactly the moment there was most to report. A failed fetch carries
        // no gauges anyway (`Reading.failed`), so it still lands on the dots
        // through `hasData`, which is where that decision belongs.
        guard line.hasData else {
            drawDots(at: y, height: pair)
            return
        }
        if let merged = line.merged {
            bar(merged, x: y, height: pair,
                colour: colour(line, line.mergedKind), critical: merged >= 90)
            return
        }
        if let top = line.top {
            bar(top, x: y, height: half,
                colour: colour(line, .shortWindow), critical: top >= 90)
        } else {
            dim(y, half)
        }
        if let bottom = line.bottom {
            bar(bottom, x: y + half, height: half,
                colour: colour(line, .longWindow), critical: bottom >= 90)
        } else {
            dim(y + half, half)
        }
        // Both halves now sit on the light side of the scale, so the split
        // between them needs a line of its own rather than a luminance step.
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: y + half - 0.25, width: width, height: 0.5).fill()
    }

    private static func bar(_ pct: Double, x y: CGFloat, height: CGFloat, colour: NSColor, critical: Bool) {
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
        // Adaptive mode deliberately keeps a row's hue even at 90%+ so five
        // urgent services do not collapse into one indistinguishable red slab.
        // This opaque red cap is the common alarm glyph: it says "critical"
        // without spending the remaining 90% of a near-full bar's identity.
        if critical {
            let cap = min(CGFloat(2), w)
            Palette.colour(Palette.alarm).setFill()
            NSRect(x: w - cap, y: y, width: cap, height: height).fill()
        }
    }

    /// Half of a pair whose window this service does not have. Drawn as a bare
    /// track so the line keeps its shape without claiming a measurement.
    private static func dim(_ y: CGFloat, _ height: CGFloat) {
        Palette.colour(Palette.track).setFill()
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

    static func serviceWindowColour(provider: String, kind: GaugeKind) -> NSColor {
        let base = Palette.serviceColour(provider)
        switch kind {
        case .longWindow, .modelWindow:
            return Palette.blend(base, toward: Palette.ground, 0.35)
        case .shortWindow, .other:
            return base
        }
    }

    private static func colour(_ line: StripLine, _ kind: GaugeKind) -> NSColor {
        let colour = serviceWindowColour(provider: line.provider, kind: kind)
        return line.stale ? colour.withAlphaComponent(0.55) : colour
    }
}
