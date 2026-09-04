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

// MARK: - AgyPrint: the print-mode `/usage` path (v1.0.28's main source)
//
// Fixture is a real capture (agy 1.1.26, 2026-09-04, n=3 measured) - no
// account, email, or credential in it, unlike the TUI's screen capture,
// which is exactly why print mode was chosen as the main path.

let agyUsageFixture = #"""
{"conversation_id":"","status":"SUCCESS","response":"Gemini Models\tWeekly Limit Remaining\t93%\t2026-09-11T01:25:50Z\nGemini Models\tFive Hour Limit Remaining\t97%\t2026-09-04T11:25:50Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-09-11T06:28:20Z\nClaude and GPT models\tFive Hour Limit Remaining\t100%\t2026-09-04T11:28:20Z\n","duration_seconds":0,"num_turns":0,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0},"command":{"name":"usage","data":{"description":"Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.","groups":[{"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","description":"You have used some of your weekly limit, it will fully refresh in 6 days, 18 hours.","window":"weekly","remaining_fraction":0.9287041425704956,"reset_time":"2026-09-11T01:25:50Z"},{"id":"gemini-5h","name":"Five Hour Limit Remaining","description":"You have used some of your 5-hour limit, it will fully refresh in 4 hours, 57 minutes.","window":"5h","remaining_fraction":0.9728128910064697,"reset_time":"2026-09-04T11:25:50Z"}]},{"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[{"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-09-11T06:28:20Z"},{"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":1,"reset_time":"2026-09-04T11:28:20Z"}]}]}}}
"""#

func testAgyPrintParsesTheMeasuredFixtureIntoTwoGroupsOfTwoPercents() {
    guard let result = AgyPrint.parse(Data(agyUsageFixture.utf8)) else {
        T.check("fixture parses", false)
        return
    }
    T.eq("two groups", result.groups.count, 2)
    guard let gemini = result.groups.first(where: { $0.name.contains("Gemini") }),
          let claudeGpt = result.groups.first(where: { $0.name.contains("Claude") }) else {
        T.check("both named groups present", false)
        return
    }
    T.near("Gemini weekly used%", gemini.weeklyUsed ?? -1, 7.1296, tol: 0.01)
    T.near("Gemini 5h used%", gemini.fiveHourUsed ?? -1, 2.7187, tol: 0.01)
    T.notNil("Gemini weekly reset parses", gemini.weeklyResets)
    T.notNil("Gemini 5h reset parses", gemini.fiveHourResets)
    T.near("Claude/GPT weekly used% at remaining_fraction 1", claudeGpt.weeklyUsed ?? -1, 0, tol: 0.001)
    T.near("Claude/GPT 5h used% at remaining_fraction 1", claudeGpt.fiveHourUsed ?? -1, 0, tol: 0.001)
}

func testAgyPrintRemainingFractionOneMeansZeroUsed() {
    let json = """
    {"status":"SUCCESS","command":{"data":{"groups":[{"name":"G","buckets":[
        {"window":"weekly","remaining_fraction":1,"reset_time":"2026-09-11T00:00:00Z"}
    ]}]}}}
    """
    guard let result = AgyPrint.parse(Data(json.utf8)), let g = result.groups.first else {
        T.check("single-bucket fixture parses", false)
        return
    }
    T.eq("remaining_fraction 1 -> 0 used", g.weeklyUsed, 0)
}

func testAgyPrintResetTimeParsesWithAndWithoutFractionalSeconds() {
    for reset in ["2026-09-11T01:25:50Z", "2026-09-11T01:25:50.123Z"] {
        let json = """
        {"status":"SUCCESS","command":{"data":{"groups":[{"name":"G","buckets":[
            {"window":"5h","remaining_fraction":0.5,"reset_time":"\(reset)"}
        ]}]}}}
        """
        guard let result = AgyPrint.parse(Data(json.utf8)), let g = result.groups.first else {
            T.check("\(reset): parses", false)
            continue
        }
        T.notNil("\(reset): 5h reset parses", g.fiveHourResets)
    }
}

func testAgyPrintStatusFailedYieldsNil() {
    let json = """
    {"status":"FAILED","command":{"data":{"groups":[{"name":"G","buckets":[
        {"window":"weekly","remaining_fraction":0.5,"reset_time":"2026-09-11T00:00:00Z"}
    ]}]}}}
    """
    T.isNil("status FAILED -> nil", AgyPrint.parse(Data(json.utf8)))
}

func testAgyPrintEmptyStdoutYieldsNil() {
    T.isNil("empty data -> nil", AgyPrint.parse(Data()))
}

func testAgyPrintMissingBucketsYieldsNil() {
    let json = """
    {"status":"SUCCESS","command":{"data":{"groups":[{"name":"G"}]}}}
    """
    T.isNil("group with no buckets -> nil", AgyPrint.parse(Data(json.utf8)))

    let emptyArray = """
    {"status":"SUCCESS","command":{"data":{"groups":[{"name":"G","buckets":[]}]}}}
    """
    T.isNil("group with an empty buckets array -> nil", AgyPrint.parse(Data(emptyArray.utf8)))
}

func testAgyPrintTSVTextModeIsNotParsedAsJSON() {
    // The same fixture's own "response" field - the TSV text the CLI would
    // print in its default (non-JSON) text mode - must not be mistaken for
    // the structured payload this parser expects.
    let tsv = "Gemini Models\tWeekly Limit Remaining\t93%\t2026-09-11T01:25:50Z\n"
    T.isNil("TSV text mode -> nil", AgyPrint.parse(Data(tsv.utf8)))
}

// MARK: - AgyProvider.refused: a real false positive found during this
// feature's own first live run (2026-09-04), pinned so it cannot come back.
//
// An early version scanned the CLI's log file for a bare "403" and it fired
// on a completely successful run: `keyringAuth: loaded token,
// expiry=2026-09-04 14:53:58.764034` - the fractional-seconds field
// `764034` contains the digits `403` by coincidence, and a real account got
// paused over a request that had actually succeeded. The fix drops the log
// scan entirely and checks only this run's own stderr, with `\b403\b`.

func testAgyProviderRefusedIgnoresADigitRunThatMerelyContains403() {
    // The exact string that caused the incident, verbatim.
    let timestampNoise = "keyringAuth: loaded token, expiry=2026-09-04 14:53:58.764034 +0700 +07 expired=false"
    T.check("764034's embedded 403 is not a refusal", !AgyProvider.refused(timestampNoise))
}

func testAgyProviderRefusedRecognisesAnActualHTTP403() {
    T.check("standalone 403 is a refusal", AgyProvider.refused("Error: HTTP 403 Forbidden"))
    T.check("403 at line start is a refusal", AgyProvider.refused("403: access denied"))
}

func testAgyProviderRefusedRecognisesPermissionDenied() {
    T.check("PERMISSION_DENIED is a refusal", AgyProvider.refused("rpc error: code = PERMISSION_DENIED"))
}

func testAgyProviderRefusedIsFalseForOrdinaryStderr() {
    T.check("empty stderr is not a refusal", !AgyProvider.refused(""))
    T.check("unrelated stderr text is not a refusal", !AgyProvider.refused("Warning: cache miss"))
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

// MARK: - Config: the "agy" interval migration (v1.0.28, owner decision
// 2026-09-04: the old default of 0 becomes 3600, once, for an existing
// settings file - see Config.migratingAgyInterval, called from load())

func testConfigDefaultAgyIntervalIsNowHourly() {
    let cfg = Config()
    T.eq("fresh config defaults \"agy\" interval to hourly", cfg.intervals["agy"], 3600)
    T.check("fresh config starts unmigrated", !cfg.agyIntervalMigrated)
}

func testConfigMigratesTheOldZeroAgyIntervalOnce() {
    var old = Config()
    old.intervals["agy"] = 0
    old.agyIntervalMigrated = false

    let migrated = Config.migratingAgyInterval(old)
    T.eq("old default 0 migrates to hourly", migrated.intervals["agy"], 3600)
    T.check("migration flag is set", migrated.agyIntervalMigrated)

    // The whole point of the flag: once migration has run, a 0 set on
    // purpose afterwards (going back to manual-only) must survive the next
    // launch rather than being silently reverted to 3600 again.
    var deliberate = migrated
    deliberate.intervals["agy"] = 0
    let untouched = Config.migratingAgyInterval(deliberate)
    T.eq("a deliberate 0 after migration is respected", untouched.intervals["agy"], 0)
    T.check("already-migrated config is returned unchanged (guard short-circuits)",
           untouched.agyIntervalMigrated)
}

func testConfigDecodingAnOldSettingsFileStillCarryingAgyDirectQuotaKeyIsTolerant() {
    // "agyDirectQuotaOnManualCheck" was removed in v1.0.28 (the direct HTTP
    // call it gated was dead code). An old settings file that still has the
    // key must decode without error - the same tolerant-decode property
    // every other removed/renamed field in this project relies on.
    let json = """
    {"agyDirectQuotaOnManualCheck": true, "intervals": {"agy": 0}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("config with the removed agy key still decodes", false)
        return
    }
    T.eq("the removed key's value has nowhere to land, and doesn't need one",
        cfg.intervals["agy"], 0)
}

// MARK: - RingIcon: pure model/colour/easing core

func testColourBandThresholds() {
    T.eq("69.9 -> ink", RingIcon.colourBand(69.9), .ink)
    T.eq("70 -> warn", RingIcon.colourBand(70), .warn)
    T.eq("89.9 -> warn", RingIcon.colourBand(89.9), .warn)
    T.eq("90 -> alarm", RingIcon.colourBand(90), .alarm)
}

func testRingModelPicksPrimarysShortAndUnscopedLongWindow() {
    var r = Reading(id: "claude", title: "Claude")
    r.gauges = [
        Gauge(label: "5h", percent: 53, text: "53%", kind: .shortWindow),
        Gauge(label: "week", percent: 11, text: "11%", kind: .longWindow),
        Gauge(label: "Fable", percent: 9, text: "9%", kind: .modelWindow)
    ]
    let model = RingIcon.model(readings: ["claude": [r]], primary: "claude")
    T.eq("outer = shortWindow", model.outer, 53)
    T.eq("inner = longWindow, ignores modelWindow", model.inner, 11)
}

func testRingModelPrimaryWithNoGaugesIsNilOuterAndInner() {
    let model = RingIcon.model(readings: [:], primary: "claude")
    T.isNil("no reading -> nil outer", model.outer)
    T.isNil("no reading -> nil inner", model.inner)
}

func testRingModelAlertDotOnlyFromNonPrimaryProvider() {
    var claude = Reading(id: "claude", title: "Claude")
    claude.gauges = [Gauge(label: "5h", percent: 95, text: "95%", kind: .shortWindow)]
    var codex = Reading(id: "codex", title: "Codex")
    codex.gauges = [Gauge(label: "5h", percent: 80, text: "80%", kind: .shortWindow)]
    let withOther = RingIcon.model(readings: ["claude": [claude], "codex": [codex]], primary: "claude")
    T.check("dot on: a non-primary provider is at 70%+", withOther.alertDot)

    let primaryOnly = RingIcon.model(readings: ["claude": [claude]], primary: "claude")
    T.check("dot off: only the primary is high", !primaryOnly.alertDot)
}

func testRingModelNumeralFormattingByStyle() {
    var r = Reading(id: "claude", title: "Claude")
    r.gauges = [Gauge(label: "5h", percent: 53, text: "53%", kind: .shortWindow)]
    let numeral = RingIcon.model(readings: ["claude": [r]], primary: "claude", style: "ringNumeral")
    T.eq("ringNumeral formats the outer percent", numeral.numeral, "53%")
    let ring = RingIcon.model(readings: ["claude": [r]], primary: "claude", style: "ring")
    T.isNil("ring style carries no numeral", ring.numeral)
}

func testEasedIsZeroToOneMonotoneAndEaseOut() {
    T.eq("eased(0) == 0", RingIcon.eased(0), 0)
    T.eq("eased(1) == 1", RingIcon.eased(1), 1)
    T.check("eased(0.5) > 0.5 (ease-out)", RingIcon.eased(0.5) > 0.5)
    var prev = -1.0
    for i in 0...10 {
        let t = Double(i) / 10
        let v = RingIcon.eased(t)
        T.check("eased is monotone at t=\(t)", v >= prev)
        prev = v
    }
}

func testMenuBarConfigStyleDefaultsSurviveAnOldConfigJSON() {
    let data = Data("{}".utf8)
    guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        T.check("empty config decodes", false)
        return
    }
    T.eq("default style is ring", cfg.menuBar.style, "ring")
    T.eq("default primary is claude", cfg.menuBar.primary, "claude")
    T.eq("default alertDot is on", cfg.menuBar.alertDot, true)
    T.eq("default animate is on", cfg.menuBar.animate, true)
}

