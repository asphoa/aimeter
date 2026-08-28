import AppKit
import Foundation

// MARK: - GenericProvider: the security property fixed across v1.0.1–v1.0.3
//
// This is the highest-value coverage in the suite. The bug took three rounds
// to close (v1.0.1 constrained the credential's source and left its
// destination in the settings file; v1.0.2 only redacted half of a repeated
// log line; v1.0.3 bound the destination to the keychain and validated the
// path) - three rounds each caught by a person or a second reviewer reading
// the code, not by a test. These are the attack payloads from that audit,
// pinned so a future edit cannot reopen the hole silently.

func testGenericProviderURLSafety() {
    // A legitimate base and path resolve, and the host is exactly the
    // approved one - this is the property everything else is checking for.
    if let (comps, host) = GenericProvider.approvedHost(from: "https://api.opentyphoon.ai"),
       let url = GenericProvider.safeURL(comps: comps, host: host, path: "/v1/credits") {
        T.eq("legit base+path: host", url.host, "api.opentyphoon.ai")
        T.eq("legit base+path: scheme", url.scheme, "https")
        T.eq("legit base+path: path", url.path, "/v1/credits")
    } else {
        T.check("legit base+path should resolve", false)
    }

    // Query strings survive without disturbing the host.
    if let (comps, host) = GenericProvider.approvedHost(from: "https://api.example.com"),
       let url = GenericProvider.safeURL(comps: comps, host: host, path: "/v1/credits?scope=all") {
        T.eq("query preserved: host", url.host, "api.example.com")
        T.eq("query preserved: query", url.query, "scope=all")
    } else {
        T.check("path with query should resolve", false)
    }

    // approvedHost: only https, only a real host.
    T.isNil("http base rejected", GenericProvider.approvedHost(from: "http://api.example.com"))
    T.isNil("scheme-less base rejected", GenericProvider.approvedHost(from: "api.example.com"))
    T.isNil("empty base rejected", GenericProvider.approvedHost(from: ""))
    T.isNil("ftp base rejected", GenericProvider.approvedHost(from: "ftp://api.example.com"))

    // The attacker payloads verified by hand during the audit. Each one must
    // fail to produce a URL - not merely produce one with the "wrong" host,
    // because a redirection that silently succeeds is exactly the bug.
    let approved = GenericProvider.approvedHost(from: "https://api.opentyphoon.ai")!

    func attack(_ name: String, _ path: String) {
        T.isNil(name, GenericProvider.safeURL(comps: approved.comps, host: approved.host, path: path))
    }
    // userinfo rewrite: the classic "https://good.com@evil.com/" shape,
    // expressed as a path since the host itself is already fixed here.
    attack("@ in path (userinfo rewrite)", "@attacker.example.com/collect")
    attack("@ later in path", "/v1/credits@attacker.example.com")
    // new-authority shapes
    attack("// starts a new authority", "//attacker.example.com/collect")
    attack("scheme switch mid-path", "https://attacker.example.com/collect")
    attack("scheme switch, different case", "HTTPS://attacker.example.com/collect")
    // must be an absolute path
    attack("relative path (no leading slash)", "v1/credits")
    attack("empty path", "")
    // control characters and encoding tricks that were tested by hand
    attack("CRLF in path", "/v1/credits\r\nHost: attacker.example.com")
    attack("NUL byte in path", "/v1/credits\u{0000}@attacker.example.com")

    // Final structural invariant: whatever gets through, the resulting URL's
    // host is never anything other than the approved one. Belt-and-braces on
    // top of the guards above, and cheap to keep.
    let benignPaths = ["/", "/v1", "/v1/credits", "/a/b/c?x=1&y=2", "/%20encoded"]
    for p in benignPaths {
        if let url = GenericProvider.safeURL(comps: approved.comps, host: approved.host, path: p) {
            T.eq("host invariant holds for \(p)", url.host, approved.host)
        }
    }
}

// MARK: - AgyTUI: three bugs found only by driving the real client
//
// Each of these failed silently the first time: the ANSI-stripping regex
// matched nothing because \u{1B} in a raw string is five literal characters,
// not an escape byte; the parser saw a heading glued to the line beneath it
// because the captured text mixed CRLF and lone CR; the fix for the first
// diagnostic dump masked only one of the two places the client prints the
// account address. None of these were visible from reading the code - only
// from capturing a real screen and looking at the bytes.

func testAgyTUIStripRemovesEscapeSequences() {
    // A CSI sequence (colour), an OSC sequence (window title), and plain text
    // in between - the three shapes the client actually emits.
    let raw = "\u{1B}[38;5;179mhello\u{1B}[m \u{1B}]0;window title\u{07}world"
    let clean = AgyTUI.strip(raw)
    T.check("no ESC bytes remain", !clean.contains("\u{1B}"), clean)
    T.check("plain text survives", clean.contains("hello") && clean.contains("world"), clean)
}

func testAgyTUIStripLeavesPlainTextUnchanged() {
    let plain = "GEMINI MODELS\nWeekly Limit Remaining\n  99.76%\n"
    T.eq("plain text passes through", AgyTUI.strip(plain), plain)
}

func testAgyTUIParseHandlesMixedLineEndings() {
    // A synthetic panel shaped like the real capture, once with CRLF and once
    // with lone CR only - the terminal mixes both, and splitting on \n alone
    // (the original bug) glues a heading to the line beneath it.
    func panel(_ nl: String) -> String {
        [
            "  Account: khan.asphodelus@gmail.com",
            "GEMINI MODELS",
            "  Models within this group: Gemini Flash, Gemini Pro",
            "  Weekly Limit Remaining",
            "    [██████████████████████████████████████████████████] 99.76%",
            "    100% remaining · Refreshes in 146h 43m",
            "  Five Hour Limit Remaining",
            "    [██████████████████████████████████████████████████] 100.00%",
            "    Quota available",
            "CLAUDE AND GPT MODELS",
            "  Weekly Limit Remaining",
            "    [██████████████████████████████████████████████████] 100.00%",
            "    Quota available",
            "  Five Hour Limit Remaining",
            "    [██████████████████████████████████████████████████] 100.00%",
            "    Quota available"
        ].joined(separator: nl)
    }

    for (label, text) in [("CRLF", panel("\r\n")), ("lone CR", panel("\r")), ("LF", panel("\n"))] {
        guard let result = AgyTUI.parse(text) else {
            T.check("\(label): parse succeeds", false)
            continue
        }
        T.eq("\(label): account", result.account, "khan.asphodelus@gmail.com")
        T.eq("\(label): group count", result.groups.count, 2)
        if let gemini = result.groups.first(where: { $0.name.contains("GEMINI") }) {
            T.near("\(label): Gemini weekly used%", gemini.weeklyUsed ?? -1, 0.24, tol: 0.01)
            T.near("\(label): Gemini 5h used%", gemini.fiveHourUsed ?? -1, 0.0, tol: 0.01)
            T.notNil("\(label): Gemini weekly reset date", gemini.weeklyResets)
        } else {
            T.check("\(label): GEMINI group present", false)
        }
    }
}

func testAgyTUIParseRejectsTextWithoutAPanel() {
    T.isNil("no panel -> nil", AgyTUI.parse("just some ordinary text\nwith no quota data"))
    T.isNil("empty text -> nil", AgyTUI.parse(""))
}

func testAgyTUIBinaryWhitelist() {
    // A configured path outside the three allowed locations must be rejected
    // even if the file exists and is executable - the whole point of the
    // whitelist is that the settings file cannot name an arbitrary binary.
    let outsider = "/tmp/aimeter-tests-not-agy-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: outsider, contents: Data("#!/bin/sh\n".utf8))
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outsider)
    defer { try? FileManager.default.removeItem(atPath: outsider) }

    T.isNil("executable outside whitelist is rejected", AgyTUI.binary(outsider))
    T.isNil("nonexistent configured path is rejected", AgyTUI.binary("/no/such/binary/anywhere"))
    // A path that happens to equal one of the allowed strings but does not
    // exist on this machine must not be returned as usable.
    T.check("allowedBinaries has exactly the three known locations",
           AgyTUI.allowedBinaries == ["~/.local/bin/agy", "/usr/local/bin/agy", "/opt/homebrew/bin/agy"])
}

