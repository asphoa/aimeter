import AppKit
import SwiftUI

/// `AIMeter --once` prints every provider's reading as plain text and exits.
/// Same code path as the menu, so it is the honest way to see what the app is
/// actually reading without staring at the menu bar.
func runOnce(manual: Bool = false, record: Bool = false) async {
    setbuf(stdout, nil)
    let cfg = Config.load().config
    L.current = cfg.language
    for p in buildProviders(cfg) {
        let readings = await p.fetchAll(manual: manual)
        if record { _ = History.record(readings, settings: History.RecordSettings(cfg.history)) }
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

func runRecipeTest(_ id: String) async {
    setbuf(stdout, nil)
    let cfg = Config.load().config; L.current = cfg.language
    guard let recipe = cfg.recipes.first(where: { $0.id == id }) else {
        print("ERR  \(L.t("rc.not.found", id))"); return
    }
    let account = cfg.accounts(recipe.id, fallback: []).first ?? AccountSpec(name: recipe.name)
    guard let pin = recipe.fetch.method == "none" ? RecipePin.Pin() : RecipePin.read(recipe.id) else {
        print("ERR  \(L.t("rc.reapprove"))"); return
    }
    switch await RecipeFetch.test(recipe, account: account, pin: pin) {
    case .failure(let fail): print("ERR  \(fail.message)")
    case .success(let result):
        print(result.meta.request)
        print("status \(result.meta.status.map(String.init) ?? "—") · \(result.meta.bytes) bytes · "
              + String(format: "%.0f ms", result.meta.elapsed * 1000))
        for gauge in result.reading.gauges { print("\(gauge.label): \(gauge.text)") }
        for line in result.reading.lines { print(line) }
        print(result.rawPreview)
    }
}

if CommandLine.arguments.contains("--settings") {
    fputs("--settings was removed; use --panel --page settings\n", stderr)
    exit(2)
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
    let page: SettingsPage? = {
        guard let pageIndex = CommandLine.arguments.firstIndex(of: "--page"),
              CommandLine.arguments.count > pageIndex + 1 else { return nil }
        switch CommandLine.arguments[pageIndex + 1] {
        case "usage": return nil
        case "settings": return .root
        case "services": return .services
        case "catalogue": return .catalogue
        case "add": return .add(kind: "openrouter")
        case "custom": return .custom
        case "menubar": return .menuBar
        case "general": return .general
        case "history": return .history
        default:
            fputs("unknown --page; use usage|settings|services|catalogue|add|custom|menubar|general|history\n", stderr)
            exit(2)
        }
    }()
    NSApplication.shared.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--demo-high") || CommandLine.arguments.contains("--demo-contrast") ||
       CommandLine.arguments.contains("--demo-expired") || CommandLine.arguments.contains("--demo-notice") {
        MainActor.assumeIsolated { renderPanelDemo(to: path, page: page) }
        exit(0)
    }
    var done = false
    Task { @MainActor in await renderPanel(to: path, page: page); done = true }
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

if let idx = CommandLine.arguments.firstIndex(of: "--recipe-test"),
   CommandLine.arguments.count > idx + 1 {
    let id = CommandLine.arguments[idx + 1]
    let sem = DispatchSemaphore(value: 0)
    Task { await runRecipeTest(id); sem.signal() }
    sem.wait(); exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--export-history") {
    let dir = CommandLine.arguments.count > idx + 1 && !CommandLine.arguments[idx + 1].hasPrefix("--")
        ? CommandLine.arguments[idx + 1] : Config.dir
    do {
        let (csv, html) = try HistoryReport.export(dir: dir)
        print("wrote \(csv)")
        print("wrote \(html)")
    } catch {
        fputs("export failed: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    let manual = CommandLine.arguments.contains("--manual")
    let record = CommandLine.arguments.contains("--record")
    let sem = DispatchSemaphore(value: 0)
    Task { await runOnce(manual: manual, record: record); sem.signal() }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
