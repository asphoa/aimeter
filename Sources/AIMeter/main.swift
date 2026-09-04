import AppKit
import SwiftUI

/// A deterministic, credential-free rendering fixture.  It is intentionally
/// opt-in (`--demo-high`) and only used by the diagnostic render flags, so a
/// visual regression check can reproduce five simultaneous near-limit rows
/// without touching a person's config or making a provider request.
func highUsageDemo(_ cfg: inout Config) -> [String: [Reading]] {
    let ids = ["claude", "codex", "agy", "openrouter", "deepseek"]
    cfg.menuBar.lines = ids.map { MenuLine(provider: $0) }
    cfg.menuBar.colourScheme = .adaptive
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
    cfg.menuBar.colourScheme = .adaptive
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
    cfg.menuBar.colourScheme = .window
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
    if CommandLine.arguments.contains("--demo-high") { return highUsageDemo(&cfg) }
    return nil
}

/// Bridges the screen-capture worker back to AppKit's main queue without
/// capturing NSMenu directly in a Sendable closure.
private final class MenuCanceller: @unchecked Sendable {
    weak var menu: NSMenu?
    init(_ menu: NSMenu) { self.menu = menu }
    func cancel() { DispatchQueue.main.async { self.menu?.cancelTracking() } }
}

/// `AIMeter --once` prints every provider's reading as plain text and exits.
/// Same code path as the menu, so it is the honest way to see what the app is
/// actually reading without staring at the menu bar.
func runOnce(manual: Bool = false, record: Bool = false) async {
    setbuf(stdout, nil)
    let cfg = Config.load()
    L.current = cfg.language
    for p in buildProviders(cfg) {
        let readings = await p.fetchAll(manual: manual)
        if record { History.record(readings) }
        for r in Reading.asOfNow(readings) {
            let mark: String
            switch r.state {
            case .ok: mark = "OK  "
            case .warn: mark = "WARN"
            case .nearLimit: mark = "LIMIT"
            case .failure: mark = "ERR "
            case .off: mark = "--  "
            }
            var head = "[\(mark)] \(r.title)"
            if let a = r.account { head += " · \(a)" }
            if let s = r.snapshotAt { head += "  (" + L.t("m.snapshot", Fmt.relative(s)) + ")" }
            print(head)
            for g in r.gauges {
                let pct = g.percent.map { String(format: " %5.1f%%", $0) } ?? "       "
                let reset = g.resetsAt.map {
                    "  · " + L.t(g.expired ? "m.ended" : "m.resets", Fmt.relative($0))
                } ?? ""
                print("        \(g.label)\(pct)  \(g.text)\(reset)")
            }
            for l in r.lines { print("        \(l)") }
            print("")
        }
    }
}

/// `AIMeter --icon out.png` renders the menu bar strip from live data at 8x, so
/// the icon can be inspected as an artefact instead of squinted at in the bar.
/// Deliberately not @MainActor: nothing here is main-actor isolated, and hopping
/// to the main actor while the main thread waits on the semaphore below would
/// deadlock.
func renderIcon(to path: String) async {
    var cfg = Config.load()
    L.current = cfg.language
    var readings: [String: [Reading]] = [:]
    if let demo = diagnosticDemo(&cfg) {
        readings = demo
    } else {
        for p in buildProviders(cfg) { readings[p.id] = await p.fetchAll() }
    }
    let lines = cfg.menuBar.lines.map { resolveStripLine($0, readings, cfg) }

    for scheme in BarColourScheme.allCases {
        let strip = StatusStrip.image(lines: lines, scheme: scheme)
        let scale: CGFloat = 8
        let size = NSSize(width: StatusStrip.width * scale, height: StatusStrip.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        strip.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let out: String
        switch scheme {
        case .provider:
            out = path
        case .window:
            out = (path as NSString).deletingPathExtension + "-window.png"
        case .adaptive:
            out = (path as NSString).deletingPathExtension + "-adaptive.png"
        }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
    for (i, l) in lines.enumerated() {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0) } ?? "—" }
        print(String(format: "  line %d  %-11@ top %-5@ bottom %-5@ merged %-5@%@",
                     i, l.provider, f(l.top), f(l.bottom), f(l.merged),
                     l.stale ? "  (stale)" : ""))
    }
}

/// `AIMeter --panel out.png` renders the dropdown panel offscreen. AppKit's
/// behaviour for view-backed menu items is not something to take on trust, and
/// a PNG is cheaper to check than asking someone to open the menu and describe
/// what they see.
@MainActor
private func renderPanelRows(_ rows: [NSView], to path: String) {
    guard !rows.isEmpty else { print("no rows"); return }
    let w = Panel.width
    let h = rows.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.height }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    var y = h
    for v in rows {
        let rh = v.intrinsicContentSize.height
        y -= rh
        v.frame = NSRect(x: 0, y: y, width: w, height: rh)
        container.addSubview(v)
    }
    // A detached NSView has no backing store on a machine without an attached
    // display.  Draw into an explicit bitmap instead: this is still the real
    // row views, but does not silently turn a visual check into no PNG.
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(w), pixelsHigh: Int(h),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.windowBackgroundColor.setFill()
    container.bounds.fill()
    for v in rows {
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.translateBy(x: v.frame.origin.x, y: v.frame.origin.y)
        v.draw(v.bounds)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(rows.count) rows, \(Int(w))x\(Int(h)) pt)")
}

