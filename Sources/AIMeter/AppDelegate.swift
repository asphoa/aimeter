import AppKit
import ServiceManagement

func buildProviders(_ cfg: Config) -> [Provider] {
    let all: [Provider] = [
        ClaudeProvider(cfg: cfg),
        CodexProvider(cfg: cfg),
        AgyProvider(cfg: cfg),
        OpenRouterProvider(cfg: cfg),
        DeepSeekProvider(cfg: cfg),
        GenericProvider(cfg: cfg),
        LocalAIProvider(),
        CursorProvider(cfg: cfg)
    ]
    return all.filter { cfg.isEnabled($0.id) }
}

    /// The latest readings, shared so the Accounts window can preview the strip
/// without triggering its own round of network and keychain access.
final class ReadingsBox: @unchecked Sendable {
    static let shared = ReadingsBox()
    private var store: [String: [Reading]] = [:]
    private let lock = NSLock()

    var current: [String: [Reading]] {
        get { lock.lock(); defer { lock.unlock() }; return store }
        set { lock.lock(); store = newValue; lock.unlock() }
    }
}

/// Turns one configured line into the two halves the strip draws.
///
/// The mapping is derived from each gauge's `kind` rather than from its
/// position, because a provider can add or drop a gauge between refreshes
/// (Claude's overage window only appears once it is in use).
func resolveStripLine(_ line: MenuLine,
                      _ readings: [String: [Reading]],
                      _ cfg: Config) -> StripLine {
    guard let raw = readings[line.provider], !raw.isEmpty else {
        return .noData(line.provider)
    }
    // Aged first: an expired window loses its percentage, and a bar drawn from
    // a percentage the panel has already withdrawn would be the same wrong
    // claim, made where there is no room to qualify it.
    let all = Reading.asOfNow(raw)
    let chosen = line.account == "*" ? all : all.filter { $0.account == line.account }
    guard !chosen.isEmpty else { return .noData(line.provider) }

    let staleAfter = TimeInterval(cfg.menuBar.staleAfterMinutes * 60)
    let stale = chosen.contains { r in
        guard let s = r.snapshotAt else { return false }
        return Date().timeIntervalSince(s) > staleAfter
    }
    let state = chosen.map(\.state).max() ?? .off

    // Keep the structural list separate from the drawable one. A snapshot can
    // lose a percentage when one of its windows ends, but that does not turn a
    // two-window provider into a one-window provider. In that case the empty
    // half is meaningful: it says a window exists but has no honest value now.
    var allGauges = chosen.flatMap(\.gauges)
    if line.gauge != "*" { allGauges = allGauges.filter { $0.label == line.gauge } }
    let gauges = allGauges.filter { $0.percent != nil }
    guard !gauges.isEmpty else { return .noData(line.provider, state: state) }

    var out = StripLine(provider: line.provider, top: nil, bottom: nil, merged: nil,
                        state: state, stale: stale)
    let hasShortWindow = allGauges.contains { $0.kind == .shortWindow }
    let hasLongWindow = allGauges.contains { $0.kind == .longWindow }
    if hasShortWindow && hasLongWindow {
        out.top = gauges.filter { $0.kind == .shortWindow }.compactMap(\.percent).max()
        out.bottom = gauges.filter { $0.kind == .longWindow }.compactMap(\.percent).max()
        return out
    }

    // A provider that structurally exposes only one window remains one full
    // height bar, even if it has several readings for that same kind (for
    // example, several OpenRouter weekly caps). `.other` is a real single
    // measurement category too, rather than an implicit weekly window.
    out.merged = gauges.compactMap(\.percent).max()
    let liveKinds = Set(gauges.map(\.kind))
    if liveKinds.contains(.shortWindow) && !liveKinds.contains(.longWindow) {
        out.mergedKind = .shortWindow
    } else if liveKinds.contains(.longWindow) && !liveKinds.contains(.shortWindow) {
        out.mergedKind = .longWindow
    }
    return out
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var cfg = Config.load()
    private var providers: [Provider] = []
    private var readings: [String: [Reading]] = [:]
    private var lastRefresh: Date?
    private var lastFetched: [String: Date] = [:]
    private var timer: Timer?
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        L.current = cfg.language
        Palette.overrides = cfg.colours
        providers = buildProviders(cfg)
        History.applyRetention(months: cfg.history.retentionMonths)
        NotificationCenter.default.addObserver(
            forName: AccountsStore.changed, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        // Appearance changes redraw what is already known; they must not send
        // the app back out to every provider.
        NotificationCenter.default.addObserver(
            forName: AccountsStore.restyled, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.cfg = Config.load()
                    Palette.overrides = self.cfg.colours
                    self.rebuildMenu()
                    self.updateTitle()
                }
            }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "AI …"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        refresh()
        restartTimer()
    }

    /// Re-reads the settings file after the Accounts window changed it, then
    /// refetches so the menu reflects the new set immediately.
    private func reload() {
        cfg = Config.load()
        L.current = cfg.language
        Palette.overrides = cfg.colours
        providers = buildProviders(cfg)
        readings = readings.filter { key, _ in providers.contains { $0.id == key } }
        restartTimer()
        lastRefresh = nil
        refresh()
    }

    /// One short tick drives every provider; each is fetched only when its own
    /// interval has elapsed, so a service set to a slow cadence - or to manual -
    /// is not dragged along by a fast one.
    private func restartTimer() {
        timer?.invalidate()
        let anyScheduled = providers.contains { cfg.interval($0.id) > 0 }
        guard anyScheduled else { timer = nil; return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDue() }
        }
    }

    /// Fetches only the providers whose interval has come round.
    private func refreshDue() {
        let now = Date()
        let due = providers.filter { p in
            let secs = cfg.interval(p.id)
            guard secs > 0 else { return false }
            guard let last = lastFetched[p.id] else { return true }
            return now.timeIntervalSince(last) >= Double(secs)
        }
        guard !due.isEmpty else { return }
        refresh(due, manual: false)
    }

    // MARK: - fetching

    func refresh(_ list: [Provider]? = nil, manual: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let list = list ?? providers
        Task { @MainActor in
            await withTaskGroup(of: (String, [Reading]).self) { group in
                for p in list {
                    group.addTask { (p.id, await p.fetchAll(manual: manual)) }
                }
                for await (pid, rs) in group {
                    self.readings[pid] = rs
                    self.lastFetched[pid] = Date()
                    History.record(rs)
                }
            }
            ReadingsBox.shared.current = self.readings
            self.lastRefresh = Date()
            self.refreshing = false
            self.rebuildMenu()
            self.updateTitle()
        }
    }

    /// Refresh on open, but never more than once every 15s - the Claude row
    /// costs one API request per refresh, per account.
    func menuWillOpen(_ menu: NSMenu) {
        // Opening the menu is not a request to check anything - it only lets
        // through whatever was already due.
        refreshDue()
    }

    // MARK: - rendering

    private var allReadings: [Reading] { providers.flatMap { readings[$0.id] ?? [] } }

    /// Panel order follows the menu bar strip, so a source that was moved to the
    /// second line is also second in the list. Sources not on the strip keep
    /// their built-in order and follow behind.
    private var orderedProviders: [Provider] {
        var out: [Provider] = []
        for line in cfg.menuBar.lines {
            guard let p = providers.first(where: { $0.id == line.provider }),
                  !out.contains(where: { $0.id == p.id }) else { continue }
            out.append(p)
        }
        out.append(contentsOf: providers.filter { p in !out.contains { $0.id == p.id } })
        return out
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let lines = cfg.menuBar.lines.map { resolveStripLine($0, readings, cfg) }
        button.image = StatusStrip.image(lines: lines, scheme: cfg.menuBar.colourScheme)
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
        button.image?.accessibilityDescription = zip(cfg.menuBar.lines, lines).map { line, s in
            let parts = [s.merged, s.top, s.bottom].compactMap { $0 }
                .map { String(format: "%.0f%%", $0) }
            return "\(line.provider) " + (parts.isEmpty ? "—" : parts.joined(separator: "/"))
        }.joined(separator: ", ")
    }

    /// Wraps a drawn row in a disabled menu item.
    private func item(_ view: NSView) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        it.view = view
        return it
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        for p in orderedProviders {
            let rows = buildPanelRows([p], readings, cfg)
            guard !rows.isEmpty else { continue }
            rows.forEach { menu.addItem(item($0)) }
            if p.id == "cursor" {
                let open = NSMenuItem(title: "    " + L.t("m.cursor.open"),
                                      action: #selector(openCursorUsage), keyEquivalent: "")
                open.target = self
                menu.addItem(open)
            } else {
                let check = NSMenuItem(title: "    " + L.t("w.checknow"),
                                       action: #selector(checkProvider(_:)), keyEquivalent: "")
                check.target = self
                check.representedObject = p.id
                menu.addItem(check)
            }
            menu.addItem(.separator())
        }

        let stamp = lastRefresh.map { d -> String in
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
        } ?? "—"
        let anyScheduled = providers.contains { cfg.interval($0.id) > 0 }
        menu.addItem(item(Panel.info(anyScheduled
                                        ? L.t("m.updated", stamp, cfg.refreshSeconds)
                                        : L.t("m.onopen"), error: false)))

        add(menu, L.t("m.refresh"), #selector(doRefresh), key: "r")
        let login = NSMenuItem(title: L.t("m.login"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        add(menu, L.t("m.accounts"), #selector(openAccounts), key: ",")
        menu.addItem(languageMenu())
        menu.addItem(intervalMenu())
        add(menu, L.t("m.history"), #selector(openHistory))
        add(menu, L.t("m.debug"), #selector(openDebug))
        add(menu, L.t("m.about"), #selector(openAbout))
        menu.addItem(.separator())
        add(menu, L.t("m.quit"), #selector(quit), key: "q")
    }

    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, key: String = "") {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        menu.addItem(it)
    }

    // MARK: - actions

    /// One of the two paths a person can trigger, and therefore one of the two
    /// allowed to do what a timer must not: make a request, or launch another
    /// program. Both reach a provider as `manual: true`; nothing else does.
    @objc private func doRefresh() {
        lastRefresh = nil
        lastFetched.removeAll()
        // "Only when I ask" means this button too: a source set to manual has
        // its own, and refreshing everything should not quietly launch a CLI
        // and sit there for half a minute.
        let scheduled = providers.filter { cfg.interval($0.id) > 0 }
        refresh(scheduled, manual: true)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = L.t("m.loginfail")
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        rebuildMenu()
    }

    private func languageMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L.t("m.language"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for lang in Lang.allCases {
            let it = NSMenuItem(title: lang.displayName, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = lang.rawValue
            it.state = cfg.language == lang ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    private func intervalMenu() -> NSMenuItem {
        let parent = NSMenuItem(title: L.t("m.interval"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for secs in [30, 60, 300, 900, 0] {
            let title = secs == 0 ? L.t("m.onopen")
                      : (secs < 60 ? L.t("m.seconds", secs) : L.t("m.minutes", secs / 60))
            let it = NSMenuItem(title: title, action: #selector(pickInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = secs
            it.state = cfg.refreshSeconds == secs ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        return parent
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw) else { return }
        cfg.language = lang
        cfg.save()
        L.current = lang
        lastRefresh = nil
        refresh()          // provider text is localised at fetch time
        rebuildMenu()
    }

    @objc private func pickInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        // The menu sets the default; per-provider overrides live in the
        // Accounts window and are left alone here.
        cfg.refreshSeconds = secs
        cfg.save()
        restartTimer()
        rebuildMenu()
    }

    /// Checking one source, on purpose. The other `manual: true` path - and the
    /// one the Claude row's CLI refresh and the Antigravity panel are really
    /// for, since both take seconds and start a vendor binary.
    @objc private func checkProvider(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? String,
              let provider = providers.first(where: { $0.id == pid }) else { return }
        lastFetched[pid] = nil
        refresh([provider], manual: true)
    }

    @objc private func openAccounts() {
        AccountsWindowController.shared.show()
    }

    @objc private func openDebug() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Config.dir))
    }

    @objc private func openHistory() {
        let (_, htmlPath) = HistoryReport.export()
        NSWorkspace.shared.open(URL(fileURLWithPath: htmlPath))
    }

    @objc private func openCursorUsage() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard/spending")!)
    }

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
