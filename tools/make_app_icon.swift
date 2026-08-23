// make_app_icon.swift — draws AIMeter's application icon entirely in code and
// packs it into AppIcon.icns. No external assets: every pixel comes from the
// CoreGraphics calls below, matching the project's no-bundled-assets rule.
//
// Build & run (swiftc directly; `swift build` would start SwiftPM's own
// sandbox, which cannot nest — same reason as build.sh):
//   swiftc -O -o .build/make_app_icon tools/make_app_icon.swift
//   .build/make_app_icon .build/AppIcon.icns [--preview <dir>]
//
// Note: the drawing itself runs anywhere, but the final iconutil step talks to
// an XPC service and fails inside the Claude Code sandbox ("Failed to generate
// ICNS", verified 260824) — run this outside the sandbox, same as codesign.
//
// Design: the Finder icon is the menu-bar strip grown up. Three capsule bars
// on a graphite panel, service hues taken verbatim from Palette.swift
// (claude amber, codex green, agy cyan), each bar showing a different level so
// the staircase silhouette reads as "a meter" even at 16 px. At 128 pt and up
// each bar splits into the two window halves (base hue above, the same hue
// lightened 35% below) exactly as StatusStrip does. Red is absent by design:
// in AIMeter red means "nearly spent", and the icon must not cry wolf.
//
// The artwork is full-bleed: macOS 26 masks square art into its squircle and
// adds the glass edge itself; art that does not fill the canvas is put on the
// grey backing plate instead. (On macOS 14/15 the same icns shows as a sharp
// square — acceptable; this app's own machine runs 26.)

import CoreGraphics
import Foundation
import ImageIO

// MARK: palette (verbatim from Sources/AIMeter/Palette.swift)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    func cg(_ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [r, g, b, a])!
    }
    func lightened(_ t: CGFloat) -> RGB {
        RGB(r: r + (1 - r) * t, g: g + (1 - g) * t, b: b + (1 - b) * t)
    }
}

let claude = RGB(r: 0.898, g: 0.600, b: 0.239)
let codex  = RGB(r: 0.184, g: 0.651, b: 0.353)
let agy    = RGB(r: 0.243, g: 0.769, b: 0.918)

let bgTop    = RGB(r: 0.145, g: 0.165, b: 0.196)
let bgBottom = RGB(r: 0.075, g: 0.090, b: 0.110)

struct Bar {
    let hue: RGB
    let topFill: CGFloat
    let bottomFill: CGFloat
    var merged: CGFloat { (topFill + bottomFill) / 2 }
}

// Levels chosen so the silhouette is a clean descending staircase.
let bars = [
    Bar(hue: claude, topFill: 0.82, bottomFill: 0.66),
    Bar(hue: codex,  topFill: 0.55, bottomFill: 0.47),
    Bar(hue: agy,    topFill: 0.30, bottomFill: 0.24),
]

// MARK: drawing

/// A bar segment. Radius scales down at small sizes: full capsule at 128 pt
/// and up, a gentle rounding at 32 pt, and at 16 px a plain unantialiased
/// rectangle — at that size a crisp pixel beats a soft curve.
func segment(_ ctx: CGContext, _ rect: CGRect, _ colour: CGColor, radius: CGFloat) {
    guard rect.width > 0.5, rect.height > 0.5 else { return }
    ctx.setFillColor(colour)
    if radius < 0.75 {
        ctx.setAllowsAntialiasing(false)
        ctx.fill(rect)
        ctx.setAllowsAntialiasing(true)
        return
    }
    let r = min(radius, min(rect.height, rect.width) / 2)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.fillPath()
}

