import Foundation

/// One credential/account within a provider. Fields are provider-specific and
/// all optional; each provider reads only what it needs. Autodiscovered on
/// first run, then editable by hand in ~/.config/aimeter/config.json.
struct AccountSpec: Codable, Sendable {
    var name: String
    var enabled: Bool = true

    /// Claude: keychain service name holding the OAuth blob.
    var keychainService: String?
    /// Claude / DeepSeek / generic: a file holding a raw key or a JSON blob.
    var keyFile: String?
    /// Which key to pull out when the file is a JSON blob of several keys.
    var keyJSONField: String?
    /// Codex / Antigravity: the HOME whose state directory this account uses.
    /// Separate accounts are separate HOMEs, which is how those CLIs work.
    var home: String?
    /// Generic OpenAI-compatible balance endpoint.
    var baseURL: String?
    var balancePath: String?

    init(name: String, enabled: Bool = true, keychainService: String? = nil,
         keyFile: String? = nil, keyJSONField: String? = nil, home: String? = nil,
         baseURL: String? = nil, balancePath: String? = nil) {
        self.name = name; self.enabled = enabled
        self.keychainService = keychainService
        self.keyFile = keyFile; self.keyJSONField = keyJSONField
        self.home = home; self.baseURL = baseURL; self.balancePath = balancePath
    }

    // Hand-written so a settings file written by an older or newer build still
    // loads: synthesised Codable rejects the whole object when one key is
    // absent, which would silently discard every account the user had.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "?"
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        keychainService = try? c.decodeIfPresent(String.self, forKey: .keychainService)
        keyFile = try? c.decodeIfPresent(String.self, forKey: .keyFile)
        keyJSONField = try? c.decodeIfPresent(String.self, forKey: .keyJSONField)
        home = try? c.decodeIfPresent(String.self, forKey: .home)
        baseURL = try? c.decodeIfPresent(String.self, forKey: .baseURL)
        balancePath = try? c.decodeIfPresent(String.self, forKey: .balancePath)
    }
}

/// One line of the menu bar strip.
///
/// Accounts are addressed by name rather than by index: the account list gets
/// reordered by the Accounts window, and an index would then silently point at
/// a different service. "*" means "whichever enabled account this service has",
/// which is what almost every line wants.
struct MenuLine: Codable, Hashable, Sendable {
    var provider: String
    var account: String = "*"
    /// Only meaningful for services with several independent gauges (one per
    /// API key). "*" takes the worst of them.
    var gauge: String = "*"

    init(provider: String, account: String = "*", gauge: String = "*") {
        self.provider = provider; self.account = account; self.gauge = gauge
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "?"
        account = (try? c.decode(String.self, forKey: .account)) ?? "*"
        gauge = (try? c.decode(String.self, forKey: .gauge)) ?? "*"
    }
}