func testRingImageSanityAndNoCrashOnNilValues() {
    let empty = RingIcon.image(for: RingIcon.RingModel())
    T.eq("no-data ring image is the plain 18x18 canvas", empty.size, NSSize(width: 18, height: 18))

    let withNumeral = RingIcon.image(for: RingIcon.RingModel(outer: 53, inner: 11, numeral: "53%"))
    T.check("numeral variant is wider than the plain ring",
           withNumeral.size.width > RingIcon.canvas)
    T.eq("numeral variant height stays the canvas height", withNumeral.size.height, RingIcon.canvas)

    let full = RingIcon.image(for: RingIcon.RingModel(outer: 93, inner: 40, alertDot: true, numeral: nil))
    T.check("drawing a full model does not crash", full.size.width > 0)
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

// MARK: - The keychain cache is stamped, not merely warm

// Both of these pin the property the repeating-password-panel fix is built on,
// and they run against the real keychain because that is the only place the
// property exists. Each uses an item of this app's own, under a fresh UUID
// service, and deletes it again; nothing here reads or writes anybody else's.

func testKeychainModificationDateIsReadableAndAbsentWhenTheItemIs() {
    T.isNil("no item, no modification date",
            Keychain.modified(service: "AIMeter · tests · \(UUID().uuidString)"))

    let svc = "AIMeter · tests · \(UUID().uuidString)"
    defer { Credential.delete(service: svc) }
    T.check("test item stored", Credential.store("first", service: svc))
    // The claim being pinned: this returns a date having decrypted nothing, so
    // it costs no authorisation and can be asked on every refresh. Measured
    // separately on 2026-08-30 with an ad-hoc probe that was in neither the
    // item's ACL nor its partition list - it answered, with no panel.
    T.notNil("an existing item has a modification date", Keychain.modified(service: svc))
}

func testCredentialCacheFollowsTheItemRatherThanTheProcess() {
    // ClaudeProvider used to drop this cache by hand on every refresh whose
    // token looked expired, because a rotation by the CLI had to be noticed
    // somehow. That is now the cache's own job, and this is the assertion that
    // made removing the hand-written drop safe: a rewritten item is picked up
    // on the next read, with nobody having called `invalidate`.
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }

    T.check("first value stored", Credential.store("token-one", service: svc))
    guard case .success(let first) = Credential.read(acct) else {
        return T.check("first read succeeds", false)
    }
    T.eq("first read returns what was stored", first, "token-one")

    guard case .success(let again) = Credential.read(acct) else {
        return T.check("second read succeeds", false)
    }
    T.eq("an unchanged item reads the same", again, "token-one")

    // The keychain records modification dates to the second, so a rewrite
    // inside the same second would be indistinguishable from no rewrite at all
    // - which is a real (and harmless) limit of this mechanism, not a flaw in
    // the test: it costs one extra refresh interval, once, in the second a
    // token happens to rotate.
    Thread.sleep(forTimeInterval: 1.2)
    T.check("second value stored", Credential.store("token-two", service: svc))

    guard case .success(let rotated) = Credential.read(acct) else {
        return T.check("post-rotation read succeeds", false)
    }
    T.eq("a rewritten item is picked up without invalidate()", rotated, "token-two")
}

