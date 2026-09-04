import AppKit

enum Palette {
    nonisolated(unsafe) static var overrides: [String: String] = [:]

    static let ink = "ink"
    static let track = "track"
    static let warn = "warn"
    static let alarm = "alarm"
    static let ok = "ok"
    static let accent = "accent"

    private static let serviceDefaults: [String: NSColor] = [
        "claude":     NSColor(srgbRed: 0.898, green: 0.600, blue: 0.239, alpha: 1),
        "codex":      NSColor(srgbRed: 0.184, green: 0.651, blue: 0.353, alpha: 1),
        "agy":        NSColor(srgbRed: 0.243, green: 0.769, blue: 0.918, alpha: 1),
        "openrouter": NSColor(srgbRed: 0.643, green: 0.420, blue: 0.925, alpha: 1),
        "deepseek":   NSColor(srgbRed: 0.878, green: 0.380, blue: 0.620, alpha: 1),
        "local":      NSColor(srgbRed: 0.639, green: 0.639, blue: 0.337, alpha: 1),
        "cursor":     NSColor(srgbRed: 0.184, green: 0.573, blue: 0.780, alpha: 1)
    ]

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static var defaults: [String: NSColor] {
        [
            ink: .labelColor,
            track: blend(.labelColor, toward: ground, 0.86),
            warn: dynamic(light: NSColor(hex: "#B87400")!, dark: NSColor(hex: "#E8B04A")!),
            alarm: dynamic(light: NSColor(hex: "#D94B3B")!, dark: NSColor(hex: "#F0705F")!),
            ok: dynamic(light: NSColor(hex: "#2E9560")!, dark: NSColor(hex: "#4FC98A")!),
            accent: .controlAccentColor
        ]
    }

    static var ground: NSColor { .windowBackgroundColor }

    static func blend(_ a: NSColor, toward b: NSColor, _ amount: CGFloat) -> NSColor {
        guard let x = a.usingColorSpace(.sRGB), let y = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(srgbRed: x.redComponent * (1 - amount) + y.redComponent * amount,
                       green: x.greenComponent * (1 - amount) + y.greenComponent * amount,
                       blue: x.blueComponent * (1 - amount) + y.blueComponent * amount,
                       alpha: 1)
    }

    private static func opaque(_ colour: NSColor, _ emphasis: CGFloat) -> NSColor {
        let alpha = colour.usingColorSpace(.sRGB)?.alphaComponent ?? 1
        let flat = blend(colour, toward: ground, 1 - alpha)
        guard emphasis < 1 else { return flat }
        return blend(flat, toward: ground, (1 - emphasis) * 0.72)
    }

    static func colour(_ role: String) -> NSColor {
        if let hex = overrides[role], let custom = NSColor(hex: hex) { return custom }
        if role.hasPrefix("service.") {
            return serviceColour(String(role.dropFirst("service.".count)))
        }
        return defaults[role] ?? .labelColor
    }

    static func serviceColour(_ id: String) -> NSColor {
        let role = "service." + id
        if let hex = overrides[role], let custom = NSColor(hex: hex) { return custom }
        return serviceDefaults[id] ?? NSColor(hex: "#8A8A8F")!
    }

    static func text(_ emphasis: CGFloat) -> NSColor {
        opaque(colour(ink), emphasis)
    }

    static func isCustom(_ role: String) -> Bool { overrides[role] != nil }

    static func defaultColour(_ role: String) -> NSColor {
        if role.hasPrefix("service.") {
            return serviceDefaults[String(role.dropFirst("service.".count))]
                ?? NSColor(hex: "#8A8A8F")!
        }
        return defaults[role] ?? .labelColor
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8,
              let number = UInt64(value, radix: 16) else { return nil }
        let hasAlpha = value.count == 8
        let red = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var hexString: String {
        guard let colour = usingColorSpace(.sRGB) else { return "#000000" }
        let component = { (value: CGFloat) in Int((max(0, min(1, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X",
                      component(colour.redComponent), component(colour.greenComponent),
                      component(colour.blueComponent), component(colour.alphaComponent))
    }
}