/// What the menu bar strip shows.
struct MenuBarConfig: Codable {
    /// Three by default. The strip is a glance, not a dashboard: at three lines
    /// each half is 2.5 pt and readable, and the smaller services are one click
    /// away in the panel. Anything up to five can be selected in config.json,
    /// with the bars thinning accordingly.
    var lines: [MenuLine] = [
        MenuLine(provider: "claude"),
        MenuLine(provider: "codex"),
        MenuLine(provider: "openrouter")
    ]
    /// A snapshot older than this is drawn dimmed.
    var staleAfterMinutes: Int = 360
    var colourScheme: BarColourScheme = .provider
    /// "ring" (default), "ringNumeral", or "bars" (the legacy strip — kept
    /// selectable only via config.json, not offered in Settings).
    var style: String = "ring"
    /// Provider id whose windows the rings show.
    var primary: String = "claude"
    /// Provider ids whose panel cards use the expanded hero presentation.
    var expanded: [String] = ["claude"]
    /// A red dot when a non-primary provider is at 70%+ or in an alert state.
    var alertDot: Bool = true
    /// Sweep the rings from the previous reading on each refresh, and breathe
    /// the outer arc at ≥90%. Always off when Reduce Motion is on, regardless
    /// of this setting.
    var animate: Bool = true
    /// "cards" (default, v1.0.27) - a floating card panel replaces the NSMenu
    /// dropdown. "menu" keeps the old NSMenu path as a fallback, selectable
    /// only by editing config.json.
    var panel: String = "cards"

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = MenuBarConfig()
        // Decoded as written: clamping here would silence the range notice
        // `Config.validated` exists to raise. Validation is the one place that
        // both clamps and reports.
        staleAfterMinutes = (try? c.decode(Int.self, forKey: .staleAfterMinutes)) ?? def.staleAfterMinutes
        colourScheme = (try? c.decode(BarColourScheme.self, forKey: .colourScheme)) ?? .provider
        style = (try? c.decode(String.self, forKey: .style)) ?? def.style
        primary = (try? c.decode(String.self, forKey: .primary)) ?? def.primary
        expanded = (try? c.decode([String].self, forKey: .expanded)) ?? [primary]
        alertDot = (try? c.decode(Bool.self, forKey: .alertDot)) ?? def.alertDot
        animate = (try? c.decode(Bool.self, forKey: .animate)) ?? def.animate
        panel = (try? c.decode(String.self, forKey: .panel)) ?? def.panel
        if let decoded = try? c.decode([MenuLine].self, forKey: .lines), !decoded.isEmpty {
            lines = decoded
        } else if let legacy = try? c.decode([String].self, forKey: .rows), !legacy.isEmpty {
            // Upgrade the old "provider/account/gauge" string form in place.
            var seen = Set<String>()
            lines = legacy.compactMap { row in
                guard let pid = row.split(separator: "/").first.map(String.init),
                      seen.insert(pid).inserted else { return nil }
                return MenuLine(provider: pid)
            }
        } else {
            lines = def.lines
        }
    }

    enum CodingKeys: String, CodingKey {
        case lines, staleAfterMinutes, colourScheme, rows
        case style, primary, expanded, alertDot, animate, panel
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(lines, forKey: .lines)
        try c.encode(staleAfterMinutes, forKey: .staleAfterMinutes)
        try c.encode(colourScheme, forKey: .colourScheme)
        try c.encode(style, forKey: .style)
        try c.encode(primary, forKey: .primary)
        try c.encode(expanded, forKey: .expanded)
        try c.encode(alertDot, forKey: .alertDot)
        try c.encode(animate, forKey: .animate)
        try c.encode(panel, forKey: .panel)
    }
}

/// Usage ledger settings. Percentages, labels, times and error strings only —
/// see History.swift; never a token, header, or secret.
struct HistoryConfig: Codable, Sendable {
    var enabled: Bool = true
    var retentionMonths: Int = 12

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = HistoryConfig()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? def.enabled
        let raw = (try? c.decode(Int.self, forKey: .retentionMonths)) ?? def.retentionMonths
        retentionMonths = raw   // clamped and reported by Config.validated
    }
}

/// One-shot migration prompts shown in Settings.
struct MigrationFlags: Codable, Sendable {
    var agyPromptShown: Bool = false
}

/// User-tunable peak-pricing windows for the DeepSeek balance card note.
struct DeepSeekPeakHours: Codable, Sendable {
    /// IANA timezone id.
    var timezone: String = "Asia/Shanghai"
    /// Gregorian weekday numbers (1 = Sunday … 7 = Saturday).
    var weekdays: [Int] = [2, 3, 4, 5, 6]
    /// Half-open local hour ranges as [startHour, endHour).
    var ranges: [[Int]] = [[9, 12], [14, 18]]
}

struct DeepSeekConfig: Codable, Sendable {
    var peakHours: DeepSeekPeakHours = DeepSeekPeakHours()
}

