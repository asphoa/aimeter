import AppKit
import SwiftUI

/// A deterministic, credential-free rendering fixture.  It is intentionally
/// opt-in (`--demo-high`) and only used by the diagnostic render flags, so a
/// visual regression check can reproduce five simultaneous near-limit rows
/// without touching a person's config or making a provider request.
func highUsageDemo(_ cfg: inout Config) -> [String: [Reading]] {
    let ids = ["claude", "codex", "agy", "openrouter", "deepseek"]
    cfg.menuBar.lines = ids.map { MenuLine(provider: $0) }
    return Dictionary(uniqueKeysWithValues: ids.map { id in
        let title = ProviderKind.find(id)?.title ?? id
        var r = Reading(id: id, title: title)
        r.gauges = [
            Gauge(label: L.t("g.5h"), percent: 96, text: "96%", resetsAt: Date().addingTimeInterval(3600), kind: .shortWindow),
            Gauge(label: L.t("g.week"), percent: 93, text: "93%", resetsAt: Date().addingTimeInterval(86_400), kind: .longWindow)
        ]
        r.state = .nearLimit
        return (id, [r])
    })
}

/// The reported shape, as distinct from the five-line high-usage stress case:
/// one Claude row with a little-used five-hour window and a nearly-spent week.
/// It is also credential-free and is solely for visual regression checks.
func contrastUsageDemo(_ cfg: inout Config) -> [String: [Reading]] {
    cfg.menuBar.lines = [MenuLine(provider: "claude")]
    var reading = Reading(id: "claude", title: ProviderKind.find("claude")?.title ?? "Claude")
    reading.gauges = [
        Gauge(label: L.t("g.5h"), percent: 19, text: "19%", resetsAt: Date().addingTimeInterval(3600), kind: .shortWindow),
        Gauge(label: L.t("g.week"), percent: 97, text: "97%", resetsAt: Date().addingTimeInterval(86_400), kind: .longWindow),
        Gauge(label: L.t("g.week.model", "Fable"), percent: 9, text: "9%",
              resetsAt: Date().addingTimeInterval(86_400), kind: .modelWindow)
    ]
    reading.state = .nearLimit
    return ["claude": [reading]]
}

/// A snapshot with a five-hour window that has ended and a still-current
/// weekly window. This is the shape a local Codex snapshot reaches between
/// refreshes, and keeps the strip's handling reproducible without waiting for
/// a particular real reset time.
func expiredWindowDemo(_ cfg: inout Config) -> [String: [Reading]] {
    cfg.menuBar.lines = [MenuLine(provider: "codex")]
    var reading = Reading(id: "codex", title: ProviderKind.find("codex")?.title ?? "Codex")
    reading.snapshotAt = Date().addingTimeInterval(-7_200)
    reading.gauges = [
        Gauge(label: L.t("g.5h"), percent: 58, text: "58%",
              resetsAt: Date().addingTimeInterval(-1_800), kind: .shortWindow),
        Gauge(label: L.t("g.week"), percent: 41, text: "41%",
              resetsAt: Date().addingTimeInterval(86_400), kind: .longWindow)
    ]
    return ["codex": [reading]]
}

func diagnosticDemo(_ cfg: inout Config) -> [String: [Reading]]? {
    if CommandLine.arguments.contains("--demo-expired") { return expiredWindowDemo(&cfg) }
    if CommandLine.arguments.contains("--demo-contrast") { return contrastUsageDemo(&cfg) }
    if CommandLine.arguments.contains("--demo-notice") { return noticeUsageDemo(&cfg) }
    if CommandLine.arguments.contains("--demo-high") { return highUsageDemo(&cfg) }
    return nil
}

