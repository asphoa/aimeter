import AppKit

/// The dropdown panel's rows, drawn rather than assembled out of characters.
///
/// The previous version padded labels with spaces to line up columns, which
/// counts characters — and a CJK label is twice as wide per character as a Latin
/// one, so a list mixing the two cannot line up in any font. Drawing puts every
/// column at a fixed x instead.
enum Panel {
    static let width: CGFloat = 430
    static let leftInset: CGFloat = 28
    static let rightInset: CGFloat = 14

    static func header(dot: NSColor, title: String, trailing: String?) -> NSView {
        let v = HeaderRowView()
        v.dotColour = dot
        v.title = title
        v.trailing = trailing
        return v
    }

    static func gauge(label: String, percent: Double?, value: String,
                      trailing: String?, fill: NSColor, expired: Bool = false) -> NSView {
        let v = GaugeRowView()
        v.label = label
        v.percent = percent
        v.value = value
        v.trailing = trailing
        v.fill = fill
        v.expired = expired
        return v
    }

    static func info(_ text: String, error: Bool) -> NSView {
        let v = InfoRowView()
        v.text = text
        v.isError = error
        return v
    }
}

/// Builds the panel's rows once, for both the live menu and the offscreen
/// render used to check it. Two code paths drawing the same panel would drift.
@MainActor
func buildPanelRows(_ providers: [Provider],
                    _ readings: [String: [Reading]],
                    _ cfg: Config) -> [NSView] {
    var rows: [NSView] = []
    for p in providers {
        guard let list = readings[p.id] else {
            rows.append(Panel.info("\(p.title)  " + L.t("m.loading"), error: false))
            continue
        }
        if list.isEmpty { continue }
        let showAccounts = list.count > 1
        for r in Reading.asOfNow(list) {
            var name = r.title
            if showAccounts, let a = r.account { name += " · \(a)" }
            rows.append(Panel.header(dot: stateColour(r.state), title: name,
                                     trailing: r.snapshotAt.map { L.t("m.snapshot", Fmt.relative($0)) }))
            for g in r.gauges {
                // The panel keeps the traffic light: it has room for a label as
                // well, so hue can carry urgency here without costing identity.
                let pct = g.percent ?? 0
                // Brighter than the system greens/oranges so the fill still
                // separates from a track that is now considerably darker.
                let fill = Palette.colour(pct >= 90 ? Palette.alarm : (pct >= 70 ? Palette.warn : Palette.ok))
                var trailing = g.resetsAt.map {
                    L.t(g.expired ? "m.ended" : "m.resets", Fmt.relative($0))
                }
                if trailing == nil, g.percent != nil, g.text != String(format: "%.0f%%", pct) {
                    trailing = g.text
                }
                rows.append(Panel.gauge(label: g.label, percent: g.percent,
                                        value: g.text, trailing: trailing, fill: fill,
                                        expired: g.expired))
            }
            for l in r.lines {
                rows.append(Panel.info(l, error: r.state == .failure))
            }
        }
    }
    return rows
}

func stateColour(_ s: ReadingState) -> NSColor {
    switch s {
    case .ok: return .systemGreen
    case .warn, .nearLimit: return .systemOrange
    case .failure: return .systemRed
    case .off: return .tertiaryLabelColor
    }
}

private func drawText(_ s: String, at x: CGFloat, in bounds: NSRect,
                  font: NSFont, colour: NSColor,
                  maxWidth: CGFloat? = nil, rightAlignedTo: CGFloat? = nil) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingMiddle
    let attrs: [NSAttributedString.Key: Any] =
        [.font: font, .foregroundColor: colour, .paragraphStyle: style]
    let text = NSAttributedString(string: s, attributes: attrs)
    let size = text.size()
    let y = (bounds.height - size.height) / 2
    if let right = rightAlignedTo {
        text.draw(in: NSRect(x: right - size.width, y: y, width: size.width, height: size.height))
    } else {
        text.draw(in: NSRect(x: x, y: y, width: maxWidth ?? (bounds.width - x), height: size.height))
    }
}