struct Config: Codable {
    var language: Lang = .system
    var menuBar: MenuBarConfig = MenuBarConfig()
    var history: HistoryConfig = HistoryConfig()
    var refreshSeconds: Int = 60
    /// Provider id -> shown or not. Missing key means shown.
    var enabled: [String: Bool] = [:]
    /// The main path (v1.0.28): reads Antigravity's quota through the CLI's
    /// own read-only print-mode command, `agy -p "/usage" --output-format
    /// json` - see AgyPrint. Measured to spend no quota and take ~4s, so
    /// unlike the pty screen-scrape it replaced as the default, it is safe
    /// on a timer.
    var agyQuotaViaPrint: Bool = true
    /// A manual-only fallback for when print mode is off or has failed:
    /// reads Antigravity's own `/usage` panel by driving the CLI in a
    /// pseudo-terminal. Slow and never automatic - see AgyTUI.
    var agyQuotaViaTUI: Bool = true
    /// Path to the agy binary; empty means look in the usual places.
    var agyBinary: String = ""
    /// Colour-role overrides as "#RRGGBBAA". An absent role keeps the dynamic
    /// default. There is deliberately no colour settings UI. See Palette.
    var colours: [String: String] = [:]
    /// Per-provider check interval in seconds. 0 means "only when I ask".
    /// A missing entry falls back to `refreshSeconds`.
    ///
    /// Antigravity defaults to hourly (owner decision, 2026-09-04): the old
    /// default of 0 dated from when the only source was the pty screen-
    /// scrape, which really was too slow and too close to the traffic shape
    /// that gets accounts flagged to run unattended. Print mode (AgyPrint)
    /// measures at ~4s and spends no quota, so polling it hourly costs
    /// nothing worth withholding. `Config.migratingAgyInterval` moves an
    /// existing settings file off the old default once; see `load()`.
    /// Cursor has no public usage API (see CursorProvider) and its row never
    /// carries a percentage to poll for — it is a link, opened by hand.
    var intervals: [String: Int] = ["agy": 3600, "cursor": 0]
    /// Set once `load()` has applied the one-time "agy" interval migration
    /// below. Guards that migration to run exactly once per install, so a
    /// user who deliberately sets the interval back to 0 afterwards (to go
    /// manual-only again) is respected rather than silently reverted on the
    /// next launch.
    var agyIntervalMigrated: Bool = false
    var migration: MigrationFlags = MigrationFlags()
    /// Set during decode only: whether `intervals` contained an explicit `"agy"` key.
    var agyIntervalKeyPresent: Bool = false
    /// A manual check on a Claude row whose access token has gone stale runs the
    /// real `claude` once - a local status check, then a minimal one-turn
    /// prompt - and re-reads the keychain, because the CLI making a live request
    /// is the only thing that refreshes that token. On by default: the
    /// alternative is a "Check now" button that cannot succeed, which is what
    /// this replaces. Turning it off costs nothing but the button; the row still
    /// says what to run by hand.
    ///
    /// The prompt is charged against the user's own window - measured at 264
    /// input and 83 output tokens of Haiku, and the row says so before it
    /// happens. That is the only thing this app does that spends anything the
    /// user did not ask for by name, which is why it is a setting at all.
    /// Never on a timer - see ClaudeCLI and ClaudeProvider.
    var claudeRefreshViaCLI: Bool = true
    /// Path to the claude binary; empty means look in the usual places.
    var claudeBinary: String = ""
    /// providerId -> accounts. Empty means "autodiscover on next launch".
    var accounts: [String: [AccountSpec]] = [:]
    /// User-defined providers. Invalid or colliding entries are rejected at
    /// decode time and described in loadWarnings for the Services page.
    var recipes: [Recipe] = []
    var loadWarnings: [String] = []
    var deepseek: DeepSeekConfig = DeepSeekConfig()

    init() {}