/// Claude card with a 429 rate-limit notice under the hero gauge.
func noticeUsageDemo(_ cfg: inout Config) -> [String: [Reading]] {
    cfg.menuBar.lines = [MenuLine(provider: "claude")]
    cfg.menuBar.expanded = ["claude"]
    var reading = Reading(id: "claude", title: ProviderKind.find("claude")?.title ?? "Claude")
    let now = Date()
    reading.gauges = [
        Gauge(label: L.t("g.5h"), percent: 42, text: "42%",
              resetsAt: now.addingTimeInterval(3600), kind: .shortWindow,
              observedAt: now.addingTimeInterval(-300), source: "api"),
        Gauge(label: L.t("g.week"), percent: 18, text: "18%",
              resetsAt: now.addingTimeInterval(86_400), kind: .longWindow,
              observedAt: now.addingTimeInterval(-300), source: "api")
    ]
    reading.lines = [L.t("c.ratelimited", Fmt.relative(now.addingTimeInterval(300)))]
    reading.state = .warn
    reading.snapshotAt = now.addingTimeInterval(-300)
    return ["claude": [reading]]
}

func applyExpandedArgument(to cfg: inout Config) {
    guard let index = CommandLine.arguments.firstIndex(of: "--expanded"),
          CommandLine.arguments.count > index + 1 else { return }
    cfg.menuBar.expanded = CommandLine.arguments[index + 1]
        .split(separator: ",").map(String.init).filter { !$0.isEmpty }
}

/// Bridges the screen-capture worker back to AppKit's main queue without
/// capturing NSMenu directly in a Sendable closure.
private final class MenuCanceller: @unchecked Sendable {
    weak var menu: NSMenu?
    init(_ menu: NSMenu) { self.menu = menu }
    func cancel() { DispatchQueue.main.async { self.menu?.cancelTracking() } }
}

/// Renders one NSImage into a PNG at `scale`, optionally forcing a light or
/// dark `NSAppearance` around the draw (`--icon`'s light/dark backgrounds) and
/// a solid background colour behind it.
func writePNG(_ image: NSImage, scale: CGFloat, background: NSColor?,
              appearance: NSAppearance?, to path: String) {
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    func draw() {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        if let background {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    if let appearance {
        appearance.performAsCurrentDrawingAppearance { draw() }
    } else {
        draw()
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// `AIMeter --icon out` renders the ring icon at 4x on a light and a dark
/// menu-bar background (`out-light.png` / `out-dark.png`) plus a labelled row
/// of the six named states (`out-states.png`), so the icon can be inspected as
/// an artefact instead of squinted at in the bar.
///
/// Deliberately not @MainActor: nothing here is main-actor isolated, and
/// hopping to the main actor while the main thread waits on the semaphore
/// below would deadlock.
func renderIcon(to path: String) async {
    var cfg = Config.load().config
    L.current = cfg.language
    var readings: [String: [Reading]] = [:]
    if let demo = diagnosticDemo(&cfg) {
        readings = demo
    } else {
        for p in buildProviders(cfg) { readings[p.id] = await p.fetchAll() }
    }
    let model = RingIcon.model(readings: readings, primary: cfg.menuBar.primary, style: cfg.menuBar.style)
    let ring = RingIcon.image(for: model)
    let base = (path as NSString).deletingPathExtension.isEmpty ? path : (path as NSString).deletingPathExtension

    let light = NSAppearance(named: .aqua)
    let dark = NSAppearance(named: .darkAqua)
    writePNG(ring, scale: 4, background: NSColor.white, appearance: light, to: base + "-light.png")
    writePNG(ring, scale: 4, background: NSColor.black, appearance: dark, to: base + "-dark.png")
    writePNG(ring, scale: 4,
             background: NSColor(srgbRed: 0.12, green: 0.42, blue: 0.86, alpha: 1),
             appearance: light, to: base + "-blue.png")
    writePNG(ring, scale: 4,
             background: NSColor(srgbRed: 0.04, green: 0.36, blue: 0.82, alpha: 1),
             appearance: dark, to: base + "-selected.png")

    // Six named states, credential-free, laid out left to right on one canvas.
    func gauge(_ pct: Double, kind: GaugeKind) -> Gauge {
        Gauge(label: "", percent: pct, text: "\(Int(pct))%", kind: kind)
    }
    var claude = Reading(id: "claude", title: "Claude")
    claude.gauges = [gauge(53, kind: .shortWindow), gauge(11, kind: .longWindow)]
    var warnR = Reading(id: "claude", title: "Claude")
    warnR.gauges = [gauge(76, kind: .shortWindow), gauge(11, kind: .longWindow)]
    var alarmR = Reading(id: "claude", title: "Claude")
    alarmR.gauges = [gauge(93, kind: .shortWindow), gauge(40, kind: .longWindow)]
    var codexHigh = Reading(id: "codex", title: "Codex")
    codexHigh.gauges = [gauge(80, kind: .shortWindow)]
    codexHigh.state = .warn

    let states: [(String, RingIcon.RingModel)] = [
        ("53% / 11%", RingIcon.model(readings: ["claude": [claude]], primary: "claude")),
        ("warn 76% / 11%", RingIcon.model(readings: ["claude": [warnR]], primary: "claude")),
        ("alarm 93% / 40%", RingIcon.model(readings: ["claude": [alarmR]], primary: "claude")),
        ("+ alert dot", RingIcon.model(readings: ["claude": [claude], "codex": [codexHigh]], primary: "claude")),
        ("ring + numeral", RingIcon.model(readings: ["claude": [claude]], primary: "claude", style: "ringNumeral")),
        ("no data", RingIcon.RingModel())
    ]
    let scale: CGFloat = 4
    let cellW = RingIcon.canvas * scale + RingIcon.numeralWidth * scale + 40
    let cellH = RingIcon.canvas * scale + 40
    let sheetSize = NSSize(width: cellW * CGFloat(states.count), height: cellH)
    let sheet = NSImage(size: sheetSize, flipped: false) { _ in
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheetSize).fill()
        for (i, entry) in states.enumerated() {
            let (label, model) = entry
            let img = RingIcon.image(for: model)
            let x = CGFloat(i) * cellW + 20
            img.draw(in: NSRect(x: x, y: 30, width: img.size.width * scale, height: img.size.height * scale))
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                          .foregroundColor: NSColor.black]
            NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: x, y: 8))
        }
        return true
    }
    writePNG(sheet, scale: 1, background: nil, appearance: light, to: base + "-states.png")

    let f = { (v: Double?) in v.map { String(format: "%.0f%%", $0) } ?? "—" }
    print("  ring outer \(f(model.outer)) inner \(f(model.inner)) dot \(model.alertDot) numeral \(model.numeral ?? "—")")
}