@MainActor
private func renderPanelDemo(to path: String) {
    var cfg = Config.load()
    L.current = cfg.language
    Palette.overrides = cfg.colours
    guard let readings = diagnosticDemo(&cfg) else { return }
    let providers = buildProviders(cfg).filter { readings[$0.id] != nil }
    renderPanelRows(buildPanelRows(providers, readings, cfg), to: path)
}

@MainActor
func renderPanel(to path: String) async {
    var cfg = Config.load()
    L.current = cfg.language
    Palette.overrides = cfg.colours
    var providers = buildProviders(cfg)
    var readings: [String: [Reading]] = [:]
    if let demo = diagnosticDemo(&cfg) {
        readings = demo
        providers = providers.filter { readings[$0.id] != nil }
    } else {
        for p in providers { readings[p.id] = await p.fetchAll() }
    }

    renderPanelRows(buildPanelRows(providers, readings, cfg), to: path)
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
    var cfg = Config.load()
    L.current = cfg.language
    Palette.overrides = cfg.colours
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

/// `AIMeter --settings out.png` renders the Accounts window offscreen, so its
/// layout can be checked here rather than by asking someone to go and look.
@MainActor
func renderSettings(to path: String, height: CGFloat) {
    let store = AccountsStore()
    let host = NSHostingController(rootView: AccountsView(store: store))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentViewController = host
    window.setContentSize(NSSize(width: 760, height: height))
    let view = host.view
    view.layoutSubtreeIfNeeded()
    // One turn of the runloop so SwiftUI completes its first layout pass.
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    try? png?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(Int(view.bounds.width))x\(Int(view.bounds.height)) pt)")
}

if let idx = CommandLine.arguments.firstIndex(of: "--settings"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let h = CommandLine.arguments.count > idx + 2 ? (Double(CommandLine.arguments[idx + 2]) ?? 720) : 720
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { renderSettings(to: path, height: CGFloat(h)) }
    exit(0)
}

/// `AIMeter --about out.png` renders the About window offscreen.
@MainActor
func renderAbout(to path: String) {
    let host = NSHostingController(rootView: aboutViewForRendering())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 10),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentViewController = host
    window.setContentSize(NSSize(width: 320, height: 10))
    let view = host.view
    view.layoutSubtreeIfNeeded()
    // Two passes: the first lets Text discover the 320pt width and wrap: the
    // window's height is still whatever it started at until this runs again.
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutSubtreeIfNeeded()
    let fitted = host.sizeThatFits(in: NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
    window.setContentSize(fitted)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    try? png?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(Int(view.bounds.width))x\(Int(view.bounds.height)) pt)")
    _ = window
}

if let idx = CommandLine.arguments.firstIndex(of: "--about"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    if let langIdx = CommandLine.arguments.firstIndex(of: "--lang"),
       CommandLine.arguments.count > langIdx + 1,
       let lang = Lang(rawValue: CommandLine.arguments[langIdx + 1]) {
        L.current = lang
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    MainActor.assumeIsolated { renderAbout(to: path) }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--panel"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    if CommandLine.arguments.contains("--demo-high") || CommandLine.arguments.contains("--demo-contrast") ||
       CommandLine.arguments.contains("--demo-expired") {
        // No fetch is involved in a fixture.  Calling it synchronously avoids
        // depending on an application run loop merely to render an NSBitmap.
        MainActor.assumeIsolated { renderPanelDemo(to: path) }
        exit(0)
    }
    // An NSView can draw only after AppKit has an application/appearance.  In
    // a headless diagnostic invocation that is not created by the normal app
    // startup path, so make it explicit just as --settings and --menushot do.
    NSApplication.shared.setActivationPolicy(.accessory)
    var done = false
    // A semaphore would deadlock here: renderPanel needs the main actor, and
    // the main thread is what would be blocked waiting for it.
    Task { @MainActor in await renderPanel(to: path); done = true }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--menushot"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    NSApplication.shared.setActivationPolicy(.accessory)
    var done = false
    Task { @MainActor in await renderMenuShots(to: path); done = true }
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--icon"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    let sem = DispatchSemaphore(value: 0)
    Task { await renderIcon(to: path); sem.signal() }
    sem.wait()
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--export-history") {
    let dir = CommandLine.arguments.count > idx + 1 && !CommandLine.arguments[idx + 1].hasPrefix("--")
        ? CommandLine.arguments[idx + 1] : Config.dir
    let (csv, html) = HistoryReport.export(dir: dir)
    print("wrote \(csv)")
    print("wrote \(html)")
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    // --manual also runs the checks that are deliberately never automatic.
    let manual = CommandLine.arguments.contains("--manual")
    let record = CommandLine.arguments.contains("--record")
    let sem = DispatchSemaphore(value: 0)
    Task { await runOnce(manual: manual, record: record); sem.signal() }
    sem.wait()
    exit(0)
}

// Top-level code is nonisolated but does run on the main thread - assume the
// isolation explicitly so the main-actor delegate can be constructed here.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Menu bar only: no Dock icon, no Cmd-Tab entry. Info.plist sets LSUIElement
    // too; this keeps it true even when the binary is launched directly.
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
