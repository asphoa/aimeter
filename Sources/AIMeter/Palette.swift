import AppKit

/// Every colour the app draws, in one place, each overridable by the user.
///
/// An unset role resolves to a semantic default (`labelColor` and friends) that
/// follows light and dark mode. An overridden role is a fixed sRGB value and
/// does not — that trade is the user's to make, and the Colours panel says so.
enum Palette {
    /// Set from the config at launch and whenever the user changes a colour.
    nonisolated(unsafe) static var overrides: [String: String] = [:]

    /// Where the adaptive strip scheme's hue circle starts. Set alongside
    /// `overrides` everywhere that reads from config, so a reroll from the
    /// Accounts window's "Optimize colours" button is visible immediately.
    nonisolated(unsafe) static var adaptiveHueOffset: Double = 218

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

    /// The ground the panel's marks are drawn against.
    ///
    /// A menu is not a window: it is translucent, and on macOS 26 the desktop
    /// behind it shows through plainly. Every semi-transparent mark drawn into
    /// one therefore picks up whatever happens to be back there. Resolved at
    /// draw time, inside the menu's own appearance, so it follows light/dark.
    private static var ground: NSColor {
        NSColor.windowBackgroundColor
    }

    /// A lower emphasis as an *opaque* colour: the tone alpha would have given,
    /// mixed against the panel's ground here rather than against the desktop.
    ///
    /// This is the whole fix for a class of bug that only ever appeared in the
    /// live menu. A 25%-alpha timestamp over a menu is not grey text, it is a
    /// window onto the wallpaper; a 30%-alpha gauge track lets a coloured blob
    /// sit *inside* the bar looking exactly like a reading. Mixing to an opaque
    /// value keeps the intended tone and makes each mark self-contained.
    private static func opaque(_ c: NSColor, _ emphasis: CGFloat) -> NSColor {
        let flat = blend(c, toward: ground, 1 - (c.usingColorSpace(.sRGB)?.alphaComponent ?? 1))
        guard emphasis < 1 else { return flat }
        // Held back from the full distance. The emphasis levels were picked
        // against the opaque white the offscreen render puts behind a row —
        // a backdrop the live menu never has. Against a real one, with the
        // desktop showing through around the glyphs, the faintest tier was
        // being read as absent. Weight is what a lower tier can afford to
        // spend here; disappearing is not.
        return blend(flat, toward: ground, (1 - emphasis) * 0.72)
    }

    /// The colour for a role, honouring an override.
    static func colour(_ role: String) -> NSColor {
        if let hex = overrides[role], let c = NSColor(hex: hex) { return c }
        if let d = defaults[role] { return d }
        switch role {
        case text:  return .labelColor
        case track: return opaque(.labelColor, 0.28)
        default:    return .labelColor
        }
    }

    /// Text at a lower emphasis. Derived from the text colour so a custom text
    /// colour keeps its hierarchy instead of clashing with a fixed grey.
    ///
    /// Opaque, not alpha-blended: see `opaque(_:_:)`. The system's own
    /// `secondaryLabelColor` and `tertiaryLabelColor` are alpha, which is why
    /// they were the ones that dissolved into the wallpaper.
    static func text(_ emphasis: CGFloat) -> NSColor {
        opaque(colour(text), emphasis)
    }

    /// Whether a role has been overridden, for the reset button and the pickers.
    static func isCustom(_ role: String) -> Bool { overrides[role] != nil }

    static func defaultColour(_ role: String) -> NSColor {
        defaults[role] ?? (role == track ? opaque(.labelColor, 0.28) : .labelColor)
    }

    /// Converts perceptually-uniform OKLCH directly to opaque sRGB.  Values
    /// outside the display's gamut are gently reduced in chroma instead of
    /// clipped channel-by-channel, which would change the hue and defeat the
    /// spacing the adaptive strip just calculated.
    static func oklch(_ l: Double, _ c: Double, _ hueDegrees: Double) -> NSColor {
        let h = hueDegrees * .pi / 180
        var chroma = c
        for _ in 0..<12 {
            let a = chroma * cos(h), b = chroma * sin(h)
            let l1 = l + 0.3963377774 * a + 0.2158037573 * b
            let m1 = l - 0.1055613458 * a - 0.0638541728 * b
            let s1 = l - 0.0894841775 * a - 1.2914855480 * b
            let l3 = l1 * l1 * l1, m3 = m1 * m1 * m1, s3 = s1 * s1 * s1
            let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
            let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
            let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
            func srgb(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            let rgb = (srgb(r), srgb(g), srgb(bl))
            if rgb.0 >= 0, rgb.0 <= 1, rgb.1 >= 0, rgb.1 <= 1, rgb.2 >= 0, rgb.2 <= 1 {
                return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            }
            chroma *= 0.88
        }
        return NSColor(white: CGFloat(max(0, min(1, l))), alpha: 1)
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