/// `AIMeter --panel out.png` renders the card panel offscreen (v1.0.27):
/// the same `PanelView` an open panel would show, in an `NSHostingView` at
/// 372pt width. Writes `out.png` for light and `out-dark.png` for dark -
/// AppKit's behaviour for a view nobody ever put on screen is not something
/// to take on trust, and a PNG is cheaper to check than asking someone to
/// open the panel and describe what they see.
@MainActor
func renderPanelState(_ state: PanelState, to path: String) {
    state.screenLimit = 4000
    var measuredHeight: CGFloat?
    state.onContentHeight = { measuredHeight = $0 }
    let hosting = NSHostingView(rootView: PanelView(state: state, opaqueBackground: true))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 4000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    // One turn of the runloop so SwiftUI completes its first layout pass -
    // the same technique the --about renderer relies on.
    let deadline = Date().addingTimeInterval(0.4)
    while measuredHeight == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    hosting.layoutSubtreeIfNeeded()
    let height = measuredHeight ?? 120
    window.setContentSize(NSSize(width: 372, height: height))
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    hosting.layoutSubtreeIfNeeded()

    let base = (path as NSString).deletingPathExtension
    let ext = (path as NSString).pathExtension.isEmpty ? "png" : (path as NSString).pathExtension

    func snapshot(_ appearance: NSAppearance, to outPath: String) {
        hosting.appearance = appearance
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: outPath))
            print("wrote \(outPath)  (\(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) pt)")
        }
    }
    snapshot(NSAppearance(named: .aqua)!, to: path)
    snapshot(NSAppearance(named: .darkAqua)!, to: "\(base)-dark.\(ext)")
}