    /// Same reasoning as AccountSpec: every field falls back to its default so
    /// an old settings file is upgraded in place rather than thrown away.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Config()
        language = (try? c.decode(Lang.self, forKey: .language)) ?? def.language
        menuBar = (try? c.decode(MenuBarConfig.self, forKey: .menuBar)) ?? def.menuBar
        history = (try? c.decode(HistoryConfig.self, forKey: .history)) ?? def.history
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? def.refreshSeconds
        enabled = (try? c.decode([String: Bool].self, forKey: .enabled)) ?? def.enabled
        // "agyDirectQuotaOnManualCheck" is no longer a field - an old
        // settings file that still carries it is decoded tolerantly here by
        // simply never asking for that key, the same way every other
        // removed or renamed field in this file is handled.
        if let decodedIntervals = try? c.decode([String: Int].self, forKey: .intervals) {
            intervals = decodedIntervals
            agyIntervalKeyPresent = decodedIntervals.keys.contains("agy")
        } else {
            intervals = def.intervals
            agyIntervalKeyPresent = false
        }
        agyIntervalMigrated = (try? c.decode(Bool.self, forKey: .agyIntervalMigrated)) ?? def.agyIntervalMigrated
        migration = (try? c.decode(MigrationFlags.self, forKey: .migration)) ?? def.migration
        agyQuotaViaPrint = (try? c.decode(Bool.self, forKey: .agyQuotaViaPrint)) ?? def.agyQuotaViaPrint
        agyQuotaViaTUI = (try? c.decode(Bool.self, forKey: .agyQuotaViaTUI)) ?? def.agyQuotaViaTUI
        agyBinary = (try? c.decode(String.self, forKey: .agyBinary)) ?? def.agyBinary
        let decodedColours = (try? c.decode([String: String].self, forKey: .colours)) ?? def.colours
        colours = Self.migratedColours(decodedColours)
        claudeRefreshViaCLI = (try? c.decode(Bool.self, forKey: .claudeRefreshViaCLI))
            ?? def.claudeRefreshViaCLI
        claudeBinary = (try? c.decode(String.self, forKey: .claudeBinary)) ?? def.claudeBinary
        accounts = (try? c.decode([String: [AccountSpec]].self, forKey: .accounts)) ?? def.accounts
        let decoded = (try? c.decode([Recipe].self, forKey: .recipes)) ?? []
        var seen = Set<String>()
        recipes = decoded.filter { recipe in
            if !Recipe.validID(recipe.id) {
                loadWarnings.append(L.t("rc.warning.id", recipe.id)); return false
            }
            if Recipe.reservedIDs.contains(recipe.id) {
                loadWarnings.append(L.t("rc.warning.reserved", recipe.id)); return false
            }
            if !seen.insert(recipe.id).inserted {
                loadWarnings.append(L.t("rc.warning.duplicate", recipe.id)); return false
            }
            if !["http", "cli", "file", "none"].contains(recipe.fetch.method) {
                loadWarnings.append(L.t("rc.warning.method", recipe.id, recipe.fetch.method)); return false
            }
            return true
        }
        deepseek = (try? c.decode(DeepSeekConfig.self, forKey: .deepseek)) ?? def.deepseek
    }

    enum CodingKeys: String, CodingKey {
        case language, menuBar, history, refreshSeconds, enabled
        case agyQuotaViaPrint, agyQuotaViaTUI, agyBinary, colours, intervals
        case agyIntervalMigrated, migration, claudeRefreshViaCLI, claudeBinary
        case accounts, recipes, deepseek
    }

    static var dir: String { expand("~/.config/aimeter") }
    /// Tests may point saves at a temp file without touching the real settings.
    static var pathOverride: String?
    static var path: String { pathOverride ?? dir + "/config.json" }

    static func load() -> (config: Config, rangeNotice: String?) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var cfg: Config
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
        } else {
            cfg = Config()
        }
        if !cfg.agyIntervalMigrated {
            cfg = migratingAgyInterval(cfg, agyKeyPresent: cfg.agyIntervalKeyPresent)
            do { try cfg.save() } catch { Diagnostics.warn("config save failed during agy migration: \(error)") }
        }
        let (validated, notice) = validated(cfg)
        cfg = validated
        if cfg.accounts.isEmpty {
            cfg.accounts = Discovery.all()
            do { try cfg.save() } catch { Diagnostics.warn("config save failed during discovery: \(error)") }
        }
        // Applied here rather than at each call site: one of those call sites
        // was missed, and the only symptom was colours silently not applying.
        Palette.overrides = cfg.colours
        let rangeNotice = notice.map { L.t("s.range.clamped", $0) }
        return (cfg, rangeNotice)
    }

    static func migratedColours(_ input: [String: String]) -> [String: String] {
        var output: [String: String] = [:]
        for (key, value) in input {
            if key.hasPrefix("panel.") || key.hasSuffix(".week") { continue }
            if key.hasPrefix("service."), key.hasSuffix(".5h") {
                let destination = String(key.dropLast(3))
                if input[destination] == nil { output[destination] = value }
                continue
            }
            output[key == "text" ? Palette.ink : key] = value
        }
        return output
    }

    static func clamp(_ value: Int, min lo: Int, max hi: Int) -> Int {
        max(lo, min(hi, value))
    }

    /// Validates integer ranges before load/save. Returns clamped config and an
    /// optional human-readable notice naming what was adjusted.
    static func validated(_ cfg: Config) -> (Config, String?) {
        var out = cfg
        var notices: [String] = []
        out.refreshSeconds = clamp(out.refreshSeconds, min: 0, max: 86_400)
        if out.refreshSeconds != cfg.refreshSeconds {
            notices.append("refreshSeconds")
        }
        let stale = clamp(out.menuBar.staleAfterMinutes, min: 1, max: 10_080)
        if stale != out.menuBar.staleAfterMinutes { notices.append("staleAfterMinutes") }
        out.menuBar.staleAfterMinutes = stale
        let retention = clamp(out.history.retentionMonths, min: 1, max: 120)
        if retention != out.history.retentionMonths { notices.append("retentionMonths") }
        out.history.retentionMonths = retention
        for (key, value) in out.intervals {
            let clamped = clamp(value, min: 0, max: 86_400)
            if clamped != value { notices.append("intervals.\(key)") }
            out.intervals[key] = clamped
        }
        let notice = notices.isEmpty ? nil : notices.joined(separator: ", ")
        return (out, notice)
    }

    /// The one-time "agy" interval migration (2026-09-04, revised v1.0.34):
    /// only when the `"agy"` key was **absent** from a pre-existing settings
    /// file does the new hourly default apply. An explicit `0` (manual-only) is
    /// preserved and may trigger a one-shot Settings prompt.
    static func migratingAgyInterval(_ cfg: Config, agyKeyPresent: Bool) -> Config {
        guard !cfg.agyIntervalMigrated else { return cfg }
        var out = cfg
        if !agyKeyPresent { out.intervals["agy"] = 3600 }
        out.agyIntervalMigrated = true
        return out
    }

    /// Whether Settings should offer to enable automatic Antigravity checks.
    static func needsAgyAutoPrompt(_ cfg: Config) -> Bool {
        cfg.agyIntervalKeyPresent && cfg.intervals["agy"] == 0 && !cfg.migration.agyPromptShown
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try writePrivate(data, to: Config.path)
    }

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

    /// How often this provider is checked, in seconds. 0 = only on request.
    func interval(_ providerID: String) -> Int {
        intervals[providerID] ?? recipes.first(where: { $0.id == providerID })?.interval ?? refreshSeconds
    }

    func accounts(_ providerID: String, fallback: [AccountSpec]) -> [AccountSpec] {
        let list = accounts[providerID] ?? fallback
        return list.filter(\.enabled)
    }
}