// MARK: - trustedHome: the HOME-steering fix from the second audit round

func testTrustedHomeRequiresExistingMarkedDirectory() {
    let base = "/tmp/aimeter-tests-home-\(UUID().uuidString)"
    let marker = ".gemini/antigravity-cli"
    defer { try? FileManager.default.removeItem(atPath: base) }

    T.isNil("nonexistent directory rejected", trustedHome(base, marker: marker))

    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    T.isNil("directory without marker rejected", trustedHome(base, marker: marker))

    try? FileManager.default.createDirectory(atPath: base + "/" + marker, withIntermediateDirectories: true)
    T.eq("directory with marker, owned by this user, accepted",
        trustedHome(base, marker: marker) ?? "", base)

    // A file (not a directory) standing where the marker is expected must not
    // satisfy the check.
    let fileNotDir = "/tmp/aimeter-tests-home-file-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: fileNotDir, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: fileNotDir) }
    T.isNil("a plain file is not accepted as HOME", trustedHome(fileNotDir, marker: marker))
}

// MARK: - Palette hex round-trip

func testColourHexRoundTrip() {
    let cases: [(NSColor, String)] = [
        (NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), "#FF0000FF"),
        (NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), "#000000FF"),
        (NSColor(srgbRed: 0.898, green: 0.600, blue: 0.239, alpha: 1), "#E5993DFF")
    ]
    for (colour, _) in cases {
        let hex = colour.hexString
        guard let back = NSColor(hex: hex) else {
            T.check("hex \(hex) parses back", false)
            continue
        }
        guard let a = colour.usingColorSpace(.sRGB), let b = back.usingColorSpace(.sRGB) else {
            T.check("colour spaces convert", false)
            continue
        }
        T.near("round-trip red for \(hex)", Double(a.redComponent), Double(b.redComponent), tol: 0.01)
        T.near("round-trip green for \(hex)", Double(a.greenComponent), Double(b.greenComponent), tol: 0.01)
        T.near("round-trip blue for \(hex)", Double(a.blueComponent), Double(b.blueComponent), tol: 0.01)
    }
    T.isNil("garbage hex rejected", NSColor(hex: "not-a-colour"))
    T.isNil("wrong-length hex rejected", NSColor(hex: "#ABC"))
    T.notNil("hex without leading # accepted", NSColor(hex: "336699"))
}

// MARK: - Fmt

func testFmtMoney() {
    T.eq("USD formatting", Fmt.money(38.9, "USD"), "$38.90")
    T.eq("CNY formatting", Fmt.money(38.9, "CNY"), "¥38.90")
    T.eq("unknown currency falls back to code prefix", Fmt.money(5, "XYZ"), "XYZ 5.00")
    T.eq("zero formats cleanly", Fmt.money(0, "USD"), "$0.00")
}

func testFmtGB() {
    T.eq("exact gigabyte", Fmt.gb(1_073_741_824), "1.0 GB")
    T.eq("half a gigabyte", Fmt.gb(536_870_912), "0.5 GB")
    T.eq("zero bytes", Fmt.gb(0), "0.0 GB")
}

// MARK: - Config: tolerant decoding, and the colour-key migration

func testConfigDecodesMinimalJSON() {
    // An empty object must decode to full defaults rather than fail: this is
    // the property that lets an old settings file survive a newer build
    // adding fields, which the project relies on deliberately (see
    // AccountSpec/MenuLine/MenuBarConfig/Config's hand-written init(from:)).
    let data = Data("{}".utf8)
    guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        T.check("empty config decodes", false)
        return
    }
    T.eq("default refreshSeconds", cfg.refreshSeconds, 60)
    T.eq("default menu bar line count", cfg.menuBar.lines.count, 3)
    T.eq("default first line is claude", cfg.menuBar.lines.first?.provider ?? "", "claude")
}

func testConfigIgnoresUnknownFieldsAndFillsMissingOnes() {
    let json = """
    {"refreshSeconds": 120, "somethingFutureVersionAdded": {"x": 1},
     "accounts": {"claude": [{"name": "Work"}]}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("config with unknown field decodes", false)
        return
    }
    T.eq("known field applied", cfg.refreshSeconds, 120)
    T.eq("partial account spec fills defaults", cfg.accounts["claude"]?.first?.enabled ?? false, true)
    T.eq("missing colours default to empty", cfg.colours.count, 0)
}

func testConfigMigratesLegacyPerServiceColourKey() {
    // Before per-window colours, a service had one colour key. The migration
    // in Config.init(from:) must move it to the 5-hour role rather than
    // dropping a colour the user had deliberately set.
    let json = """
    {"colours": {"service.claude": "#FF0000FF", "text": "#00FF00FF"}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("config with legacy colour key decodes", false)
        return
    }
    T.eq("legacy key migrated to 5h role", cfg.colours["service.claude.5h"] ?? "", "#FF0000FF")
    T.isNil("legacy key removed after migration", cfg.colours["service.claude"])
    T.eq("non-service key untouched", cfg.colours["text"] ?? "", "#00FF00FF")
}

func testConfigDefaultsAndRoundTripsAdaptiveHueOffset() {
    // An old settings file predating the "Optimize colours" reroll button
    // has no adaptiveHueOffset at all - it must fall back to the same
    // default StatusStrip's adaptive scheme has always used, not to 0
    // (which would silently change everyone's existing adaptive palette on
    // upgrade even though nobody clicked anything).
    let old = """
    {"menuBar": {"lines": [{"provider": "claude", "account": "*", "gauge": "*"}]}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(old.utf8)) else {
        T.check("config without adaptiveHueOffset decodes", false)
        return
    }
    T.eq("missing offset defaults to the original constant", cfg.menuBar.adaptiveHueOffset, 218)

    // A stored reroll must survive a save/load cycle exactly - this is the
    // one field the whole button exists to persist.
    var rerolled = cfg
    rerolled.menuBar.adaptiveHueOffset = 47.5
    guard let data = try? JSONEncoder().encode(rerolled),
          let reloaded = try? JSONDecoder().decode(Config.self, from: data) else {
        T.check("config with a rerolled offset round-trips", false)
        return
    }
    T.eq("rerolled offset survives encode/decode", reloaded.menuBar.adaptiveHueOffset, 47.5)
}

func testConfigMigratesLegacyRowsToMenuLines() {
    // Before MenuLine existed, menuBar.rows held "provider/account/gauge"
    // strings. An old settings file with that shape should upgrade in place.
    let json = """
    {"menuBar": {"rows": ["claude/0/0", "codex/0/0", "claude/0/1"]}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("config with legacy rows decodes", false)
        return
    }
    T.eq("legacy rows collapse to one line per provider", cfg.menuBar.lines.count, 2)
    T.eq("provider order preserved", cfg.menuBar.lines.map(\.provider), ["claude", "codex"])
}

// MARK: - resolveStripLine: the menu bar strip's provider -> bar mapping

func gauge(_ percent: Double?, _ kind: GaugeKind, label: String = "g") -> Gauge {
    Gauge(label: label, percent: percent, text: percent.map { "\(Int($0))%" } ?? "-", kind: kind)
}

func testResolveStripLineSplitsTwoWindowsIntoTopAndBottom() {
    let reading = Reading(id: "claude", title: "Claude", gauges: [
        gauge(20, .shortWindow), gauge(74, .longWindow)
    ])
    let line = resolveStripLine(MenuLine(provider: "claude"), ["claude": [reading]], Config())
    T.near("top is the short window", line.top ?? -1, 20)
    T.near("bottom is the long window", line.bottom ?? -1, 74)
    T.isNil("no merged bar when both windows present", line.merged)
}

func testResolveStripLineMergesASingleWindowService() {
    // A truly single-window service must still draw as one full-height bar,
    // not as a pair with a mysteriously empty top half.
    let reading = Reading(id: "openrouter", title: "OpenRouter", gauges: [gauge(33, .longWindow)])
    let line = resolveStripLine(MenuLine(provider: "openrouter"), ["openrouter": [reading]], Config())
    T.near("single window merges", line.merged ?? -1, 33)
    T.eq("merged bar keeps the window it actually measured", line.mergedKind, .longWindow)
    T.isNil("no top half for a single-window service", line.top)
    T.isNil("no bottom half for a single-window service", line.bottom)
}

