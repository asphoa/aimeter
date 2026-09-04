import AppKit

/// The two-ring menu bar icon (v1.0.26), replacing the bar strip as the
/// default. Two concentric arcs for the primary service's two windows, an
/// optional alert dot for every other service, and an optional numeral —
/// with the strip (`StatusStrip`) kept only as the `bars` fallback for
/// config.json.
///
/// Pure model/colour/easing functions live here alongside the drawing code so
/// the whole thing can be tested without a display: `model(readings:primary:)`
/// decides *what* to draw, `image(for:phase:progress:)` is the only place
/// that draws it.
enum RingIcon {
    static let canvas: CGFloat = 18
    static let centre = CGPoint(x: 9, y: 9)
    static let outerRadius: CGFloat = 6.9
    static let outerStroke: CGFloat = 2.2
    static let innerRadius: CGFloat = 4.4
    static let innerStroke: CGFloat = 1.5
    static let dotRadius: CGFloat = 2
    static let dotCentre = CGPoint(x: 15.6, y: 2.6)
    static let numeralGap: CGFloat = 5
    static let numeralWidth: CGFloat = 34   // room for "100%" at 12pt semibold

    enum Band: Equatable { case ink, warn, alarm }

    /// The pure shape this icon draws: nothing here is an NSColor or NSImage,
    /// so it can be built and compared in a test with no display.
    struct RingModel: Equatable {
        var outer: Double?
        var inner: Double?
        var alertDot: Bool = false
        var numeral: String? = nil
    }

    /// 70/90, inclusive at the boundary per spec: 69.9 is ink, 70 is warn,
    /// 89.9 is warn, 90 is alarm.
    static func colourBand(_ percent: Double) -> Band {
        if percent >= 90 { return .alarm }
        if percent >= 70 { return .warn }
        return .ink
    }

    /// Builds the model for the primary service's two rings plus the other
    /// providers' alert-dot condition. `style` decides whether a numeral is
    /// attached; nothing else about the model depends on it.
    static func model(readings: [String: [Reading]], primary: String,
                       style: String = "ring") -> RingModel {
        var out = RingModel()
        if let raw = readings[primary] {
            let rows = Reading.asOfNow(raw)
            let gauges = rows.flatMap(\.gauges).filter { $0.percent != nil }
            out.outer = gauges.filter { $0.kind == .shortWindow }.compactMap(\.percent).max()
            // Unscoped long window only — a `.modelWindow` (a per-model weekly
            // entry, e.g. Claude's "Fable" scoped line) is never picked up
            // here, matching the strip's own `.longWindow`/`.modelWindow`
            // distinction (see GaugeKind).
            out.inner = gauges.filter { $0.kind == .longWindow }.compactMap(\.percent).max()
        }
        for (id, raw) in readings where id != primary {
            let rows = Reading.asOfNow(raw)
            let highGauge = rows.flatMap(\.gauges).compactMap(\.percent).contains { $0 >= 70 }
            let alertState = rows.contains { $0.state == .warn || $0.state == .nearLimit || $0.state == .failure }
            if highGauge || alertState { out.alertDot = true }
        }
        if style == "ringNumeral", let o = out.outer {
            out.numeral = String(format: "%.0f%%", o)
        }
        return out
    }

    /// Ease-out cubic: fast start, gentle arrival — `eased(0) == 0`,
    /// `eased(1) == 1`, monotone increasing, and past the midpoint of a
    /// linear sweep (`eased(0.5) > 0.5`) by construction.
    static func eased(_ t: Double) -> Double {
        let c = max(0, min(1, t))
        return 1 - pow(1 - c, 3)
    }

    private static func arcColour(_ band: Band) -> NSColor {
        switch band {
        case .ink:   return .labelColor
        case .warn:  return Palette.colour(Palette.warn)
        case .alarm: return Palette.colour(Palette.alarm)
        }
    }