// MARK: - A signed-out CLI is reported as signed out, not as a read failure

/// Observed 2026-09-02: Claude Code's keychain item read perfectly well and
/// held `accessToken: ""`, `expiresAt: 0` beside the usual account metadata -
/// the shape the CLI leaves behind when it is signed out (`claude auth status`
/// said `loggedIn: false`). The row said "could not obtain an access token",
/// which reads as this app failing, and offered nothing to do about it.
func testCredentialReportsABlankTokenAsASignOutNotAsAMissingOne() {
    // The pure predicate, on the shapes it has to tell apart.
    T.check("a blank subscription token is recognised",
            Credential.holdsBlankToken(json: claudeBlob(access: ""), field: nil))
    T.check("a real subscription token is not",
            !Credential.holdsBlankToken(json: claudeBlob(), field: nil))
    T.check("a blob with no token field at all is not",
            !Credential.holdsBlankToken(json: ["claudeAiOauth": ["subscriptionType": "max"]],
                                        field: nil))
    T.check("an MCP entry's blank token does not count as the subscription's",
            !Credential.holdsBlankToken(json: ["claudeAiOauth": ["accessToken": "ok"],
                                               "mcpOAuth": ["x": ["accessToken": ""]]],
                                        field: nil))
    T.check("keyJSONField narrows before the check, like everywhere else",
            Credential.holdsBlankToken(json: ["deepseek": ["api_key": ""], "other": ["api_key": "k"]],
                                       field: "deepseek"))

    // Through the real read path, on an item this app owns, so no panel.
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }
    func json(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }
    T.check("blank blob stored", Credential.store(json(claudeBlob(access: "")), service: svc))
    switch Credential.read(acct) {
    case .success(let s):
        T.check("a blank token is not handed out as a credential (got \(s))", false)
    case .failure(let e):
        T.check("the failure is marked blank", e.blank)
        T.eq("and worded as a blank credential, not a read failure",
             e.message, L.t("e.blanktoken"))
        T.check("and is not a denial", !e.denied)
    }

    // The item's own modification date moves on rewrite, so the cache lets
    // the sign-in back through without anyone calling invalidate().
    Thread.sleep(forTimeInterval: 1.2)
    T.check("real blob stored", Credential.store(json(claudeBlob()), service: svc))
    guard case .success(let token) = Credential.read(acct) else {
        return T.check("signing back in is picked up on the next read", false)
    }
    T.eq("signing back in is picked up on the next read", token, "sk-ant-oat-REAL")
}

// MARK: - "Check now" can put a refused panel back; a timer still cannot

/// v1.0.21 remembered a refusal against the item's modification stamp, so one
/// dismissed panel stopped being a panel a minute. Its row then told the user
/// to press "Check now" and choose "Always Allow" - and nothing on the manual
/// path forgot the refusal, so the button re-read the memory and did nothing
/// until Claude Code next rewrote the item. This pins the door that was missing.
// MARK: - Reading the CLI's own item through /usr/bin/security, not SecItemCopyMatching

/// The route through `/usr/bin/security` is scoped by an explicit allowlist,
/// not by any pattern match on the service string - a poisoned config.json
/// must not be able to widen it. Pure.
func testKeychainSecurityToolRouteIsAnAllowlistNotAPrefix() {
    T.check("the CLI's own item is on the list",
            Keychain.readsViaSecurityTool("Claude Code-credentials"))
    T.check("an AIMeter-owned item is not",
            !Keychain.readsViaSecurityTool("AIMeter · claude · x"))
    T.check("a service that merely starts with the CLI's name is not",
            !Keychain.readsViaSecurityTool("Claude Code-credentials-evil"))
    T.check("a service that is merely a prefix of the CLI's name is not",
            !Keychain.readsViaSecurityTool("Claude Code-credential"))
}