func testResolveStripLineHandlesSeveralSameWindowGauges() {
    // Several OpenRouter keys are all weekly caps - conceptually one
    // measurement, so the worst of them becomes a single merged bar rather
    // than several half-pairs.
    let reading = Reading(id: "openrouter", title: "OpenRouter", gauges: [
        gauge(10, .longWindow, label: "a"), gauge(38, .longWindow, label: "b")
    ])
    let line = resolveStripLine(MenuLine(provider: "openrouter"), ["openrouter": [reading]], Config())
    T.notNil("merged bar present for multiple same-window gauges", line.merged)
    T.isNil("no top half", line.top)
    T.isNil("no bottom half", line.bottom)
}

func testResolveStripLineKeepsAnExpiredWindowInATwoWindowShape() {
    // This is the real Codex shape after a cached 5-hour window resets: its
    // percentage is deliberately withdrawn, while the weekly one remains
    // accurate. The missing short half must not reclassify the service as a
    // single weekly bar.
    let now = Date()
    let reading = codexLikeReading(now: now)
    let line = resolveStripLine(MenuLine(provider: "codex"),
                                ["codex": [reading]], Config())
    T.isNil("expired short window is an empty top half", line.top)
    T.near("live weekly window stays in the bottom half", line.bottom ?? -1, 27)
    T.isNil("two-window shape never becomes a merged bar", line.merged)
}

func testResolveStripLineReturnsNoDataWhenProviderAbsent() {
    let line = resolveStripLine(MenuLine(provider: "deepseek"), [:], Config())
    T.check("absent provider has no data", !line.hasData)
}

func testResolveStripLineReturnsNoDataWhenGaugesHaveNoPercent() {
    // DeepSeek reports a balance, not a percentage - the strip must show the
    // "no data" dots rather than treating a missing percent as zero.
    let reading = Reading(id: "deepseek", title: "DeepSeek",
                          gauges: [Gauge(label: "Balance", percent: nil, text: "¥38.90")])
    let line = resolveStripLine(MenuLine(provider: "deepseek"), ["deepseek": [reading]], Config())
    T.check("a percent-less gauge yields no bar data", !line.hasData)
}

// MARK: - Credential: which token comes out of a blob holding several
//
// `Claude Code-credentials` carries the subscription's own OAuth under
// `claudeAiOauth` *and* an `mcpOAuth` directory with one entry per configured
// MCP server, each with an `accessToken` of its own — forty of them on the
// machine this was diagnosed on. Picking the wrong one sends a third party's
// token to api.anthropic.com and reports the resulting 401 as an expired
// Claude sign-in. Every entry happens to be empty today, so the bug is latent;
// these fixtures make it non-latent so a regression cannot hide behind that.

/// The real item's shape, with the MCP tokens filled in as they will be the
/// day the user authorises one of those servers.
private func claudeBlob(access: String = "sk-ant-oat-REAL",
                        expiresAt: Any? = 1_787_648_408_691,
                        refreshExpiresAt: Any? = 1_788_733_210_691) -> [String: Any] {
    var own: [String: Any] = ["accessToken": access, "refreshToken": "sk-ant-ort-REAL",
                              "scopes": ["user:inference"], "subscriptionType": "max"]
    if let expiresAt { own["expiresAt"] = expiresAt }
    if let refreshExpiresAt { own["refreshTokenExpiresAt"] = refreshExpiresAt }
    var mcp: [String: Any] = [:]
    for name in ["aaa-sorts-first", "linear", "notion", "zzz-sorts-last"] {
        mcp[name] = ["serverName": name, "accessToken": "mcp-token-\(name)",
                     "refreshToken": "mcp-refresh-\(name)",
                     "expiresAt": 1_000_000_000_000] as [String: Any]
    }
    return ["mcpOAuth": mcp, "claudeAiOauth": own]
}

func testCredentialPrefersTheSubscriptionTokenOverMCPTokens() {
    T.eq("subscription token wins over MCP tokens",
         Credential.unwrap(json: claudeBlob(), field: nil), "sk-ant-oat-REAL")

    // The assertion above can pass by luck: with two keys at the top level the
    // walk reaches one subtree first, and which one depends on a hash seed
    // fixed per process. The narrowing is what makes it not luck, so pin the
    // narrowing itself — `container` must hand back the subscription's own
    // object, never the blob that also holds `mcpOAuth`.
    let narrowed = Credential.container(claudeBlob(), field: nil) as? [String: Any]
    T.eq("container narrows to claudeAiOauth", narrowed?["refreshToken"] as? String, "sk-ant-ort-REAL")
    T.isNil("the narrowed object cannot see mcpOAuth at all", narrowed?["mcpOAuth"])

    // Not once — every time. Swift fixes its hash seed per process, so
    // repeating the *same* keys would only re-run one ordering; the server
    // names are varied instead, which is what actually moves `mcpOAuth` and
    // `claudeAiOauth` around relative to each other.
    var picks = Set<String>()
    for i in 0..<200 {
        var blob = claudeBlob()
        var mcp: [String: Any] = [:]
        for j in 0...(i % 7) {
            let name = "srv-\(i)-\(j)-\(UUID().uuidString)"
            mcp[name] = ["serverName": name, "accessToken": "mcp-token-\(name)"] as [String: Any]
        }
        blob["mcpOAuth"] = mcp
        picks.insert(Credential.unwrap(json: blob, field: nil) ?? "nil-\(i)")
    }
    T.eq("no MCP token is ever chosen, over 200 differently-shaped blobs",
         picks, ["sk-ant-oat-REAL"])

    // No MCP token may come out under any circumstance, including when the
    // subscription's own entry is the one that is empty.
    let hollow = Credential.unwrap(json: claudeBlob(access: ""), field: nil)
    T.check("an empty subscription token does not fall through to an MCP token",
            hollow == nil, "got \(String(describing: hollow))")

    // An explicit field still wins — this is how the DeepSeek account reads a
    // multi-key file, and narrowing must not have quietly taken that over.
    let multi: [String: Any] = ["deepseek": "ds-key", "openai": "oa-key"]
    T.eq("keyJSONField still selects its field", Credential.unwrap(json: multi, field: "deepseek"), "ds-key")
    T.eq("a flat blob without either container still resolves",
         Credential.unwrap(json: ["api_key": "flat-key"], field: nil), "flat-key")
}

func testCredentialExpiryReadsBothHalvesOfTheOAuthPair() {
    // Milliseconds, as Claude Code writes them: 2026-08-25T09:00:08.691Z and
    // 2026-09-06T22:20:10.691Z — the pair actually observed while diagnosing
    // this, an access token hours from expiry against a refresh token days from it.
    let e = Credential.expiry(json: claudeBlob(), field: nil)
    T.eq("access expiry read as milliseconds", e.access?.timeIntervalSince1970, 1_787_648_408.691)
    T.eq("refresh expiry read as milliseconds", e.refresh?.timeIntervalSince1970, 1_788_733_210.691)

    // refreshTokenExpiresAt must not be mistaken for expiresAt: they differ by
    // a prefix only, and reading the long one as the short one would hide
    // exactly the staleness this feature exists to report.
    T.check("the two are not the same value", e.access != e.refresh)

    // Seconds are told from milliseconds by magnitude, not by which app wrote it.
    let secs = Credential.expiry(json: claudeBlob(expiresAt: 1_787_648_408,
                                                  refreshExpiresAt: 1_788_733_210), field: nil)
    T.eq("a seconds stamp is not divided by a thousand", secs.access?.timeIntervalSince1970, 1_787_648_408)

    // A credential with no expiry recorded — a pasted API key — must never be
    // called expired, or the pre-flight check would refuse to probe forever.
    let none = Credential.expiry(json: ["api_key": "flat-key"], field: nil)
    T.isNil("a keyless blob has no access expiry", none.access)
    T.check("no recorded expiry is not an expired token", !none.accessExpired)
    T.check("no recorded expiry is not a live refresh token", !none.refreshAlive)

    // The two states the menu has to tell apart.
    let past = Date().timeIntervalSince1970 - 3600
    let future = Date().timeIntervalSince1970 + 86_400
    let stale = Credential.expiry(json: claudeBlob(expiresAt: past * 1000,
                                                   refreshExpiresAt: future * 1000), field: nil)
    T.check("stale access token is expired", stale.accessExpired)
    T.check("stale access token still has a live session", stale.refreshAlive)

    let dead = Credential.expiry(json: claudeBlob(expiresAt: past * 1000,
                                                  refreshExpiresAt: past * 1000), field: nil)
    T.check("a dead refresh token is a real sign-out", dead.accessExpired && !dead.refreshAlive)
}