    /// Renders the model to an NSImage. `phase` (0...1) drives the ≥90%
    /// breathing alpha on the outer arc; `progress` (0...1, eased outside)
    /// interpolates from `from` (the previously shown model, for the sweep
    /// animation) to `model`. Both default to "no animation in progress".
    static func image(for model: RingModel, from: RingModel? = nil,
                       phase: Double = 0, progress: Double = 1) -> NSImage {
        let numeralOn = model.numeral != nil
        let width = numeralOn ? canvas + numeralGap + numeralWidth : canvas
        let size = NSSize(width: width, height: canvas)
        let img = NSImage(size: size, flipped: false) { _ in
            func lerp(_ a: Double?, _ b: Double?) -> Double? {
                guard let b else { return nil }
                guard let a else { return b * progress }
                return a + (b - a) * progress
            }
            let outer = lerp(from?.outer, model.outer)
            let inner = lerp(from?.inner, model.inner)

            drawTrack(radius: outerRadius, stroke: outerStroke)
            drawTrack(radius: innerRadius, stroke: innerStroke)

            if let outer {
                var alpha: CGFloat = 1
                if let m = model.outer, colourBand(m) == .alarm {
                    // Breathe 1.0 -> 0.55 -> 1.0 over the phase's period.
                    alpha = 0.775 + 0.225 * CGFloat(cos(phase * 2 * .pi))
                }
                drawArc(radius: outerRadius, stroke: outerStroke, percent: outer,
                       colour: arcColour(colourBand(outer)).withAlphaComponent(alpha))
            }
            if let inner {
                drawArc(radius: innerRadius, stroke: innerStroke, percent: inner,
                       colour: arcColour(colourBand(inner)))
            }
            if model.alertDot {
                Palette.colour(Palette.alarm).setFill()
                let r = dotRadius
                NSBezierPath(ovalIn: NSRect(x: dotCentre.x - r, y: canvas - dotCentre.y - r,
                                            width: r * 2, height: r * 2)).fill()
            }
            if let numeral = model.numeral {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.labelColor
                ]
                let str = NSAttributedString(string: numeral, attributes: attrs)
                let sz = str.size()
                let y = (canvas - sz.height) / 2
                str.draw(at: NSPoint(x: canvas + numeralGap, y: y))
            }
            return true
        }
        img.isTemplate = false   // amber/red states need real colour, not a single tint
        return img
    }

    private static func drawTrack(radius: CGFloat, stroke: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: canvas - centre.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = stroke
        NSColor.labelColor.withAlphaComponent(0.14).setStroke()
        path.stroke()
    }

    /// Starts at 12 o'clock, runs clockwise. In AppKit's unflipped angle
    /// convention (0° = 3 o'clock, counter-clockwise positive) that is
    /// start = 90°, end = 90° - 360*pct/100.
    private static func drawArc(radius: CGFloat, stroke: CGFloat, percent: Double, colour: NSColor) {
        guard percent > 0 else { return }
        let clamped = max(0, min(100, percent))
        let start: CGFloat = 90
        let end = start - CGFloat(clamped) / 100 * 360
        let path = NSBezierPath()
        // y flipped because NSImage(size:flipped:false:) draws with origin
        // at bottom-left in the standard AppKit coordinate space.
        path.appendArc(withCenter: NSPoint(x: centre.x, y: canvas - centre.y),
                       radius: radius, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = stroke
        path.lineCapStyle = .round
        colour.setStroke()
        path.stroke()
    }
}

/// Owns the one Timer that redraws the ring during a refresh's sweep and the
/// ≥90% breathing loop, so nothing but this object ever starts or stops one —
/// two independent timers driving the same image would race.
@MainActor
final class RingAnimator {
    private var timer: Timer?
    private var current: RingIcon.RingModel = RingIcon.RingModel()
    private var previous: RingIcon.RingModel?
    private var sweepStart: Date?
    private let onUpdate: (NSImage) -> Void

    init(onUpdate: @escaping (NSImage) -> Void) {
        self.onUpdate = onUpdate
    }

    /// Called on each successful refresh. Animates the sweep from the last
    /// shown model to the new one, unless motion is off (config, or Reduce
    /// Motion), in which case it redraws once with no transition.
    func show(_ model: RingIcon.RingModel, animated: Bool) {
        timer?.invalidate()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            current = model
            previous = nil
            onUpdate(RingIcon.image(for: model))
            startBreathingIfNeeded()
            return
        }
        previous = current
        current = model
        sweepStart = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let start = sweepStart else { return }
        let t = Date().timeIntervalSince(start) / 0.5
        if t >= 1 {
            timer?.invalidate()
            sweepStart = nil
            previous = nil
            onUpdate(RingIcon.image(for: current))
            startBreathingIfNeeded()
            return
        }
        let eased = RingIcon.eased(t)
        onUpdate(RingIcon.image(for: current, from: previous, progress: eased))
    }

    /// The alarm-band "breathing" loop: only running while the outer ring is
    /// ≥90%, restarted from `show` so a config change or a fresh reading
    /// never leaves two timers alive.
    private func startBreathingIfNeeded() {
        guard let outer = current.outer, RingIcon.colourBand(outer) == .alarm else { return }
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let phase = Date().timeIntervalSince(started).truncatingRemainder(dividingBy: 1.6) / 1.6
                self.onUpdate(RingIcon.image(for: self.current, phase: phase))
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