private final class HeaderRowView: NSView {
    var dotColour: NSColor = .systemGreen
    var title = ""
    var trailing: String?

    override var intrinsicContentSize: NSSize { NSSize(width: Panel.width, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 8
        dotColour.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: (bounds.height - d) / 2, width: d, height: d)).fill()
        drawText(title, at: Panel.leftInset, in: bounds,
             font: .systemFont(ofSize: 13, weight: .semibold), colour: Palette.text(1),
             maxWidth: 210)
        if let trailing {
            drawText(trailing, at: 0, in: bounds, font: .systemFont(ofSize: 11),
                 colour: Palette.text(0.5), rightAlignedTo: bounds.width - Panel.rightInset)
        }
    }
}

private final class GaugeRowView: NSView {
    var label = ""
    var percent: Double?
    var value = ""
    var trailing: String?
    var fill: NSColor = .systemGreen
    var expired = false

    private let barX: CGFloat = 148
    private let barW: CGFloat = 90
    private let barH: CGFloat = 5

    override var intrinsicContentSize: NSSize { NSSize(width: Panel.width, height: 19) }

    override func draw(_ dirtyRect: NSRect) {
        drawText(label, at: Panel.leftInset, in: bounds, font: .systemFont(ofSize: 12),
             colour: Palette.text(0.7), maxWidth: barX - Panel.leftInset - 8)

        if let pct = percent {
            let y = (bounds.height - barH) / 2
            // Light enough to read as "not filled", dark enough to be a shape:
            // at 0.15 the track vanished into the panel's own background.
            Palette.colour(Palette.track).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
            let w = max(pct > 0 ? 2 : 0, min(barW, barW * CGFloat(pct) / 100))
            if w > 0 {
                fill.setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: w, height: barH),
                             xRadius: barH / 2, yRadius: barH / 2).fill()
            }
            drawText(String(format: "%.0f%%", pct), at: 0, in: bounds,
                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                 colour: Palette.text(1), rightAlignedTo: 284)
            if let trailing {
                drawText(trailing, at: 292, in: bounds, font: .systemFont(ofSize: 11),
                     colour: Palette.text(0.5), maxWidth: bounds.width - 292 - Panel.rightInset)
            }
        } else if expired {
            // A window whose cycle ended after the snapshot: the track stays,
            // because this is still a window and the row should not shrink into
            // the shape used for a money balance, but nothing fills it - there
            // is no honest length to draw. The dash sits where the percentage
            // was, so the eye lands on "not known" in the column it was reading.
            let y = (bounds.height - barH) / 2
            Palette.colour(Palette.track).setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH),
                         xRadius: barH / 2, yRadius: barH / 2).fill()
            drawText(value, at: 0, in: bounds,
                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                 colour: Palette.text(0.5), rightAlignedTo: 284)
            if let trailing {
                drawText(trailing, at: 292, in: bounds, font: .systemFont(ofSize: 11),
                     colour: Palette.text(0.5), maxWidth: bounds.width - 292 - Panel.rightInset)
            }
        } else {
            // A balance, not a percentage: no bar to draw, so the figure takes
            // the whole right-hand column.
            drawText(value, at: 0, in: bounds,
                 font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                 colour: Palette.text(1), rightAlignedTo: bounds.width - Panel.rightInset)
        }
    }
}

private final class InfoRowView: NSView {
    var text = ""
    var isError = false

    override var intrinsicContentSize: NSSize { NSSize(width: Panel.width, height: 17) }

    override func draw(_ dirtyRect: NSRect) {
        drawText(text, at: Panel.leftInset, in: bounds, font: .systemFont(ofSize: 11),
             colour: isError ? Palette.colour(Palette.alarm) : Palette.text(0.7),
             maxWidth: bounds.width - Panel.leftInset - Panel.rightInset)
    }
}
