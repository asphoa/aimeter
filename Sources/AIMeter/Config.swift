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
    /// away in the panel. Anything up to five can be chosen in the Accounts
    /// window, with the bars thinning accordingly.
    var lines: [MenuLine] = [
        MenuLine(provider: "claude"),
        MenuLine(provider: "codex"),
        MenuLine(provider: "openrouter")
    ]
    /// A snapshot older than this is drawn dimmed.
    var staleAfterMinutes: Int = 360
    var colourScheme: BarColourScheme = .provider

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = MenuBarConfig()
        staleAfterMinutes = (try? c.decode(Int.self, forKey: .staleAfterMinutes)) ?? def.staleAfterMinutes
        colourScheme = (try? c.decode(BarColourScheme.self, forKey: .colourScheme)) ?? def.colourScheme
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
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(lines, forKey: .lines)
        try c.encode(staleAfterMinutes, forKey: .staleAfterMinutes)
        try c.encode(colourScheme, forKey: .colourScheme)
    }
}

struct Config: Codable {
    var language: Lang = .system
    var menuBar: MenuBarConfig = MenuBarConfig()
    var refreshSeconds: Int = 60
    /// Provider id -> shown or not. Missing key means shown.
    var enabled: [String: Bool] = [:]
    /// Off, and measured to be pointless as well as risky: the credential the
    /// CLI keeps is not an OAuth access token this endpoint accepts (tested
    /// 2026-08-23, HTTP 401 UNAUTHENTICATED), so getting a number would mean
    /// replicating the vendor client's own handshake. The code path is kept in
    /// case that ever changes; it fires only during a manual check, never on a
    /// timer.
    var agyDirectQuotaOnManualCheck: Bool = false
    /// A manual check reads Antigravity's own `/usage` panel by driving the CLI
    /// in a pseudo-terminal. Slow and never automatic - see AgyTUI.
    var agyQuotaViaTUI: Bool = true
    /// Path to the agy binary; empty means look in the usual places.
    var agyBinary: String = ""
    /// Colour-role overrides as "#RRGGBBAA". An absent role keeps the adaptive
    /// default. See Palette.
    var colours: [String: String] = [:]
    /// Per-provider check interval in seconds. 0 means "only when I ask".
    /// A missing entry falls back to `refreshSeconds`.
    ///
    /// Antigravity starts on manual: scheduled checks can only ever read its
    /// log, which never contains a number, so polling it buys nothing - and the
    /// request that does return a number is one to make by hand.
    var intervals: [String: Int] = ["agy": 0]
    var claudeProbeModel: String = "claude-haiku-4-5-20251001"
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

    init() {}

    /// Same reasoning as AccountSpec: every field falls back to its default so
    /// an old settings file is upgraded in place rather than thrown away.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Config()
        language = (try? c.decode(Lang.self, forKey: .language)) ?? def.language
        menuBar = (try? c.decode(MenuBarConfig.self, forKey: .menuBar)) ?? def.menuBar
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? def.refreshSeconds
        enabled = (try? c.decode([String: Bool].self, forKey: .enabled)) ?? def.enabled
        agyDirectQuotaOnManualCheck = (try? c.decode(Bool.self, forKey: .agyDirectQuotaOnManualCheck))
            ?? def.agyDirectQuotaOnManualCheck
        intervals = (try? c.decode([String: Int].self, forKey: .intervals)) ?? def.intervals
        agyQuotaViaTUI = (try? c.decode(Bool.self, forKey: .agyQuotaViaTUI)) ?? def.agyQuotaViaTUI
        agyBinary = (try? c.decode(String.self, forKey: .agyBinary)) ?? def.agyBinary
        colours = (try? c.decode([String: String].self, forKey: .colours)) ?? def.colours
        // Each service used to have one colour; it now has one per window.
        // An old key becomes the 5-hour colour rather than silently vanishing.
        for (key, value) in colours where key.hasPrefix("service.")
            && !key.hasSuffix(".5h") && !key.hasSuffix(".week") {
            colours[key + ".5h"] = value
            colours.removeValue(forKey: key)
        }
        claudeProbeModel = (try? c.decode(String.self, forKey: .claudeProbeModel)) ?? def.claudeProbeModel
        claudeRefreshViaCLI = (try? c.decode(Bool.self, forKey: .claudeRefreshViaCLI))
            ?? def.claudeRefreshViaCLI
        claudeBinary = (try? c.decode(String.self, forKey: .claudeBinary)) ?? def.claudeBinary
        accounts = (try? c.decode([String: [AccountSpec]].self, forKey: .accounts)) ?? def.accounts
    }

    static var dir: String { expand("~/.config/aimeter") }
    static var path: String { dir + "/config.json" }

    static func load() -> Config {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var cfg: Config
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = decoded
        } else {
            cfg = Config()
        }
        if cfg.accounts.isEmpty {
            cfg.accounts = Discovery.all()
            cfg.save()
        }
        // Applied here rather than at each call site: one of those call sites
        // was missed, and the only symptom was colours silently not applying.
        Palette.overrides = cfg.colours
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        writePrivate(data, to: Config.path)
    }

    func isEnabled(_ id: String) -> Bool { enabled[id] ?? true }

    /// How often this provider is checked, in seconds. 0 = only on request.
    func interval(_ providerID: String) -> Int { intervals[providerID] ?? refreshSeconds }

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

    /// ~/.codex, whatever CODEX_HOME points at, plus any pooled HOMEs.
    static func codex() -> [AccountSpec] {
        var out: [AccountSpec] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: expand("~/.codex")) {
            out.append(AccountSpec(name: "Default", home: expand("~")))
        }
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            let home = (ch as NSString).deletingLastPathComponent
            if !home.isEmpty, home != expand("~") {
                out.append(AccountSpec(name: "CODEX_HOME", home: home))
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