/// Finds accounts that already exist on this machine so the first launch shows
/// something real without anyone touching a config file. Only conventional
/// locations are probed - anything unusual is added through the Accounts window.
enum Discovery {
    /// Extra account HOMEs can be dropped in ~/.config/aimeter/pools/<provider>/
    /// as folders or symlinks; each becomes its own row.
    static func poolDirs(_ provider: String) -> [(name: String, path: String)] {
        let pool = Config.dir + "/pools/" + provider
        return ((try? FileManager.default.contentsOfDirectory(atPath: pool)) ?? [])
            .sorted()
            .filter { !$0.hasPrefix(".") }
            .map { ($0, pool + "/" + $0) }
    }

    static func all() -> [String: [AccountSpec]] {
        ["claude": claude(), "codex": codex(), "agy": agy(),
         "openrouter": openrouter(), "deepseek": deepseek(), "generic": []]
    }

    static func claude() -> [AccountSpec] {
        [AccountSpec(name: "Claude Code", keychainService: "Claude Code-credentials")]
    }

    /// ~/.codex under $HOME, the CODEX_HOME state directory when set, plus pooled HOMEs.
    static func codex() -> [AccountSpec] {
        var out: [AccountSpec] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: expand("~/.codex")) {
            out.append(AccountSpec(name: "Default", home: expand("~")))
        }
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            let state = expand(ch)
            if !state.isEmpty, state != expand("~/.codex"), fm.fileExists(atPath: state) {
                out.append(AccountSpec(name: "CODEX_HOME", home: state))
            }
        }
        for p in poolDirs("codex") where fm.fileExists(atPath: p.path + "/.codex") {
            out.append(AccountSpec(name: p.name, home: p.path))
        }
        return out
    }

    /// Any HOME containing .gemini/antigravity-cli.
    static func agy() -> [AccountSpec] {
        var out: [AccountSpec] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: expand("~/.gemini/antigravity-cli")) {
            out.append(AccountSpec(name: "Default", home: expand("~")))
        }
        for p in poolDirs("agy") where fm.fileExists(atPath: p.path + "/.gemini/antigravity-cli") {
            out.append(AccountSpec(name: p.name, home: p.path))
        }
        return out
    }

    static func openrouter() -> [AccountSpec] {
        var out: [AccountSpec] = []
        let dir = expand("~/.config/openrouter")
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter({ $0.hasPrefix("key") }).sorted() {
            let short = file.replacingOccurrences(of: "key_", with: "")
                            .replacingOccurrences(of: "key", with: "")
            out.append(AccountSpec(name: short.isEmpty ? "Default" : short,
                                   keyFile: dir + "/" + file))
        }
        for cand in ["~/.openrouter_key", "~/.config/openrouter.key"]
        where FileManager.default.fileExists(atPath: expand(cand)) {
            out.append(AccountSpec(name: "Default", keyFile: expand(cand)))
        }
        if out.isEmpty, ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil {
            out.append(AccountSpec(name: "OPENROUTER_API_KEY", keyFile: "env:OPENROUTER_API_KEY"))
        }
        return out
    }

    static func deepseek() -> [AccountSpec] {
        for cand in ["~/.deepseek_key", "~/.config/deepseek/key", "~/.config/deepseek.key"]
        where FileManager.default.fileExists(atPath: expand(cand)) {
            return [AccountSpec(name: "Default", keyFile: expand(cand))]
        }
        if ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"] != nil {
            return [AccountSpec(name: "DEEPSEEK_API_KEY", keyFile: "env:DEEPSEEK_API_KEY")]
        }
        return []
    }
}