@MainActor
func renderPanelDemo(to path: String, page: SettingsPage? = nil) {
    var cfg = Config.load().config
    applyExpandedArgument(to: &cfg)
    L.current = cfg.language
    Palette.overrides = cfg.colours
    guard let readings = diagnosticDemo(&cfg) else { return }
    let state = PanelState()
    state.model = PanelModelBuilder.build(readings: readings, cfg: cfg)
    // Credential-free fixture: the trend stays empty rather than reading this
    // machine's real usage ledger, so the render is deterministic.
    state.lastRefresh = Date()
    state.refreshIntervalSeconds = cfg.interval(cfg.menuBar.primary)
    state.language = cfg.language
    state.animate = false
    setPanelPage(page, on: state)
    renderPanelState(state, to: path)
}

@MainActor
func renderPanel(to path: String, page: SettingsPage? = nil) async {
    var cfg = Config.load().config
    applyExpandedArgument(to: &cfg)
    L.current = cfg.language
    Palette.overrides = cfg.colours
    if page != nil {
        let state = PanelState(store: SettingsStore(config: cfg))
        state.language = cfg.language
        state.refreshIntervalSeconds = cfg.refreshSeconds
        state.animate = false
        setPanelPage(page, on: state)
        renderPanelState(state, to: path)
        return
    }
    if diagnosticDemo(&cfg) != nil {
        renderPanelDemo(to: path, page: page)
        return
    }
    let providers = buildProviders(cfg)
    var readings: [String: [Reading]] = [:]
    for provider in providers { readings[provider.id] = await provider.fetchAll() }

    let state = PanelState()
    var model = PanelModelBuilder.build(readings: readings, cfg: cfg)
    for index in model.cards.indices where model.cards[index].expanded {
        guard let hero = model.cards[index].hero else { continue }
        let account = hero.account ?? ""
        let gaugeId = Parse.gaugeId(label: hero.label, kind: hero.kind)
        let segments = Sparkline.recentSamples(historyDir: Config.dir + "/history",
                                               provider: model.cards[index].id,
                                               account: account, gaugeId: gaugeId,
                                               refreshInterval: cfg.interval(model.cards[index].id))
        let flat = Sparkline.flatten(segments)
        if flat.count >= 2 {
            model.cards[index].sparkline = flat.map {
                PanelModel.SparkPoint(date: $0.date, value: $0.value)
            }
        }
    }
    state.model = model
    state.lastRefresh = Date()
    state.refreshIntervalSeconds = cfg.interval(cfg.menuBar.primary)
    state.language = cfg.language
    state.animate = false   // a still image has nothing to sweep from
    setPanelPage(page, on: state)
    renderPanelState(state, to: path)
}

@MainActor
func setPanelPage(_ page: SettingsPage?, on state: PanelState) {
    guard let page else { return }
    switch page {
    case .root: state.nav.stack = [.root]
    case .services: state.nav.stack = [.root, .services]
    case .catalogue: state.nav.stack = [.root, .services, .catalogue]
    case .add(let kind):
        state.builtinDraft = AddDraft(providerID: kind)
        state.nav.stack = [.root, .services, .catalogue, .add(kind: kind)]
    case .custom:
        if state.draft == nil { state.draft = RecipeDraft() }
        if CommandLine.arguments.contains("--demo-tested") {
            var draft = state.draft!
            draft.id = "typhoon"; draft.name = "Typhoon"; draft.baseURL = "https://api.opentyphoon.ai"
            var reading = Reading(id: "typhoon", title: "Typhoon")
            reading.gauges = [Gauge(label: "Balance", percent: nil, text: "$12.40", resetsAt: nil)]
            draft.tested = RecipeTestResult(reading: reading,
                meta: RecipeFetchMeta(request: "GET https://api.opentyphoon.ai/v1/credits",
                                      status: 200, bytes: 84, elapsed: 0.184,
                                      contentType: "application/json", snapshotAt: nil),
                rawPreview: #"{"credits":12.4,"renews_at":"2026-09-06T00:00:00Z"}"#,
                suggestions: ["renews_at"])
            state.draft = draft
        }
        state.nav.stack = [.root, .services, .catalogue, .custom]
    case .menuBar: state.nav.stack = [.root, .menuBar]
    case .general: state.nav.stack = [.root, .general]
    case .history: state.nav.stack = [.root, .history]
    }
}

