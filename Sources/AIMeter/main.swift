import AppKit

/// `AIMeter --once` prints every provider's reading as plain text and exits.
/// Same code path as the menu, so it is the honest way to see what the app is
/// actually reading without staring at the menu bar.
func runOnce(manual: Bool = false) async {
    setbuf(stdout, nil)
    let cfg = Config.load()
    L.current = cfg.language
    for p in buildProviders(cfg) {
        for r in await p.fetchAll(manual: manual) {
            let mark: String
            switch r.state {
            case .ok: mark = "OK  "
            case .warn: mark = "WARN"
            case .error: mark = "ERR "
            case .off: mark = "--  "
            }
            var head = "[\(mark)] \(r.title)"
            if let a = r.account { head += " · \(a)" }
            if let s = r.snapshotAt { head += "  (" + L.t("m.snapshot", Fmt.relative(s)) + ")" }
            print(head)
            for g in r.gauges {
                let pct = g.percent.map { String(format: " %5.1f%%", $0) } ?? "       "
                let reset = g.resetsAt.map { "  · " + L.t("m.resets", Fmt.relative($0)) } ?? ""
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
    let cfg = Config.load()
    L.current = cfg.language
    var readings: [String: [Reading]] = [:]
    for p in buildProviders(cfg) { readings[p.id] = await p.fetchAll() }
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
        let out = scheme == .provider ? path
                : (path as NSString).deletingPathExtension + "-window.png"
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
func renderPanel(to path: String) async {
    let cfg = Config.load()
    L.current = cfg.language
    let providers = buildProviders(cfg)
    var readings: [String: [Reading]] = [:]
    for p in providers { readings[p.id] = await p.fetchAll() }

    let rows = buildPanelRows(providers, readings, cfg)
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
    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.windowBackgroundColor.setFill()
    container.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    container.cacheDisplay(in: container.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: path))
    print("wrote \(path)  (\(rows.count) rows, \(Int(w))x\(Int(h)) pt)")
}

if let idx = CommandLine.arguments.firstIndex(of: "--panel"),
   CommandLine.arguments.count > idx + 1 {
    let path = CommandLine.arguments[idx + 1]
    var done = false
    // A semaphore would deadlock here: renderPanel needs the main actor, and
    // the main thread is what would be blocked waiting for it.
    Task { @MainActor in await renderPanel(to: path); done = true }
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

if CommandLine.arguments.contains("--once") {
    // --manual also runs the checks that are deliberately never automatic.
    let manual = CommandLine.arguments.contains("--manual")
    let sem = DispatchSemaphore(value: 0)
    Task { await runOnce(manual: manual); sem.signal() }
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