/// `securityToolPassword` has to read an item written the way the CLI writes
/// its own - through `security add-generic-password -U`, which leaves the
/// item's partition list as `apple-tool:` alone. Creating the throwaway item
/// with `SecItemAdd` instead (as `Credential.store` does, for AIMeter's own
/// items) would not exercise the same ACL shape and would raise this app's
/// usual in-process panel on read - the opposite of what this test needs to
/// prove. So this one shells out to `security` directly for setup too.
func testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt() {
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    // A space and a brace exercise both the newline-stripping path and the
    // "looks like JSON" branch a caller further up the stack takes on the
    // returned string - this call itself does no JSON parsing.
    let dummy = "not a real token {with a space}"

    let add = Process()
    add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    add.arguments = ["add-generic-password", "-a", "aimeter-tests", "-s", svc,
                     "-w", dummy, "-U"]
    add.standardOutput = Pipe()
    add.standardError = Pipe()
    guard (try? add.run()) != nil else {
        return T.check("could run /usr/bin/security to set up the test item", false)
    }
    add.waitUntilExit()
    guard add.terminationStatus == 0 else {
        return T.check("test item created with the CLI's own write path (exit \(add.terminationStatus))", false)
    }
    defer {
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", svc]
        del.standardOutput = Pipe()
        del.standardError = Pipe()
        try? del.run()
        del.waitUntilExit()
    }

    switch Keychain.securityToolPassword(service: svc) {
    case .success(let s):
        T.eq("reads back exactly what was stored, no trailing newline", s, dummy)
    case .failure(let e):
        T.check("security-tool read of an apple-tool:-partitioned item succeeds (\(e.message))", false)
    }

    let missingSvc = "AIMeter · tests · \(UUID().uuidString)"
    switch Keychain.securityToolPassword(service: missingSvc) {
    case .success: T.check("a never-created service should not be found", false)
    case .failure(let e):
        T.eq("a missing item is reported as k.missing",
             e.message, L.t("k.missing", missingSvc))
    }
}

func testCheckNowForgetsARefusalButKeepsTheToken() {
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }
    T.check("token stored", Credential.store("token-one", service: svc))
    guard let stamp = Keychain.modified(service: svc) else {
        return T.check("the item has a modification stamp", false)
    }

    // Plant the refusal a timer tick would have left behind.
    TokenCache.shared.clear(svc)
    TokenCache.shared.refuse(svc, stamp: stamp)
    switch Credential.read(acct) {
    case .success: T.check("a remembered refusal is honoured without a read", false)
    case .failure(let e):
        T.check("a remembered refusal is honoured without a read", e.denied)
        T.eq("in the words that promise the button will fix it", e.message, L.t("k.denied"))
    }

    // The button's door.
    Credential.forgetRefusal(acct)
    T.check("the refusal is forgotten", !TokenCache.shared.refused(svc, stamp: stamp))
    guard case .success(let got) = Credential.read(acct) else {
        return T.check("after forgetting, the item is read again", false)
    }
    T.eq("after forgetting, the item is read again", got, "token-one")

    // Forgetting a refusal must not throw away a token that was never refused:
    // a manual check on a healthy row would otherwise cost a fresh read, and
    // on the CLI's item a fresh read is a fresh panel.
    Credential.forgetRefusal(acct)
    T.eq("a cached token survives forgetRefusal",
         TokenCache.shared.value(svc, stamp: stamp), "token-one")
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

// MARK: - ClaudeProvider.readings(fromUsage:) — the /api/oauth/usage parser
//
// Fixture copied from the measured 2026-09-04 shape (CLI 2.1.260): session
// 39%, weekly_all 8%, one weekly_scoped entry for "Fable" at 9%.

private func usageFixture(limits: [[String: Any]] = [
    ["kind": "session", "group": "session", "percent": 39, "severity": "normal",
     "resets_at": "2026-09-04T15:00:00Z", "scope": NSNull(), "is_active": true],
    ["kind": "weekly_all", "group": "weekly", "percent": 8, "severity": "normal",
     "resets_at": "2026-09-08T00:00:00Z", "scope": NSNull(), "is_active": true],
    ["kind": "weekly_scoped", "group": "weekly", "percent": 9, "severity": "normal",
     "resets_at": "2026-09-08T00:00:00Z",
     "scope": ["model": ["id": NSNull(), "display_name": "Fable"], "surface": NSNull()],
     "is_active": true]
], extra: [String: Any]? = nil, fiveHour: [String: Any]? = nil, sevenDay: [String: Any]? = nil) -> [String: Any] {
    var obj: [String: Any] = ["limits": limits]
    if let extra { obj["extra_usage"] = extra }
    if let fiveHour { obj["five_hour"] = fiveHour }
    if let sevenDay { obj["seven_day"] = sevenDay }
    return obj
}

func testClaudeUsageParserReadsTheMeasuredThreeGaugeShape() {
    let (gauges, lines, state) = ClaudeProvider.readings(fromUsage: usageFixture())
    T.eq("three gauges", gauges.count, 3)
    T.eq("session label", gauges[0].label, L.t("g.5h"))
    T.eq("session kind", gauges[0].kind, .shortWindow)
    T.near("session percent", gauges[0].percent ?? -1, 39)
    T.notNil("session resets_at parsed", gauges[0].resetsAt)
    T.eq("weekly_all label", gauges[1].label, L.t("g.week"))
    T.eq("weekly_all kind", gauges[1].kind, .longWindow)
    T.near("weekly_all percent", gauges[1].percent ?? -1, 8)
    T.eq("weekly_scoped label carries the model name", gauges[2].label, L.t("g.week.model", "Fable"))
    T.eq("weekly_scoped kind is modelWindow, not longWindow", gauges[2].kind, .modelWindow)
    T.near("weekly_scoped percent", gauges[2].percent ?? -1, 9)
    T.check("no lines for an all-normal fixture", lines.isEmpty)
    T.eq("state stays ok", state, .ok)
}

func testClaudeUsageParserPreservesAnUnknownKindByItsRawName() {
    let obj = usageFixture(limits: [
        ["kind": "monthly_beta", "group": "monthly", "percent": 12, "severity": "normal",
         "resets_at": "2026-10-01T00:00:00Z", "scope": NSNull(), "is_active": true]
    ])
    let (gauges, _, _) = ClaudeProvider.readings(fromUsage: obj)
    T.eq("one gauge", gauges.count, 1)
    T.eq("unknown kind is never dropped silently — the raw kind is the label",
         gauges[0].label, "monthly_beta")
    T.eq("unknown kind maps to .other", gauges[0].kind, .other)
}