/// `AIMeter --menushot out.png` opens the real dropdown — a genuine `NSMenu`,
/// tracked by AppKit — and photographs it with the pointer resting at a series
/// of depths down the first section.
///
/// `--panel` cannot answer questions about highlighting, material or any other
/// thing AppKit draws *behind* a row: it renders the row views into a bare
/// container, and a view outside a menu is never tracked. This flag is the only
/// way to see what the user sees. It needs Screen Recording permission, and it
/// moves the pointer, so it is a diagnostic to run deliberately rather than
/// part of any routine check.
@MainActor
func renderMenuShots(to path: String) async {
    var cfg = Config.load().config
    L.current = cfg.language
    Palette.overrides = cfg.colours
    // The default front-end (v1.0.27) is the floating card panel, which is
    // not an NSMenu at all - there is nothing here for this flag's
    // mouse-warp-and-screencapture technique to track. Say so plainly rather
    // than silently screenshotting whatever happens to be under the pointer;
    // `--panel` is the deliberate, deterministic way to see the card panel.
    guard cfg.menuBar.panel == "menu" else {
        print("--menushot needs menuBar.panel == \"menu\" (the NSMenu fallback) - "
            + "the default card panel has no NSMenu to track. Use --panel instead.")
        return
    }
    var providers = buildProviders(cfg)
    var readings: [String: [Reading]] = [:]
    if let demo = diagnosticDemo(&cfg) {
        readings = demo
        providers = providers.filter { readings[$0.id] != nil }
    } else {
        for p in providers { readings[p.id] = await p.fetchAll() }
    }

    // Built exactly as `rebuildMenu` builds it, including the enabled "Check
    // now" item: a disabled item and an enabled one do not highlight alike, so
    // a harness that got that wrong would answer the wrong question.
    final class Sink: NSObject { @objc func noop(_ s: Any?) {} }
    let sink = Sink()
    let menu = NSMenu()
    let canceller = MenuCanceller(menu)
    for p in providers {
        let rows = buildPanelRows([p], readings, cfg)
        guard !rows.isEmpty else { continue }
        for v in rows {
            let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            v.frame = NSRect(origin: .zero, size: v.intrinsicContentSize)
            it.view = v
            menu.addItem(it)
        }
        let check = NSMenuItem(title: "    " + L.t("w.checknow"),
                               action: #selector(Sink.noop(_:)), keyEquivalent: "")
        check.target = sink
        menu.addItem(check)
        menu.addItem(.separator())
    }
    guard menu.numberOfItems > 0 else { print("no rows"); return }

    let screenH = NSScreen.main?.frame.height ?? 900
    let anchor = NSPoint(x: 320, y: screenH - 60)          // AppKit, y from bottom
    let topLeftY = screenH - anchor.y                       // CoreGraphics, y from top
    let base = (path as NSString).deletingPathExtension
    let restore = NSEvent.mouseLocation

    // Down the first section: header, both gauges, "Check now", then past the
    // separator into the next service as a control.
    for dy in [-24.0, 12, 30, 48, 66, 84, 104] {
        let target = CGPoint(x: anchor.x + 90, y: topLeftY + dy)
        CGWarpMouseCursorPosition(target)
        let out = "\(base)\(dy < 0 ? "-outside" : "-y\(Int(dy))").png"
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
            // A second warp once the menu is up: AppKit picks its highlight from
            // pointer movement, and a pointer that never moved after the menu
            // appeared may leave nothing highlighted at all.
            CGWarpMouseCursorPosition(CGPoint(x: target.x + 1, y: target.y))
            CGWarpMouseCursorPosition(target)
            Thread.sleep(forTimeInterval: 0.45)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // Only the menu's own rectangle: a full-screen grab would sweep up
            // whatever else the person happens to have open.
            p.arguments = ["-x", "-o", "-R",
                           "\(Int(anchor.x) - 12),\(Int(topLeftY) - 12),470,330", out]
            try? p.run()
            p.waitUntilExit()
            canceller.cancel()
        }
        menu.popUp(positioning: nil, at: anchor, in: nil)
        print("wrote \(out)")
    }
    CGWarpMouseCursorPosition(CGPoint(x: restore.x, y: screenH - restore.y))
}
