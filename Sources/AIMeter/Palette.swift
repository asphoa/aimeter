import AppKit

/// Every colour the app draws, in one place, each overridable by the user.
///
/// An unset role resolves to a semantic default (`labelColor` and friends) that
/// follows light and dark mode. An overridden role is a fixed sRGB value and
/// does not — that trade is the user's to make, and the Colours panel says so.
enum Palette {
    /// Set from the config at launch and whenever the user changes a colour.
    nonisolated(unsafe) static var overrides: [String: String] = [:]

    // Role names, also the config keys.
    static let text = "text"
    static let track = "track"
    static let alarm = "alarm"
    static let ok = "ok"
    static let warn = "warn"
    /// Each service has two colours, one per window. They are separate roles
    /// rather than one colour plus a derivation, because a derived shade is not
    /// something the user can choose.
    static func service(_ id: String, _ kind: GaugeKind) -> String {
        "service." + id + (kind == .shortWindow ? ".5h" : ".week")
    }

    static let serviceRoles = ["claude", "codex", "agy", "openrouter", "deepseek", "local", "generic"]

    /// Base hues, cool side of the wheel so red and orange mean one thing only.
    /// The weekly default is the base lightened; both are overridable.
    private static let bases: [String: NSColor] = [
        "claude":     NSColor(srgbRed: 0.898, green: 0.600, blue: 0.239, alpha: 1),
        "codex":      NSColor(srgbRed: 0.184, green: 0.651, blue: 0.353, alpha: 1),
        "agy":        NSColor(srgbRed: 0.243, green: 0.769, blue: 0.918, alpha: 1),
        "openrouter": NSColor(srgbRed: 0.643, green: 0.420, blue: 0.925, alpha: 1),
        "deepseek":   NSColor(srgbRed: 0.878, green: 0.380, blue: 0.620, alpha: 1),
        "local":      NSColor(srgbRed: 0.639, green: 0.639, blue: 0.337, alpha: 1),
        "generic":    NSColor(srgbRed: 0.659, green: 0.608, blue: 0.545, alpha: 1)
    ]

    private static var defaults: [String: NSColor] {
        var out: [String: NSColor] = [
            alarm: NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1),
            ok:    NSColor(srgbRed: 0.196, green: 0.843, blue: 0.294, alpha: 1),
            warn:  NSColor(srgbRed: 1.0, green: 0.702, blue: 0.251, alpha: 1)
        ]
        for (id, base) in bases {
            out["service." + id + ".5h"] = base
            out["service." + id + ".week"] = blend(base, toward: .white, 0.35)
        }
        return out
    }

    private static func blend(_ a: NSColor, toward b: NSColor, _ t: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: x.redComponent * (1 - t) + y.redComponent * t,
                       green: x.greenComponent * (1 - t) + y.greenComponent * t,
                       blue: x.blueComponent * (1 - t) + y.blueComponent * t,
                       alpha: 1)
    }

    /// The colour for a role, honouring an override.
    static func colour(_ role: String) -> NSColor {
        if let hex = overrides[role], let c = NSColor(hex: hex) { return c }
        if let d = defaults[role] { return d }
        switch role {
        case text:  return .labelColor
        case track: return .labelColor.withAlphaComponent(0.30)
        default:    return .labelColor
        }
    }

    /// Text at a lower emphasis. Derived from the text colour so a custom text
    /// colour keeps its hierarchy instead of clashing with a fixed grey.
    static func text(_ emphasis: CGFloat) -> NSColor {
        if overrides[text] != nil { return colour(text).withAlphaComponent(emphasis) }
        switch emphasis {
        case 1: return .labelColor
        case 0.7: return .secondaryLabelColor
        default: return .tertiaryLabelColor
        }
    }

    /// Whether a role has been overridden, for the reset button and the pickers.
    static func isCustom(_ role: String) -> Bool { overrides[role] != nil }

    static func defaultColour(_ role: String) -> NSColor {
        defaults[role] ?? (role == track ? NSColor.labelColor.withAlphaComponent(0.30) : .labelColor)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let f = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X",
                      f(c.redComponent), f(c.greenComponent), f(c.blueComponent), f(c.alphaComponent))
    }
}