func testClaudeUsageParserAcceptsPercentAsIntDoubleOrString() {
    for (raw, name) in [(39 as Any, "Int"), (39.0 as Any, "Double"), ("39" as Any, "String")] {
        let obj = usageFixture(limits: [
            ["kind": "session", "group": "session", "percent": raw, "severity": "normal",
             "resets_at": "2026-09-04T15:00:00Z", "scope": NSNull(), "is_active": true]
        ])
        let (gauges, _, _) = ClaudeProvider.readings(fromUsage: obj)
        T.near("percent as \(name) parses", gauges.first?.percent ?? -1, 39)
    }
}

func testClaudeUsageParserExtraUsageGaugeOnlyWhenEnabled() {
    let enabled = usageFixture(extra: [
        "is_enabled": true, "monthly_limit": 1000, "used_credits": 0,
        "currency": "USD", "decimal_places": 2
    ])
    let (withExtra, _, _) = ClaudeProvider.readings(fromUsage: enabled)
    guard let extraGauge = withExtra.first(where: { $0.label == L.t("g.extra") }) else {
        T.check("extra_usage enabled produces a gauge", false); return
    }
    T.check("extra usage text is formatted as money",
            extraGauge.text.contains("$0.00") && extraGauge.text.contains("$10.00"),
            extraGauge.text)

    let disabled = usageFixture(extra: ["is_enabled": false, "monthly_limit": 1000,
                                        "used_credits": 0, "currency": "USD", "decimal_places": 2])
    let (withoutExtra, _, _) = ClaudeProvider.readings(fromUsage: disabled)
    T.check("extra_usage disabled adds no gauge",
            !withoutExtra.contains { $0.label == L.t("g.extra") })
}

func testClaudeUsageParserFallsBackToUnifiedWindowsWhenLimitsIsEmpty() {
    let obj = usageFixture(limits: [],
                           fiveHour: ["utilization": 55.0, "resets_at": "2026-09-04T15:00:00Z"],
                           sevenDay: ["utilization": 12.0, "resets_at": "2026-09-08T00:00:00Z"])
    let (gauges, _, _) = ClaudeProvider.readings(fromUsage: obj)
    T.eq("two gauges from the fallback", gauges.count, 2)
    T.near("five_hour utilization", gauges[0].percent ?? -1, 55)
    T.eq("five_hour kind", gauges[0].kind, .shortWindow)
    T.near("seven_day utilization", gauges[1].percent ?? -1, 12)
    T.eq("seven_day kind", gauges[1].kind, .longWindow)
}

func testClaudeUsageParserLockedReasonAddsALineAndNearLimitState() {
    let obj = usageFixture(fiveHour: ["utilization": 10.0, "resets_at": "2026-09-04T15:00:00Z",
                                      "locked_reason": "payment_failed"])
    let (_, lines, state) = ClaudeProvider.readings(fromUsage: obj)
    T.check("locked_reason produces a line",
            lines.contains(L.t("c.locked", "payment_failed")))
    T.eq("locked_reason escalates to nearLimit", state, .nearLimit)
}

// MARK: - strip classification regression: a scoped weekly must not become
// "the" weekly window (the exact shape of the v1.0.19 bug)

func testResolveStripLineIgnoresAModelScopedWeeklyEntry() {
    let reading = Reading(id: "claude", title: "Claude", gauges: [
        gauge(39, .shortWindow), gauge(8, .longWindow), gauge(9, .modelWindow, label: "Fable weekly window")
    ])
    let line = resolveStripLine(MenuLine(provider: "claude"), ["claude": [reading]], Config())
    T.near("top is still the session window", line.top ?? -1, 39)
    T.near("bottom is still the unscoped weekly window, not the scoped one", line.bottom ?? -1, 8)
    T.isNil("no merged bar — this is still the two-window shape", line.merged)
}

func testClaudeUsagePanelShowsAllThreeGaugesEvenThoughTheStripIgnoresOne() {
    // Regression pin for the panel side of the same fixture: the strip only
    // draws two bars, but the panel (which just iterates every gauge on the
    // reading) must still show all three.
    let (gauges, _, _) = ClaudeProvider.readings(fromUsage: usageFixture())
    T.eq("panel sees all three gauges", gauges.count, 3)
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

// MARK: - History: ledger line shape, append, retention, export

func testHistoryLineShapeForAGaugeAndAFailure() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var r = Reading(id: "claude", title: "Claude Code", account: "Work", state: .ok)
    let g = Gauge(label: "5-hour window", percent: 42.5, text: "42%",
                  resetsAt: now.addingTimeInterval(3600), kind: .shortWindow)
    r.gauges = [g]
    let line = History.line(for: r, gauge: g, at: now)
    guard let data = line.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        T.check("gauge line parses as JSON", false); return
    }
    T.eq("gauge line: provider", obj["provider"] as? String, "claude")
    T.eq("gauge line: account", obj["account"] as? String, "Work")
    T.eq("gauge line: gauge", obj["gauge"] as? String, "5-hour window")
    T.eq("gauge line: kind", obj["kind"] as? String, "shortWindow")
    T.eq("gauge line: percent", obj["percent"] as? Double, 42.5)
    T.eq("gauge line: state", obj["state"] as? Int, ReadingState.ok.rawValue)
    T.check("gauge line: t is ISO8601 UTC", (obj["t"] as? String)?.hasSuffix("Z") == true)
    T.check("gauge line: resets_at is ISO8601", (obj["resets_at"] as? String)?.hasSuffix("Z") == true)
    T.isNil("gauge line: snapshot_at is null when absent", obj["snapshot_at"] as? String)
    let noSecretKeys = Set(obj.keys).isDisjoint(with: ["token", "accessToken", "Authorization", "apiKey"])
    T.check("gauge line: no secret-looking keys", noSecretKeys)

    let failed = Reading.failed("codex", "Codex", nil, "Connection failed: timed out")
    let failLine = History.line(for: failed, gauge: nil, at: now)
    guard let fdata = failLine.data(using: .utf8),
          let fobj = (try? JSONSerialization.jsonObject(with: fdata)) as? [String: Any] else {
        T.check("failure line parses as JSON", false); return
    }
    T.eq("failure line: error", fobj["error"] as? String, "Connection failed: timed out")
    T.eq("failure line: state", fobj["state"] as? Int, ReadingState.failure.rawValue)
    T.isNil("failure line has no gauge key", fobj["gauge"] as? String)
}

