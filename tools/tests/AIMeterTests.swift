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
    // Codex only ever reports a weekly figure - this must draw as one
    // full-height bar, not a pair with a mysteriously empty top half.
    let reading = Reading(id: "codex", title: "Codex", gauges: [gauge(33, .longWindow)])
    let line = resolveStripLine(MenuLine(provider: "codex"), ["codex": [reading]], Config())
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

func testClaudeProviderSeparatesAStaleTokenFromARealSignOut() {
    let p = ClaudeProvider(cfg: Config())
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
    T.eq("a real sign-out is still an error", [dead.state, unknown.state], [.error, .error])
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
        testConfigMigratesLegacyRowsToMenuLines()
        testResolveStripLineSplitsTwoWindowsIntoTopAndBottom()
        testResolveStripLineMergesASingleWindowService()
        testResolveStripLineHandlesSeveralSameWindowGauges()
        testResolveStripLineReturnsNoDataWhenProviderAbsent()
        testResolveStripLineReturnsNoDataWhenGaugesHaveNoPercent()
        testCredentialPrefersTheSubscriptionTokenOverMCPTokens()
        testCredentialExpiryReadsBothHalvesOfTheOAuthPair()
        testClaudeProviderSeparatesAStaleTokenFromARealSignOut()
        testFindStringVisitsKeysInAStableOrder()

        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "(%.2fs)", elapsed))
        exit(T.summary())
    }
}