/// Draws one icon. `pt` picks the design tier (16/32 keep merged bars, 128+
/// split into the two window halves); `px` is the actual bitmap size.
func draw(pt: Int, px: Int, into ctx: CGContext) {
    let S = CGFloat(px)

    // Graphite panel, faint vertical gradient. Full bleed on purpose.
    let grad = CGGradient(colorsSpace: srgb,
                          colors: [bgTop.cg(), bgBottom.cg()] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

    // Content box: the centre ~62% of the canvas, clear of the squircle mask.
    // At 16 px this resolves to the integer box (3,3)-(13,13).
    let inset = (S * 0.1875).rounded()
    let content = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)

    let n = CGFloat(bars.count)
    var barH = (content.height * 0.26).rounded()
    var gap = (content.height - n * barH) / (n - 1)
    if pt <= 32 {
        gap = gap.rounded()
        barH = ((content.height - (n - 1) * gap) / n).rounded(.down)
    }

    let track = CGColor(colorSpace: srgb, components: [1, 1, 1, 0.13])!

    for (i, bar) in bars.enumerated() {
        // CG origin is bottom-left; lay bars out top to bottom.
        let yTop = content.maxY - CGFloat(i) * (barH + gap)
        let rect = CGRect(x: content.minX, y: yTop - barH, width: content.width, height: barH)

        if pt >= 128 {
            // Split into the two window halves, like StatusStrip.
            let halfGap = (S / 100).rounded()
            let halfH = (barH - halfGap) / 2
            let top = CGRect(x: rect.minX, y: rect.maxY - halfH, width: rect.width, height: halfH)
            let bot = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfH)
            segment(ctx, top, track, radius: halfH / 2)
            segment(ctx, bot, track, radius: halfH / 2)
            segment(ctx, CGRect(x: top.minX, y: top.minY,
                                width: max(top.width * bar.topFill, halfH * 1.6), height: halfH),
                    bar.hue.cg(), radius: halfH / 2)
            segment(ctx, CGRect(x: bot.minX, y: bot.minY,
                                width: max(bot.width * bar.bottomFill, halfH * 1.6), height: halfH),
                    bar.hue.lightened(0.35).cg(), radius: halfH / 2)
        } else {
            // Merged bar, integer-aligned so nothing lands between pixels.
            // Radius 0 below 24 px (plain rect), gentle rounding above; a fill
            // never shrinks below 1.6 bar heights so a low reading stays a
            // short bar rather than collapsing into a dot.
            let radius: CGFloat = px < 24 ? 0 : (barH * 0.3).rounded()
            let w = max((rect.width * bar.merged).rounded(), (barH * 1.6).rounded())
            segment(ctx, rect, track, radius: radius)
            segment(ctx, CGRect(x: rect.minX, y: rect.minY, width: w, height: barH),
                    bar.hue.cg(), radius: radius)
        }
    }
}

func render(pt: Int, px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    draw(pt: pt, px: px, into: ctx)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed: \(url.path)") }
}

/// Nearest-neighbour enlargement, for checking small sizes pixel by pixel.
func zoom(_ img: CGImage, by k: Int) -> CGImage {
    let w = img.width * k, h = img.height * k
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// The icon squircle-masked and set on a light or dark Finder-like swatch —
/// an approximation of macOS 26's treatment, for judging contrast only.
func swatch(_ img: CGImage, light: Bool) -> CGImage {
    let S = img.width, pad = S / 4, W = S + 2 * pad
    let ctx = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let bg: CGFloat = light ? 0.96 : 0.11
    ctx.setFillColor(CGColor(colorSpace: srgb, components: [bg, bg, bg, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
    let iconRect = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: CGFloat(S), height: CGFloat(S))
    let r = CGFloat(S) * 0.225   // approximate Tahoe squircle radius
    ctx.addPath(CGPath(roundedRect: iconRect, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(img, in: iconRect)
    return ctx.makeImage()!
}

// MARK: main

let args = CommandLine.arguments
let outIcns = URL(fileURLWithPath: args.count > 1 && !args[1].hasPrefix("--") ? args[1]
                                                                              : ".build/AppIcon.icns")
var previewDir: URL? = nil
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    previewDir = URL(fileURLWithPath: args[i + 1])
}

let fm = FileManager.default
let iconset = outIcns.deletingLastPathComponent().appendingPathComponent("AIMeter.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (pt, scale) pairs iconutil requires. The @2x member of a pair keeps the
// design tier of its point size: a retina 16 pt icon is still a 16 pt icon.
let members: [(pt: Int, scale: Int)] =
    [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
     (256, 1), (256, 2), (512, 1), (512, 2)]
for m in members {
    let img = render(pt: m.pt, px: m.pt * m.scale)
    let name = "icon_\(m.pt)x\(m.pt)" + (m.scale == 2 ? "@2x" : "") + ".png"
    writePNG(img, iconset.appendingPathComponent(name))
}

let icu = Process()
icu.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icu.arguments = ["-c", "icns", iconset.path, "-o", outIcns.path]
try icu.run()
icu.waitUntilExit()
guard icu.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(outIcns.path)")

if let dir = previewDir {
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for (pt, k) in [(16, 16), (32, 8), (128, 4), (512, 1)] {
        let img = render(pt: pt, px: pt)
        writePNG(img, dir.appendingPathComponent("icon_\(pt).png"))
        if k > 1 {
            writePNG(zoom(img, by: k), dir.appendingPathComponent("icon_\(pt)_zoom\(k)x.png"))
        }
    }
    let big = render(pt: 512, px: 512)
    writePNG(swatch(big, light: true), dir.appendingPathComponent("finder_light_512.png"))
    writePNG(swatch(big, light: false), dir.appendingPathComponent("finder_dark_512.png"))
    let small = render(pt: 16, px: 32)   // 16 pt @2x, as Finder list view shows it
    writePNG(zoom(small, by: 8), dir.appendingPathComponent("icon_16at2x_zoom8x.png"))
    print("previews in \(dir.path)")
}