func testHistoryAppendCreatesMonthlyFileWithModeAndTwoLines() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
    let r1 = Reading(id: "claude", title: "Claude Code",
                     gauges: [Gauge(label: "5-hour window", percent: 10, text: "10%", kind: .shortWindow)])
    let r2 = Reading(id: "claude", title: "Claude Code",
                     gauges: [Gauge(label: "5-hour window", percent: 20, text: "20%", kind: .shortWindow)])
    History.record([r1], at: now, dir: tmp)
    History.record([r2], at: now.addingTimeInterval(60), dir: tmp)

    let historyDir = tmp + "/history"
    var isDir: ObjCBool = false
    T.check("history dir exists", FileManager.default.fileExists(atPath: historyDir, isDirectory: &isDir) && isDir.boolValue)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: historyDir) {
        T.eq("history dir mode 0700", (attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    } else { T.check("history dir attrs readable", false) }

    let monthPath = historyDir + "/2023-11.jsonl"
    T.check("monthly file exists", FileManager.default.fileExists(atPath: monthPath))
    if let attrs = try? FileManager.default.attributesOfItem(atPath: monthPath) {
        T.eq("monthly file mode 0600", (attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    } else { T.check("monthly file attrs readable", false) }

    let content = (try? String(contentsOfFile: monthPath, encoding: .utf8)) ?? ""
    let lines = content.split(separator: "\n")
    T.eq("two records -> two lines", lines.count, 2)
    for l in lines {
        T.check("each line is valid JSON",
                 (try? JSONSerialization.jsonObject(with: Data(l.utf8))) != nil)
    }
}

func testHistoryRetentionDeletesOldMonthKeepsRecent() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let historyDir = tmp + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    func stamp(_ monthsAgo: Int) -> String {
        let d = cal.date(byAdding: .month, value: -monthsAgo, to: now)!
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }
    let old = historyDir + "/\(stamp(13)).jsonl"
    let recent = historyDir + "/\(stamp(11)).jsonl"
    FileManager.default.createFile(atPath: old, contents: Data("{}\n".utf8))
    FileManager.default.createFile(atPath: recent, contents: Data("{}\n".utf8))

    History.applyRetention(dir: tmp, months: 12, now: now)

    T.check("13-months-old file deleted", !FileManager.default.fileExists(atPath: old))
    T.check("11-months-old file kept", FileManager.default.fileExists(atPath: recent))
}

// MARK: - HistoryReport: export produces a self-contained, secret-free HTML+CSV

func testHistoryReportExportProducesHTMLAndCSVWithNoSecrets() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let now = Date()
    let claude = Reading(id: "claude", title: "Claude Code",
                         gauges: [Gauge(label: "5-hour window", percent: 30, text: "30%",
                                       resetsAt: now.addingTimeInterval(3600), kind: .shortWindow)])
    let codex = Reading(id: "codex", title: "Codex",
                        gauges: [Gauge(label: "Weekly window", percent: 55, text: "55%", kind: .longWindow)])
    History.record([claude], at: now.addingTimeInterval(-120), dir: tmp)
    History.record([codex], at: now.addingTimeInterval(-60), dir: tmp)

    let (csvPath, htmlPath) = HistoryReport.export(dir: tmp, providerTitle: { id in
        id == "claude" ? "Claude Code" : (id == "codex" ? "Codex" : id)
    })
    T.check("csv file exists", FileManager.default.fileExists(atPath: csvPath))
    T.check("html file exists", FileManager.default.fileExists(atPath: htmlPath))

    let html = (try? String(contentsOfFile: htmlPath, encoding: .utf8)) ?? ""
    T.check("html contains Claude Code title", html.contains("Claude Code"))
    T.check("html contains Codex title", html.contains("Codex"))
    for secret in ["Bearer", "sk-", "eyJ", "accessToken"] {
        T.check("html contains no \"\(secret)\"", !html.contains(secret))
    }
    T.check("html has at least one svg chart", html.contains("<svg"))

    let csv = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? ""
    let csvLines = csv.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
    // header + 2 ledger lines
    T.eq("csv row count = ledger lines + header", csvLines.count, 3)
}

// MARK: - Cursor: link-only row, never a strip slot

func testCursorProviderHasNoGaugesAndTheLinkLine() {
    let cfg = Config()
    let provider = CursorProvider(cfg: cfg)
    var readings: [Reading] = []
    let sem = DispatchSemaphore(value: 0)
    Task { readings = await provider.fetchAll(manual: false); sem.signal() }
    sem.wait()
    guard FileManager.default.fileExists(atPath: "/Applications/Cursor.app") else {
        T.check("no Cursor.app on this machine -> no reading", readings.isEmpty)
        return
    }
    guard let r = readings.first else { T.check("cursor produced a reading", false); return }
    T.check("cursor reading has no gauges", r.gauges.isEmpty)
    T.eq("cursor reading state is .off", r.state, .off)
    T.check("cursor reading carries the link line", r.lines.contains(L.t("x.cursor.link")))
}

func testResolveStripLineYieldsNoStripLineForAGaugelessCursorReading() {
    let reading = Reading.off("cursor", "Cursor", "Cursor", L.t("x.cursor.link"))
    let line = resolveStripLine(MenuLine(provider: "cursor"), ["cursor": [reading]], Config())
    T.check("a gaugeless off reading yields no bar data", !line.hasData)
}

// MARK: - PanelModel: the card panel's pure builder (v1.0.27)

func testPanelModelPrimaryPicksConfiguredProvider() {
    var codex = Reading(id: "codex", title: "Codex")
    codex.gauges = [Gauge(label: "5h", percent: 40, text: "40%", kind: .shortWindow)]
    var cfg = Config()
    cfg.menuBar.primary = "codex"
    let model = PanelModelBuilder.build(readings: ["codex": [codex]], cfg: cfg)
    T.eq("primary card is the configured provider", model.primary.providerId, "codex")
    T.eq("primary hero comes from that provider's gauge", model.primary.heroPercent, 40)
}

func testPanelModelHeroUsesShortWindowGauge() {
    var claude = Reading(id: "claude", title: "Claude")
    claude.gauges = [
        Gauge(label: "week", percent: 97, text: "97%", kind: .longWindow),
        Gauge(label: "5h", percent: 19, text: "19%", kind: .shortWindow)
    ]
    let model = PanelModelBuilder.build(readings: ["claude": [claude]], cfg: Config())
    T.eq("hero percent is the shortWindow gauge, not the first gauge", model.primary.heroPercent, 19)
    T.eq("hero window label follows the shortWindow gauge", model.primary.windowLabel, "5h")
}

func testPanelModelChipOrderIsLongThenModelSortedThenOther() {
    var claude = Reading(id: "claude", title: "Claude")
    claude.gauges = [
        Gauge(label: "5h", percent: 19, text: "19%", kind: .shortWindow),
        Gauge(label: "Extra usage", percent: 5, text: "5%", kind: .other),
        Gauge(label: "Zebra", percent: 3, text: "3%", kind: .modelWindow),
        Gauge(label: "week", percent: 97, text: "97%", kind: .longWindow),
        Gauge(label: "Alpha", percent: 9, text: "9%", kind: .modelWindow)
    ]
    let model = PanelModelBuilder.build(readings: ["claude": [claude]], cfg: Config())
    T.eq("chip order: longWindow, modelWindows sorted, then other",
         model.primary.chips.map(\.label), ["week", "Alpha", "Zebra", "Extra usage"])
}

func testPanelModelSecondaryOrderIsFixed() {
    let ids = ["cursor", "local", "agy", "deepseek", "openrouter", "codex", "zzzgeneric"]
    var readings: [String: [Reading]] = [:]
    for id in ids {
        var r = Reading(id: id, title: id)
        r.gauges = [Gauge(label: "x", percent: 10, text: "10%", kind: .other)]
        readings[id] = [r]
    }
    let model = PanelModelBuilder.build(readings: readings, cfg: Config())   // primary = claude, absent
    T.eq("secondary order: codex, openrouter, deepseek, agy, local, cursor, then others",
         model.secondaries.map(\.id), ["codex", "openrouter", "deepseek", "agy", "local", "cursor", "zzzgeneric"])
}

func testPanelModelSecondaryOrderExcludesThePrimary() {
    var codex = Reading(id: "codex", title: "Codex")
    codex.gauges = [Gauge(label: "5h", percent: 40, text: "40%", kind: .shortWindow)]
    var cfg = Config()
    cfg.menuBar.primary = "codex"
    let model = PanelModelBuilder.build(readings: ["codex": [codex]], cfg: cfg)
    T.check("the primary provider does not also appear as a secondary card",
           !model.secondaries.contains { $0.id == "codex" })
}

func testPanelModelFailureReadingYieldsTheAlarmMessage() {
    let failed = Reading.failed("claude", "Claude", nil, "Connection failed: timed out")
    let model = PanelModelBuilder.build(readings: ["claude": [failed]], cfg: Config())
    T.eq("primary state is .failure", model.primary.state, .failure)
    T.eq("primary failure message is the reading's first line",
         model.primary.failureMessage, "Connection failed: timed out")

    var cfg = Config()
    cfg.menuBar.primary = "somethingElse"
    let failedCodex = Reading.failed("codex", "Codex", nil, "HTTP 500")
    let model2 = PanelModelBuilder.build(readings: ["codex": [failedCodex]], cfg: cfg)
    guard let card = model2.secondaries.first(where: { $0.id == "codex" }) else {
        T.check("codex produced a secondary card", false); return
    }
    T.eq("secondary card state is .failure", card.state, .failure)
    T.eq("secondary card failure message is the reading's first line", card.failureMessage, "HTTP 500")
}

func testPanelModelMissingPrimaryYieldsTheNoDataState() {
    let model = PanelModelBuilder.build(readings: [:], cfg: Config())
    T.check("no reading at all -> primary has no data", !model.primary.hasData)
    T.eq("no reading at all -> primary state is .off", model.primary.state, .off)

    var otherOnly = Reading(id: "codex", title: "Codex")
    otherOnly.gauges = [Gauge(label: "5h", percent: 10, text: "10%", kind: .shortWindow)]
    let model2 = PanelModelBuilder.build(readings: ["codex": [otherOnly]], cfg: Config())
    T.check("primary's own id absent from readings -> no data even though others exist",
           !model2.primary.hasData)
}

// MARK: - PanelFormat: reset-time phrasing

func testPanelFormatResetTextPastIsEndedFutureIsUntilReset() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let future = now.addingTimeInterval(3600)
    let past = now.addingTimeInterval(-3600)
    T.isNil("no resetsAt -> no reset text", PanelFormat.resetText(nil, now: now))
    let futureText = PanelFormat.resetText(future, now: now) ?? ""
    T.check("future resetsAt reads \"until reset\"", futureText.contains("until reset"), futureText)
    let pastText = PanelFormat.resetText(past, now: now) ?? ""
    T.check("past resetsAt reads \"ended\"", pastText.contains("ended"), pastText)
}