// MARK: - Credential: the keyFile path narrows and field-matches like the
// keychain path, instead of running its own separate extraction
//
// Before this fix, `Credential.blob` handed a keyFile account's raw contents
// to `readKey`, which unwrapped the JSON itself and always discarded
// `a.keyJSONField` (called with `jsonField: nil`). That meant a keyFile blob
// holding more than one plausible token-shaped field could resolve to the
// wrong one — the exact class of bug `container`/`unwrap` exist to prevent on
// the keychain path — and `Credential.expiry` received an already-unwrapped
// string rather than the JSON object it expects, so it silently returned an
// empty `Expiry` for every keyFile-backed account.

/// Writes a JSON fixture under `.build/tests/tmp`, not `/tmp` - the latter is
/// unreachable from a compiled binary running inside this project's usual
/// sandbox, and a `try!` write there would abort the whole suite (no summary,
/// no later tests run) rather than fail just this one assertion the way
/// every other filesystem-touching test in this file does.
private func writeJSONFixture(_ obj: [String: Any]) -> String? {
    let dir = ".build/tests/tmp"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/aimeter-tests-keyfile-\(UUID().uuidString).json"
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil ? path : nil
}

func testCredentialKeyFileHonoursJSONFieldThroughTheSameNarrowing() {
    // Two providers' keys sharing one file, each with its own plausible
    // token-shaped field. Picking the wrong one would silently charge one
    // provider's usage against the other's account.
    guard let path = writeJSONFixture([
        "deepseek": ["api_key": "ds-real-key", "scope": "chat"],
        "openrouter": ["api_key": "or-real-key", "scope": "chat"]
    ]) else {
        T.check("could write the keyFile JSON fixture", false)
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    let deepseek = AccountSpec(name: "t", keyFile: path, keyJSONField: "deepseek")
    switch Credential.read(deepseek) {
    case .success(let v): T.eq("keyFile account honours its keyJSONField", v, "ds-real-key")
    case .failure(let e): T.check("keyFile read with a field should not fail", false, e.message)
    }

    let openrouter = AccountSpec(name: "t", keyFile: path, keyJSONField: "openrouter")
    switch Credential.read(openrouter) {
    case .success(let v):
        T.eq("a different keyJSONField on the same file resolves independently", v, "or-real-key")
    case .failure(let e): T.check("keyFile read with a field should not fail", false, e.message)
    }

    // `expiry()` must see the raw JSON object too, not an already-unwrapped
    // token string — this was the concrete symptom: `Credential.expiry`
    // silently returned an empty `Expiry` for every keyFile-backed account
    // because it could never parse a bare token string as JSON.
    guard let path2 = writeJSONFixture(["deepseek": ["api_key": "ds-real-key",
                                                     "expiresAt": 1_787_648_408_691]]) else {
        T.check("could write the second keyFile JSON fixture", false)
        return
    }
    defer { try? FileManager.default.removeItem(atPath: path2) }
    let e = Credential.expiry(AccountSpec(name: "t", keyFile: path2, keyJSONField: "deepseek"))
    T.eq("expiry() reads a keyFile account's JSON instead of always returning empty",
         e.access?.timeIntervalSince1970, 1_787_648_408.691)

    // A malformed JSON key file (truncated / half-written) must fail cleanly,
    // not fall through to sending the raw file body - secrets and all - as
    // the credential itself.
    let dir = ".build/tests/tmp"
    let badPath = dir + "/aimeter-tests-keyfile-\(UUID().uuidString).json"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: badPath,
                                   contents: Data("{\"deepseek\": {\"api_key\": \"ds-real-key\"".utf8))
    defer { try? FileManager.default.removeItem(atPath: badPath) }
    switch Credential.read(AccountSpec(name: "t", keyFile: badPath)) {
    case .success(let v):
        T.check("truncated JSON must not be read as a literal key", false, "got \(v)")
    case .failure: T.check("truncated JSON is reported as no token, not leaked as one", true)
    }
}

func testClaudeProviderSeparatesAStaleTokenFromARealSignOut() {
    // The CLI-refresh offer adds a line whose presence depends on whether a
    // claude binary happens to be installed on the machine running the tests.
    // Switched off here so these assertions test the message rather than the
    // machine; the offer has its own test below.
    var plain = Config()
    plain.claudeRefreshViaCLI = false
    let p = ClaudeProvider(cfg: plain)
    let acct = AccountSpec(name: "Claude Code", keychainService: "Claude Code-credentials")
    let past = Date(timeIntervalSinceNow: -3600)
    let future = Date(timeIntervalSinceNow: 86_400 * 12)

    // Access token stale, refresh token alive: the common case, and the one the
    // app used to mis-report. It must not tell the user to log in again.
    let stale = p.refused(acct, Credential.Expiry(access: past, refresh: future))
    T.eq("stale token: first line names the token, not the sign-in",
         stale.lines.first, L.t("c.stale"))
    T.eq("stale token: a second line says the session survives", stale.lines.count, 2)
    T.check("stale token: does not tell the user to log in again",
            !stale.lines.contains(L.t("c.expired")))

    // Refresh token dead too: this really is a sign-out.
    let dead = p.refused(acct, Credential.Expiry(access: past, refresh: past))
    T.eq("dead refresh token: the sign-in message", dead.lines, [L.t("c.expired")])

    // No expiry recorded at all — a pasted API key refused by the server. With
    // nothing to say about a session, fall back to the sign-in message rather
    // than inventing a reassurance.
    let unknown = p.refused(acct, Credential.Expiry())
    T.eq("unknown expiry falls back to the sign-in message", unknown.lines, [L.t("c.expired")])

    // Severity has to earn the same distinction the text already makes: a
    // one-second fix should not carry the same red-dot urgency as an actual
    // logout, or the message right next to it is undermined.
    T.eq("stale token reads as a warning, not an error", stale.state, .warn)
    T.eq("a real sign-out is still a failure", [dead.state, unknown.state], [.failure, .failure])
}

func testFindStringVisitsKeysInAStableOrder() {
    // Two matching keys at the same level: whichever is chosen, it must be the
    // same one every time, so that a wrong choice is a reproducible bug.
    let blob: [String: Any] = ["zebra": ["token": "z"], "alpha": ["token": "a"]]
    var seen = Set<String>()
    for _ in 0..<200 {
        seen.insert(findString(in: blob, names: ["token"]) ?? "nil")
    }
    T.eq("a tie between two subtrees resolves the same way every time", seen.count, 1)
}

// MARK: - ClaudeCLI: pressing the button the message tells the user to press