// MARK: - Config: an old config.json without "panel" decodes as "cards"

func testConfigPanelDefaultsToCardsForAnOldConfigJSON() {
    let data = Data("{}".utf8)
    guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
        T.check("empty config decodes", false); return
    }
    T.eq("default menuBar.panel is \"cards\"", cfg.menuBar.panel, "cards")

    // A settings file with every other field already populated by an older
    // build, but no "panel" key at all - the exact shape this guards.
    let oldStyle = """
    {"menuBar": {"lines": [], "staleAfterMinutes": 360, "colourScheme": "provider",
     "adaptiveHueOffset": 218, "style": "ring", "primary": "claude", "alertDot": true, "animate": true}}
    """
    guard let cfg2 = try? JSONDecoder().decode(Config.self, from: Data(oldStyle.utf8)) else {
        T.check("pre-v1.0.27-shaped config decodes", false); return
    }
    T.eq("panel-less menuBar still defaults panel to \"cards\"", cfg2.menuBar.panel, "cards")
}

// MARK: - Sparkline: the primary card's trend samples

func testSparklineSamplesFiltersByProviderAndKind() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let iso = ISO8601DateFormatter()
    func line(_ provider: String, _ kind: String, _ pct: Double, _ t: Date) -> String {
        "{\"provider\":\"\(provider)\",\"kind\":\"\(kind)\",\"percent\":\(pct),\"t\":\"\(iso.string(from: t))\"}"
    }
    let lines = [
        line("claude", "shortWindow", 10, now.addingTimeInterval(-3600)),
        line("codex", "shortWindow", 99, now.addingTimeInterval(-3600)),      // wrong provider
        line("claude", "longWindow", 55, now.addingTimeInterval(-3600)),     // wrong kind
        line("claude", "shortWindow", 20, now.addingTimeInterval(-1800))
    ]
    let samples = Sparkline.samples(from: lines, provider: "claude", now: now)
    T.eq("only the matching provider+kind lines survive", samples.count, 2)
    T.check("no sample carries the wrong-provider or wrong-kind percent",
           !samples.contains { $0.1 == 99 || $0.1 == 55 })
}

func testSparklineSamplesIgnoresBadLines() {
    let now = Date()
    let iso = ISO8601DateFormatter()
    let good = "{\"provider\":\"claude\",\"kind\":\"shortWindow\",\"percent\":30,\"t\":\"\(iso.string(from: now))\"}"
    let lines = ["not json at all", "{\"provider\":\"claude\"}", "", good,
                 "{\"provider\":\"claude\",\"kind\":\"shortWindow\",\"percent\":null,\"t\":\"\(iso.string(from: now))\"}"]
    let samples = Sparkline.samples(from: lines, provider: "claude", now: now)
    T.eq("only the one well-formed line with a numeric percent survives", samples.count, 1)
}

func testSparklineSamplesRespectsTheTwentyFourHourWindow() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let iso = ISO8601DateFormatter()
    func line(_ t: Date) -> String {
        "{\"provider\":\"claude\",\"kind\":\"shortWindow\",\"percent\":50,\"t\":\"\(iso.string(from: t))\"}"
    }
    let lines = [line(now.addingTimeInterval(-25 * 3600)),  // too old
                 line(now.addingTimeInterval(-23 * 3600)),
                 line(now)]
    let samples = Sparkline.samples(from: lines, provider: "claude", now: now)
    T.eq("a line older than 24h is dropped", samples.count, 2)
}

func testSparklineSamplesDownsamplesToAtMostNinetySixAndStaysChronological() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let iso = ISO8601DateFormatter()
    var lines: [String] = []
    for i in 0..<500 {
        let t = now.addingTimeInterval(-Double(500 - i) * 100)   // ascending, within 24h
        lines.append("{\"provider\":\"claude\",\"kind\":\"shortWindow\",\"percent\":\(i % 100),"
                    + "\"t\":\"\(iso.string(from: t))\"}")
    }
    let samples = Sparkline.samples(from: lines, provider: "claude", now: now, maxPoints: 96)
    T.check("downsampled to at most 96 points", samples.count <= 96, "\(samples.count)")
    var prev = Date.distantPast
    var chronological = true
    for s in samples { if s.0 < prev { chronological = false }; prev = s.0 }
    T.check("samples stay in chronological order after downsampling", chronological)
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
        testAgyPrintParsesTheMeasuredFixtureIntoTwoGroupsOfTwoPercents()
        testAgyPrintRemainingFractionOneMeansZeroUsed()
        testAgyPrintResetTimeParsesWithAndWithoutFractionalSeconds()
        testAgyPrintStatusFailedYieldsNil()
        testAgyPrintEmptyStdoutYieldsNil()
        testAgyPrintMissingBucketsYieldsNil()
        testAgyPrintTSVTextModeIsNotParsedAsJSON()
        testAgyProviderRefusedIgnoresADigitRunThatMerelyContains403()
        testAgyProviderRefusedRecognisesAnActualHTTP403()
        testAgyProviderRefusedRecognisesPermissionDenied()
        testAgyProviderRefusedIsFalseForOrdinaryStderr()
        testAgyTUIBinaryWhitelist()
        testTrustedHomeRequiresExistingMarkedDirectory()
        testColourHexRoundTrip()
        testFmtMoney()
        testFmtGB()
        testConfigDecodesMinimalJSON()
        testConfigDefaultAgyIntervalIsNowHourly()
        testConfigMigratesTheOldZeroAgyIntervalOnce()
        testConfigDecodingAnOldSettingsFileStillCarryingAgyDirectQuotaKeyIsTolerant()
        testColourBandThresholds()
        testRingModelPicksPrimarysShortAndUnscopedLongWindow()
        testRingModelPrimaryWithNoGaugesIsNilOuterAndInner()
        testRingModelAlertDotOnlyFromNonPrimaryProvider()
        testRingModelNumeralFormattingByStyle()
        testEasedIsZeroToOneMonotoneAndEaseOut()
        testMenuBarConfigStyleDefaultsSurviveAnOldConfigJSON()
        testRingImageSanityAndNoCrashOnNilValues()
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
        testKeychainModificationDateIsReadableAndAbsentWhenTheItemIs()
        testKeychainSecurityToolRouteIsAnAllowlistNotAPrefix()
        testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt()
        testCredentialCacheFollowsTheItemRatherThanTheProcess()
        testCredentialReportsABlankTokenAsASignOutNotAsAMissingOne()
        testCheckNowForgetsARefusalButKeepsTheToken()
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
        testClaudeUsageParserReadsTheMeasuredThreeGaugeShape()
        testClaudeUsageParserPreservesAnUnknownKindByItsRawName()
        testClaudeUsageParserAcceptsPercentAsIntDoubleOrString()
        testClaudeUsageParserExtraUsageGaugeOnlyWhenEnabled()
        testClaudeUsageParserFallsBackToUnifiedWindowsWhenLimitsIsEmpty()
        testClaudeUsageParserLockedReasonAddsALineAndNearLimitState()
        testResolveStripLineIgnoresAModelScopedWeeklyEntry()
        testClaudeUsagePanelShowsAllThreeGaugesEvenThoughTheStripIgnoresOne()
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
        testHistoryLineShapeForAGaugeAndAFailure()
        testHistoryAppendCreatesMonthlyFileWithModeAndTwoLines()
        testHistoryRetentionDeletesOldMonthKeepsRecent()
        testHistoryReportExportProducesHTMLAndCSVWithNoSecrets()
        testCursorProviderHasNoGaugesAndTheLinkLine()
        testResolveStripLineYieldsNoStripLineForAGaugelessCursorReading()
        testPanelModelPrimaryPicksConfiguredProvider()
        testPanelModelHeroUsesShortWindowGauge()
        testPanelModelChipOrderIsLongThenModelSortedThenOther()
        testPanelModelSecondaryOrderIsFixed()
        testPanelModelSecondaryOrderExcludesThePrimary()
        testPanelModelFailureReadingYieldsTheAlarmMessage()
        testPanelModelMissingPrimaryYieldsTheNoDataState()
        testPanelFormatResetTextPastIsEndedFutureIsUntilReset()
        testConfigPanelDefaultsToCardsForAnOldConfigJSON()
        testSparklineSamplesFiltersByProviderAndKind()
        testSparklineSamplesIgnoresBadLines()
        testSparklineSamplesRespectsTheTwentyFourHourWindow()
        testSparklineSamplesDownsamplesToAtMostNinetySixAndStaysChronological()

        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "(%.2fs)", elapsed))
        exit(T.summary())
    }
}