/// The whitelist is the whole of the protection. The settings file is plain
/// text, so a path taken from it unchecked would let anything able to edit that
/// file choose which binary this app runs, as the user.
func testClaudeCLIBinaryWhitelist() {
    let outsider = "/tmp/aimeter-test-claude-\(getpid())"
    FileManager.default.createFile(atPath: outsider, contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    defer { try? FileManager.default.removeItem(atPath: outsider) }

    T.check("the test's own binary really is executable",
            FileManager.default.isExecutableFile(atPath: outsider))
    T.isNil("executable outside whitelist is rejected", ClaudeCLI.binary(outsider))
    T.isNil("nonexistent configured path is rejected", ClaudeCLI.binary("/no/such/claude"))
    T.check("whitelist covers the installers' own destinations",
            ClaudeCLI.allowedBinaries == ["~/.local/bin/claude", "/usr/local/bin/claude",
                                          "/opt/homebrew/bin/claude", "~/.claude/local/claude"])
    // An empty configured path means "look in the usual places", not "run the
    // binary at the empty path" — the settings file stores it as "".
    T.check("empty configured path falls back to the search",
            ClaudeCLI.binary("") == ClaudeCLI.binary(nil))
}

/// Only the CLI's own credential may cause the CLI to be launched. Running it
/// for a pasted API key would spawn a subprocess that cannot possibly help,
/// since nothing about that key is refreshed by `claude` running.
func testClaudeCLIOnlyClaimsTheCLIsOwnCredential() {
    T.check("the CLI's keychain item counts",
            ClaudeCLI.ownsCLICredential(
                AccountSpec(name: "a", keychainService: "Claude Code-credentials")))
    // Not the file the CLI uses where there is no keychain: on macOS the CLI
    // writes the keychain, and a key-file account carries no expiry to trigger
    // this path with. See ClaudeCLI for the measurement.
    T.check("the credentials file is not accepted in the keychain's place",
            !ClaudeCLI.ownsCLICredential(
                AccountSpec(name: "a", keyFile: "~/.claude/.credentials.json")))
    T.check("a pasted key stored by this app does not",
            !ClaudeCLI.ownsCLICredential(
                AccountSpec(name: "a", keychainService: "AIMeter · claude · work")))
    T.check("an unrelated key file does not",
            !ClaudeCLI.ownsCLICredential(
                AccountSpec(name: "a", keyFile: "~/.config/anthropic/key")))
    T.check("an account with no credential source at all does not",
            !ClaudeCLI.ownsCLICredential(AccountSpec(name: "a")))
}

/// Measured 2026-08-25 against claude 2.1.243: started without USER, the same
/// binary reports `loggedIn: false` on a machine that is signed in, because its
/// keychain item is filed under the account name. Building the environment from
/// nothing — the habit inherited from AgyTUI — would therefore have produced a
/// button that ran the CLI, refreshed nothing, and reported the same stale
/// message as before. This test exists so that regresses loudly.
func testClaudeCLIEnvironmentCarriesWhatTheCredentialLookupNeeds() {
    let env = ClaudeCLI.environment(home: "/Users/someone", user: "someone", lang: "en_US.UTF-8")
    T.eq("USER is passed through", env["USER"], "someone")
    T.eq("LOGNAME matches USER", env["LOGNAME"], "someone")
    T.eq("HOME is the account's home", env["HOME"], "/Users/someone")
    // A menu click must not quietly download a new several-hundred-megabyte CLI.
    T.eq("the auto-updater is off", env["DISABLE_AUTOUPDATER"], "1")
    T.eq("non-essential traffic is off", env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1")
    // Built, not inherited: the parent's environment can point the CLI at a
    // different credential than the one this row is about.
    T.isNil("no API key is handed down", env["ANTHROPIC_API_KEY"])
    T.isNil("no config directory is handed down", env["CLAUDE_CONFIG_DIR"])
    T.eq("nothing else is smuggled in", Set(env.keys),
         Set(["HOME", "PATH", "USER", "LOGNAME", "LANG",
              "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]))
    T.isNil("an absent LANG is simply omitted",
            ClaudeCLI.environment(home: "/h", user: "u", lang: nil)["LANG"])
}

/// Read-only by name and by argument. This is the gate in front of the step
/// that costs something, so it must stay the local, free, cannot-open-a-browser
/// subcommand it is relied on for.
func testClaudeCLIStatusStaysTheReadOnlySubcommand() {
    T.eq("status arguments are the status subcommand",
         ClaudeCLI.statusArguments, ["auth", "status", "--json"])
}

/// The argument list that fixes the bug, pinned whole.
///
/// v1.0.10 ran `auth status` believing that starting the CLI refreshes its
/// token. Measured on 2026-08-27 against a genuinely expired token, it does not:
/// 0.45s, a normal report, and the same expired token still in the keychain. The
/// refresh happens when the CLI needs a working token for a live request, so the
/// second step has to be a real one-turn prompt.
///
/// Pinned as a whole list because every entry is load-bearing, and pinned again
/// item by item for the two that are load-bearing for reasons a reader of the
/// list would not guess.
func testClaudeCLIRefreshRunsARealButMinimalPrompt() {
    T.eq("the refresh arguments are exactly this", ClaudeCLI.refreshArguments, [
        "-p", ".",
        "--model", "haiku",
        "--safe-mode",
        "--tools", "",
        "--system-prompt", "Reply with the single character: .",
        "--effort", "low",
        "--max-budget-usd", "0.02",
        "--no-session-persistence",
        "--output-format", "json"
    ])

    let args = ClaudeCLI.refreshArguments
    // The one that keeps a menu-bar click from starting a Claude session with
    // Bash and Edit in the user's home directory. Everything else on the list is
    // about cost; this one is about what the subprocess is allowed to do.
    guard let tools = args.firstIndex(of: "--tools") else {
        return T.check("the tool set is pinned shut", false)
    }
    T.eq("no tools at all are available to the run", args[tools + 1], "")
    T.check("customisations are off, so no hook or MCP server runs from a click",
            args.contains("--safe-mode"))
    // A stale-token click is not the moment to discover that a permission
    // bypass was left on the list.
    T.check("nothing on the list bypasses permissions",
            !args.contains { $0.contains("dangerously") || $0.contains("bypass") })
    T.check("it is a one-turn print, not a session", args.contains("-p"))
    // Not claudeProbeModel: that comes out of the settings file, which this
    // project treats as untrusted, and a pinned dated id rots where an alias
    // does not.
    T.check("the model is the alias", args.contains("haiku"))
    T.check("a spend ceiling is set", args.contains("--max-budget-usd"))
    T.check("the run leaves no transcript behind", args.contains("--no-session-persistence"))
    // The reply is discarded, so the only thing the output has to support is
    // reading a failure off it.
    T.check("the result is machine-readable", args.contains("--output-format"))
}

/// A failure is only ever a message. What decides whether the refresh worked is
/// the keychain, read afterwards — asking the subprocess instead is exactly how
/// the broken version reported success at something it had not done.
func testClaudeCLIPromptFailureReadsTheRunWithoutJudgingIt() {
    let ok = #"{"is_error":false,"subtype":"success","result":".","api_error_status":null}"#
    T.isNil("a clean run has nothing to say",
            ClaudeCLI.promptFailure(output: ok, error: "", exitCode: 0))
    let refused = #"{"is_error":true,"subtype":"error","api_error_status":"401","result":"x"}"#
    T.eq("an API refusal is reported as itself",
         ClaudeCLI.promptFailure(output: refused, error: "", exitCode: 1), "401")
    // An older CLI rejects an argument it does not know, and says so on stderr.
    // Reporting a bare "exit 1" for that would leave no way to tell a rejected
    // flag from a network failure.
    T.eq("a rejected argument is quoted from stderr",
         ClaudeCLI.promptFailure(output: "", error: "error: unknown option '--effort'\n",
                                 exitCode: 1),
         "error: unknown option '--effort'")
    T.check("with nothing said at all, the exit code is the message",
            ClaudeCLI.promptFailure(output: "", error: "", exitCode: 1) == "exit 1")
    T.eq("a clean exit printing nothing usable is still a failure",
         ClaudeCLI.promptFailure(output: "not json", error: "", exitCode: 0),
         L.t("c.refresh.unreadable"))
    // A menu row is one line wide, and stderr is not.
    let flood = String(repeating: "x", count: 500)
    T.check("a wall of output is cut to one line that fits",
            (ClaudeCLI.promptFailure(output: "", error: flood, exitCode: 1) ?? "").count <= 161)
    T.check("multi-line output does not become a multi-line row",
            !(ClaudeCLI.promptFailure(output: "", error: "one\ntwo\n", exitCode: 1) ?? "x")
                .contains("\n"))
}

/// The CLI exits 1 both when it is signed out and when it fails, so the exit
/// code alone cannot decide the message. Measured: signed out prints
/// `"loggedIn": false` and exits 1, without offering to log in.
func testClaudeCLIOutcomeReadsTheReportNotJustTheExitCode() {
    let inJSON = #"{"loggedIn": true, "authMethod": "claude.ai", "subscriptionType": "max"}"#
    T.eq("a signed-in report is signedIn", ClaudeCLI.outcome(output: inJSON, exitCode: 0), .signedIn)
    let outJSON = #"{"loggedIn": false, "authMethod": "none"}"#
    T.eq("a signed-out report is signedOut, exit 1 notwithstanding",
         ClaudeCLI.outcome(output: outJSON, exitCode: 1), .signedOut)
    T.check("nothing printed is a failure, not a sign-out",
            ClaudeCLI.outcome(output: "", exitCode: 1) == .failed("exit 1"))
    T.check("output that is not the expected report is a failure",
            ClaudeCLI.outcome(output: "command not found", exitCode: 127) == .failed("exit 127"))
    T.check("a clean exit printing nothing usable is still a failure",
            ClaudeCLI.outcome(output: "{}", exitCode: 0) == .failed(L.t("c.refresh.unreadable")))
}

/// The status report names the account and its organisation. The dump exists to
/// be pasted somewhere while debugging, so it must not carry them.
func testClaudeCLIRedactsTheAccountFromTheDump() {
    let raw = #"{"loggedIn": true, "email": "someone@example.com", "orgId": "ede5df71-cafe", "orgName": "Someone Ltd", "subscriptionType": "max"}"#
    let safe = ClaudeCLI.redact(raw)
    T.check("the address is gone", !safe.contains("someone@example.com"))
    T.check("the organisation id is gone", !safe.contains("ede5df71-cafe"))
    T.check("the organisation name is gone", !safe.contains("Someone Ltd"))
    T.check("what the dump is for survives", safe.contains(#""subscriptionType": "max""#))
    T.check("and so does the field that decides the outcome", safe.contains(#""loggedIn": true"#))

    // The prompt run writes a second dump, and that one carries session
    // identifiers instead of an address.
    let run = #"{"is_error":false,"session_id":"82ac5c71-cafe","uuid":"4de032aa-cafe","subtype":"success"}"#
    let scrubbed = ClaudeCLI.redact(run)
    T.check("the session id is gone", !scrubbed.contains("82ac5c71-cafe"))
    T.check("the message uuid is gone", !scrubbed.contains("4de032aa-cafe"))
    T.check("what the dump is for survives here too", scrubbed.contains(#""is_error":false"#))
}

/// Runs the real binary — the free step only — because the plumbing both steps
/// share is the part no amount of string-pinning can vouch for.
///
/// `execute` builds the environment from nothing, drains two pipes, enforces a
/// timeout and writes a redacted dump. Step two differs from step one in its
/// argument list and in costing something; everything underneath is this code.
/// The failure this whole change is about was a causal claim nobody could test,
/// so the parts that *can* be tested are, on any machine that has the CLI.
///
/// Deliberately not the prompt step: a test suite must not spend the user's
/// window every time it runs. That step is verified by hand, with the same
/// arguments and the same from-scratch environment — measured 2026-08-27, 2.5s,
/// 264 input and 83 output tokens.
func testClaudeCLIActuallyRunsTheBinaryOnThisMachine() {
    guard let bin = ClaudeCLI.binary(nil) else { return }
    let home = trustedHome("~", marker: ".claude") ?? NSHomeDirectory()
    let outcome = ClaudeCLI.status(binary: bin, home: home)
    // Either answer means the subprocess started, spoke, and was understood.
    // What must not happen is `.failed`, which here would mean the environment
    // or the parsing is wrong — the 2026-08-25 USER bug, caught this way.
    switch outcome {
    case .signedIn, .signedOut:
        T.check("the real CLI ran and its report was understood", true)
    case .failed(let why):
        T.check("the real CLI ran and its report was understood (got: \(why))", false)
    }
    let dump = Config.dir + "/claude-cli-last.json"
    T.check("and the run left a dump to look at",
            FileManager.default.fileExists(atPath: dump))
    // The dump is the file most likely to be pasted somewhere while debugging.
    let text = (try? String(contentsOfFile: dump, encoding: .utf8)) ?? ""
    T.check("with no address in it", !text.contains("@") || text.contains("<redacted>"))
}

/// A stale row must say that the button can fix it — otherwise the button is
/// there and nothing tells the user it now does something. And when the feature
/// is off, or the account is not the CLI's, the offer must not be made.
func testClaudeProviderOffersTheRefreshOnlyWhenItCouldWork() {
    let past = Date(timeIntervalSinceNow: -3600)
    let future = Date(timeIntervalSinceNow: 86_400 * 12)
    let stale = Credential.Expiry(access: past, refresh: future)
    let cliAccount = AccountSpec(name: "Claude Code", keychainService: "Claude Code-credentials")
    let offer = L.t("c.refresh.offer")

    var off = Config()
    off.claudeRefreshViaCLI = false
    T.check("switched off, no offer is made",
            !ClaudeProvider(cfg: off).refused(cliAccount, stale).lines.contains(offer))

    var noBinary = Config()
    noBinary.claudeRefreshViaCLI = true
    // Pointed at a path the whitelist rejects, so there is no binary to run
    // whatever this machine happens to have installed.
    noBinary.claudeBinary = "/no/such/claude"
    T.check("with no usable binary, no offer is made",
            !ClaudeProvider(cfg: noBinary).refused(cliAccount, stale).lines.contains(offer))

    var on = Config()
    on.claudeRefreshViaCLI = true
    let pasted = AccountSpec(name: "work", keychainService: "AIMeter · claude · work")
    T.check("a pasted key is never offered a CLI run",
            !ClaudeProvider(cfg: on).refused(pasted, stale).lines.contains(offer))
    // A real sign-out is never offered a refresh: there is nothing to refresh.
    let dead = Credential.Expiry(access: past, refresh: past)
    T.check("a dead refresh token gets the sign-in message, not an offer",
            !ClaudeProvider(cfg: on).refused(cliAccount, dead).lines.contains(offer))
    // The remaining branch depends on a claude binary being installed, which is
    // a property of the machine rather than of the code — so it is asserted
    // where that holds instead of being faked.
    if ClaudeCLI.binary(nil) != nil {
        T.check("with the CLI present, the stale row says the button will run it",
                ClaudeProvider(cfg: on).refused(cliAccount, stale).lines.contains(offer))
    }
    // A note from an actual run replaces the offer: the user is told what just
    // happened, not invited to do again what has just been done.
    let noted = ClaudeProvider(cfg: on).refused(cliAccount, stale, note: L.t("c.refresh.stale"))
    T.check("a run's outcome is reported instead of the offer", !noted.lines.contains(offer))
    T.check("and the outcome itself is on the row", noted.lines.contains(L.t("c.refresh.stale")))
}

// MARK: - tailBytes: the half of the Codex complaint that was a real bug
//
// A byte-offset seek lands inside a character whenever the text there is not
// ASCII. Strict UTF-8 decoding then rejects the whole window, the caller sees
// no tail at all, and it moves on to an older file - so the newest reading in
// existence is skipped and an older one shown as current, with nothing logged
// because nothing failed. Measured across this machine's own Codex rollouts on
// 2026-08-27: 6% of the files over the window size decode to nil on their own
// tail.

func testTailBytesSurvivesACutInsideACharacter() {
    let dir = NSTemporaryDirectory() + "aimeter-tail-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/rollout.jsonl"

    let limit = 1024
    let newest = "{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":7}}}}"
    var strictFailures = 0
    for pad in 0..<3 {
        // Three-byte characters, shifted a byte at a time, so at least one of
        // these three cuts must fall inside one.
        let filler = String(repeating: "語", count: 900) + String(repeating: "x", count: pad)
        try? (filler + "\n" + newest + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        // What the old code did with this window, measured rather than assumed.
        let raw = FileManager.default.contents(atPath: path)!
        if String(data: raw.suffix(limit), encoding: .utf8) == nil { strictFailures += 1 }

        let tail = tailBytes(path, limit: limit)
        T.notNil("pad \(pad): a tail is returned", tail)
        T.check("pad \(pad): the newest record is in it",
                tail?.contains("rate_limits") == true)
    }
    T.check("the test actually exercises a mid-character cut", strictFailures > 0,
            "no alignment produced an invalid window")
}

func testTailBytesReadsASmallFileWhole() {
    // Below the window there is no cut to land badly, and the first line is a
    // real one - dropping it would lose the only record in a short log.
    let dir = NSTemporaryDirectory() + "aimeter-tail-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/short.jsonl"
    try? "第一行 rate_limits\nsecond\n".write(toFile: path, atomically: true, encoding: .utf8)
    T.check("the first line of a short file survives",
            tailBytes(path, limit: 512 * 1024)?.contains("第一行") == true)
}

// MARK: - Reading.asOf: the Codex accuracy complaint of 2026-08-27
//
// The numbers below are the real ones, taken off this machine's own session
// file (~/.codex/sessions/2026/08/26) and off ChatGPT's own usage panel at the
// same moment. The snapshot was captured 26 August 15:51 (+07); its weekly
// window reset at 1788314596 = 2 September, its five-hour window at
// 1787747461 = 26 August 19:31. Read the next morning, the weekly figure was
// still exactly right (27%, matching the panel) and the five-hour figure read
// 84% against a live 0%. One snapshot, one parse, two figures of completely
// different worth - which is the whole point of this function.

private func codexLikeReading(now: Date) -> Reading {
    var r = Reading(id: "codex", title: "Codex")
    r.snapshotAt = now.addingTimeInterval(-15 * 3600 - 16 * 60)   // "15h 16m ago"
    r.gauges = [
        Gauge(label: "5-hour window", percent: 84, text: "84%",
              resetsAt: now.addingTimeInterval(-11 * 3600 - 37 * 60), kind: .shortWindow),
        Gauge(label: "Weekly window", percent: 27, text: "27%",
              resetsAt: now.addingTimeInterval(6 * 86400 + 3600), kind: .longWindow)
    ]
    r.state = worstState(r.gauges)
    return r
}

func testAsOfWithdrawsAWindowThatHasAlreadyEnded() {
    let now = Date()
    let aged = codexLikeReading(now: now).asOf(now)

    T.check("expired window is marked", aged.gauges[0].expired)
    T.isNil("expired window carries no percentage", aged.gauges[0].percent)
    T.eq("expired window shows a dash", aged.gauges[0].text, "—")
    T.notNil("expired window keeps its reset time, to say when it ended",
             aged.gauges[0].resetsAt)

    // The half that was right stays right. Withdrawing both would have been a
    // different wrong answer: a week-long window 15 hours old is accurate.
    T.check("live window is untouched", !aged.gauges[1].expired)
    T.near("live window keeps its figure", aged.gauges[1].percent ?? -1, 27)
}

func testAsOfDropsTheColourTheDeadNumberWasDriving() {
    let now = Date()
    let before = codexLikeReading(now: now)
    T.eq("84% made the row amber to begin with", before.state, .warn)
    T.eq("and it is green once only the live 27% is left", before.asOf(now).state, .ok)
}

func testAsOfKeepsAStateSomethingElseSet() {
    // A provider failure with no gauge above 90 must survive expiry.
    // That is not the expired gauge talking, so it must survive the withdrawal.
    let now = Date()
    var r = codexLikeReading(now: now)
    r.state = .failure
    T.eq("a non-gauge failure is not cleared by expiry", r.asOf(now).state, .failure)
}

func testAsOfLeavesLiveReadingsAlone() {
    // Claude's reset time arrives in the same response as its percentage, so a
    // moment in the past there is clock skew, not a spent cycle. Blanking it
    // would break a row that was correct.
    let now = Date()
    var live = Reading(id: "claude", title: "Claude")
    live.gauges = [Gauge(label: "5-hour", percent: 55, text: "55%",
                         resetsAt: now.addingTimeInterval(-90), kind: .shortWindow)]
    T.near("a live reading keeps its figure", live.asOf(now).gauges[0].percent ?? -1, 55)
    T.check("and is never marked expired", !live.asOf(now).gauges[0].expired)

    // A snapshot whose window ended half a minute ago is inside the skew
    // grace: the two clocks are not the same clock, and a row must not flicker
    // to a dash at the moment of reset.
    var snap = live
    snap.snapshotAt = now.addingTimeInterval(-120)
    snap.gauges[0].resetsAt = now.addingTimeInterval(-30)
    T.check("a snapshot within the grace period is not expired",
            !snap.asOf(now).gauges[0].expired)
    snap.gauges[0].resetsAt = now.addingTimeInterval(-600)
    T.check("and is expired once well past it", snap.asOf(now).gauges[0].expired)
}

func testStripDrawsNoBarForAWindowThatHasEnded() {
    // The menu bar has no room to qualify anything, so an 84% bar there is the
    // same claim with none of the caveat. It must simply not be drawn, while
    // its empty half stays visible to preserve this service's two-window shape.
    let now = Date()
    let line = resolveStripLine(MenuLine(provider: "codex"),
                                ["codex": [codexLikeReading(now: now)]], Config())
    T.near("only the live window reaches the bottom half", line.bottom ?? -1, 27)
    T.isNil("no merged bar reclassifies the remaining weekly window", line.merged)
    T.isNil("no bar for the window that ended", line.top)
    T.check("the row is still flagged stale", line.stale)
}

// MARK: - distinct failures, quota warnings, and adaptive colour

func testNearLimitIsNotAFetchFailure() {
    let gauges = [Gauge(label: "quota", percent: 95, text: "95%", resetsAt: nil)]
    T.eq("90% is a near-limit state, not a fetch failure", worstState(gauges), .nearLimit)
    T.eq("near-limit uses the warning dot", stateColour(.nearLimit).hexString,
         NSColor.systemOrange.hexString)
    T.eq("a failed read alone uses the failure dot", stateColour(.failure).hexString,
         NSColor.systemRed.hexString)
}

func testCodexQuotaWireStatusesNeverReachTheUI() {
    let warning = CodexProvider.rateLimitStatus("allowed_warning")
    T.eq("allowed_warning becomes a warning", warning?.state, .warn)
    T.eq("allowed_warning is human language", warning.map { L.t($0.key) }, L.t("x.rate.allowedwarning"))
    let reached = CodexProvider.rateLimitStatus("rate_limit_reached")
    T.eq("a reached limit is near-limit, not fetch failure", reached?.state, .nearLimit)
    T.isNil("allowed needs no status line", CodexProvider.rateLimitStatus("allowed"))
    let unknown = CodexProvider.rateLimitStatus("future_wire_name")
    T.eq("unknown wire values are still not printed", unknown.map { L.t($0.key) }, L.t("x.rate.unknown"))
}

func testCodexSkipsAWindowlessRateLimitsEntry() {
    // Both shapes captured verbatim from a real ~/.codex/sessions rollout on
    // 2026-08-28: a normal "codex" entry with real numbers, immediately
    // followed later in the same file by a "premium" entry with both windows
    // null. newestSnapshot() used to take whichever line was textually last,
    // so this exact pair reported "no percentage field" with a usable
    // reading sitting one line above it.
    let usable: [String: Any] = [
        "limit_id": "codex",
        "primary": ["used_percent": 99.0, "window_minutes": 300, "resets_at": 1787894162],
        "secondary": ["used_percent": 16.0, "window_minutes": 10080, "resets_at": 1788480962]
    ]
    T.check("a normal codex entry has a usable window", CodexProvider.hasUsableWindow(usable))

    let windowless: [String: Any] = [
        "limit_id": "premium", "primary": NSNull(), "secondary": NSNull(),
        "plan_type": "plus", "rate_limit_reached_type": NSNull()
    ]
    T.check("a premium entry with both windows null has nothing to show",
            !CodexProvider.hasUsableWindow(windowless))

    // A window present but itself missing used_percent (a shape this has not
    // been seen to emit, but the check should not assume the field is always
    // there) must not be read as usable either.
    let noPercentField: [String: Any] = ["primary": ["window_minutes": 300, "resets_at": 0]]
    T.check("a window object without used_percent is not usable",
            !CodexProvider.hasUsableWindow(noPercentField))
}

func testAdaptivePaletteSeparatesLinesAndWindows() {
    let a = StatusStrip.adaptiveColour(index: 0, count: 5, kind: .shortWindow, critical: true)
    let b = StatusStrip.adaptiveColour(index: 1, count: 5, kind: .shortWindow, critical: true)
    let weekly = StatusStrip.adaptiveColour(index: 0, count: 5, kind: .longWindow, critical: true)
    let comfortable = StatusStrip.adaptiveColour(index: 0, count: 5, kind: .shortWindow, critical: false)
    T.check("critical lines keep distinct identities", a.hexString != b.hexString)
    T.check("weekly half differs from 5-hour half", a.hexString != weekly.hexString)
    T.check("critical differs from comfortable", a.hexString != comfortable.hexString)
}

func testPanelGaugeColoursKeepWindowIdentityAndSignalUrgency() {
    let shortLow = panelGaugeStyle(kind: .shortWindow, percent: 19)
    let shortHigh = panelGaugeStyle(kind: .shortWindow, percent: 97)
    let weeklyLow = panelGaugeStyle(kind: .longWindow, percent: 19)
    let weeklyHigh = panelGaugeStyle(kind: .longWindow, percent: 97)
    T.eq("5-hour identity does not change at the limit", shortLow.fill.hexString, shortHigh.fill.hexString)
    T.check("5-hour and weekly have stable distinct colours", shortLow.fill.hexString != weeklyLow.fill.hexString)
    T.eq("comfortable window has no urgency cap", Int(shortLow.alertWidth), 0)
    T.eq("near-limit window has a visible alarm cap", Int(weeklyHigh.alertWidth), 12)
    T.eq("near-limit cap uses the alarm colour", weeklyHigh.alert?.hexString ?? "", Palette.colour(Palette.alarm).hexString)
    T.eq("warning window has a smaller amber cap", Int(panelGaugeStyle(kind: .longWindow, percent: 70).alertWidth), 7)
    T.eq("untyped percentage preserves traffic-light urgency", panelGaugeStyle(kind: .other, percent: 97).fill.hexString,
         Palette.colour(Palette.alarm).hexString)
}

func testTimeoutDoesNotWaitForAnUncooperativeOperation() {
    let sem = DispatchSemaphore(value: 0)
    var elapsed = Double.infinity
    Task {
        let start = Date()
        _ = await withTimeout(0.05, {
            // This deliberately ignores cancellation for long enough to prove
            // the race does not wait for it, but it eventually resumes so the
            // harness leaves no leaked continuation diagnostic behind.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
                    continuation.resume(returning: Reading(id: "late", title: "late"))
                }
            }
        }, onTimeout: { .failed("test", "test", nil, "timeout") })
        elapsed = Date().timeIntervalSince(start)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 1)
    T.check("timeout returns without waiting for a stuck child", elapsed < 0.5,
            "returned after \(elapsed)s")
}

// MARK: - Every L.t("...") call site has a row
//
// m.ended/m.expired.hint shipped referenced in Model.swift/main.swift/
// PanelRows.swift but with no row in gen_l10n.py's table at all - four
// releases, 226 passing tests, and nobody noticed because L.t() falls back
// to printing the raw key rather than failing loudly, and it takes a
// specific locale plus a specific expired-window state to see it with your
// own eyes. This scans every call site in the real source tree against the
// real table, the same cross-check a person would have to do by hand.

func testEveryLocalizationCallSiteHasATableRow() {
    let root = "Sources/AIMeter"
    guard let enumerator = FileManager.default.enumerator(atPath: root) else {
        T.check("Sources/AIMeter is readable from the test working directory", false)
        return
    }
    // L.t("literal") and L.t("literal", ...) - not L.t(someVariable), which
    // is not this bug's shape and cannot be checked without evaluating code.
    guard let pattern = try? NSRegularExpression(pattern: #"L\.t\(\s*"([^"\\]+)""#) else {
        T.check("call-site regex compiles", false)
        return
    }
    var missing: [String: String] = [:]  // key -> "file:line"
    var filesScanned = 0
    for case let path as String in enumerator {
        guard path.hasSuffix(".swift") else { continue }
        let full = root + "/" + path
        guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
        filesScanned += 1
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            for m in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                guard !L.allKeys.contains(key) else { continue }
                missing[key] = "\(path):\(n + 1)"
            }
        }
    }
    T.check("scanned at least the known source files", filesScanned > 10, "\(filesScanned)")
    T.eq("every L.t(\"literal\") call site has a row in gen_l10n.py's table",
         missing.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }, [])
}

// MARK: - entry point
//
// @main rather than a plain main.swift: top-level executable statements are
// only allowed in a file literally named main.swift, and that name is already
// taken by the app itself (deliberately excluded from this build - see
// test.sh).

@main
struct Runner {
    static func main() {
        let start = Date()
        testGenericProviderURLSafety()
        testAgyTUIStripRemovesEscapeSequences()
        testAgyTUIStripLeavesPlainTextUnchanged()
        testAgyTUIParseHandlesMixedLineEndings()
        testAgyTUIParseRejectsTextWithoutAPanel()
        testAgyTUIBinaryWhitelist()
        testTrustedHomeRequiresExistingMarkedDirectory()
        testColourHexRoundTrip()
        testFmtMoney()
        testFmtGB()
        testConfigDecodesMinimalJSON()
        testConfigIgnoresUnknownFieldsAndFillsMissingOnes()
        testConfigMigratesLegacyPerServiceColourKey()
        testConfigDefaultsAndRoundTripsAdaptiveHueOffset()
        testConfigMigratesLegacyRowsToMenuLines()
        testResolveStripLineSplitsTwoWindowsIntoTopAndBottom()
        testResolveStripLineMergesASingleWindowService()
        testResolveStripLineHandlesSeveralSameWindowGauges()
        testResolveStripLineKeepsAnExpiredWindowInATwoWindowShape()
        testResolveStripLineReturnsNoDataWhenProviderAbsent()
        testResolveStripLineReturnsNoDataWhenGaugesHaveNoPercent()
        testCredentialPrefersTheSubscriptionTokenOverMCPTokens()
        testCredentialExpiryReadsBothHalvesOfTheOAuthPair()
        testCredentialKeyFileHonoursJSONFieldThroughTheSameNarrowing()
        testClaudeProviderSeparatesAStaleTokenFromARealSignOut()
        testClaudeCLIBinaryWhitelist()
        testClaudeCLIOnlyClaimsTheCLIsOwnCredential()
        testClaudeCLIEnvironmentCarriesWhatTheCredentialLookupNeeds()
        testClaudeCLIStatusStaysTheReadOnlySubcommand()
        testClaudeCLIRefreshRunsARealButMinimalPrompt()
        testClaudeCLIPromptFailureReadsTheRunWithoutJudgingIt()
        testClaudeCLIActuallyRunsTheBinaryOnThisMachine()
        testClaudeCLIOutcomeReadsTheReportNotJustTheExitCode()
        testClaudeCLIRedactsTheAccountFromTheDump()
        testClaudeProviderOffersTheRefreshOnlyWhenItCouldWork()
        testFindStringVisitsKeysInAStableOrder()
        testTailBytesSurvivesACutInsideACharacter()
        testTailBytesReadsASmallFileWhole()
        testAsOfWithdrawsAWindowThatHasAlreadyEnded()
        testAsOfDropsTheColourTheDeadNumberWasDriving()
        testAsOfKeepsAStateSomethingElseSet()
        testAsOfLeavesLiveReadingsAlone()
        testStripDrawsNoBarForAWindowThatHasEnded()
        testNearLimitIsNotAFetchFailure()
        testCodexQuotaWireStatusesNeverReachTheUI()
        testCodexSkipsAWindowlessRateLimitsEntry()
        testAdaptivePaletteSeparatesLinesAndWindows()
        testPanelGaugeColoursKeepWindowIdentityAndSignalUrgency()
        testTimeoutDoesNotWaitForAnUncooperativeOperation()
        testEveryLocalizationCallSiteHasATableRow()

        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "(%.2fs)", elapsed))
        exit(T.summary())
    }
}
