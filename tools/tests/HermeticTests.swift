import AppKit
import Foundation
import SwiftUI

// MARK: - RecipeURL: the security property fixed across v1.0.1–v1.0.3
//
// This is the highest-value coverage in the suite. The bug took three rounds
// to close (v1.0.1 constrained the credential's source and left its
// destination in the settings file; v1.0.2 only redacted half of a repeated
// log line; v1.0.3 bound the destination to the keychain and validated the
// path) - three rounds each caught by a person or a second reviewer reading
// the code, not by a test. These are the attack payloads from that audit,
// pinned so a future edit cannot reopen the hole silently.

func testRecipeURLSafety() {
    // A legitimate base and path resolve, and the host is exactly the
    // approved one - this is the property everything else is checking for.
    if let (comps, host) = RecipeURL.approvedHost(from: "https://api.opentyphoon.ai"),
       let url = RecipeURL.safeURL(comps: comps, host: host, path: "/v1/credits") {
        T.eq("legit base+path: host", url.host, "api.opentyphoon.ai")
        T.eq("legit base+path: scheme", url.scheme, "https")
        T.eq("legit base+path: path", url.path, "/v1/credits")
    } else {
        T.check("legit base+path should resolve", false)
    }

    // Query strings survive without disturbing the host.
    if let (comps, host) = RecipeURL.approvedHost(from: "https://api.example.com"),
       let url = RecipeURL.safeURL(comps: comps, host: host, path: "/v1/credits?scope=all") {
        T.eq("query preserved: host", url.host, "api.example.com")
        T.eq("query preserved: query", url.query, "scope=all")
    } else {
        T.check("path with query should resolve", false)
    }

    // approvedHost: only https, only a real host.
    T.isNil("http base rejected", RecipeURL.approvedHost(from: "http://api.example.com"))
    T.isNil("scheme-less base rejected", RecipeURL.approvedHost(from: "api.example.com"))
    T.isNil("empty base rejected", RecipeURL.approvedHost(from: ""))
    T.isNil("ftp base rejected", RecipeURL.approvedHost(from: "ftp://api.example.com"))

    // The attacker payloads verified by hand during the audit. Each one must
    // fail to produce a URL - not merely produce one with the "wrong" host,
    // because a redirection that silently succeeds is exactly the bug.
    let approved = RecipeURL.approvedHost(from: "https://api.opentyphoon.ai")!

    func attack(_ name: String, _ path: String) {
        T.isNil(name, RecipeURL.safeURL(comps: approved.comps, host: approved.host, path: path))
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
        guard let url = RecipeURL.safeURL(comps: approved.comps, host: approved.host, path: p) else {
            T.check("benign path \(p) must resolve", false)
            continue
        }
        T.eq("host invariant holds for \(p)", url.host, approved.host)
    }
}

func testRecipeDecodeTolerant() {
    let good = #"{"id":"typhoon","name":"Typhoon","credential":{"source":"none"},"fetch":{"method":"http","baseURL":"https://api.example.com","path":"/v1"},"map":{"format":"json","gauges":[]},"future":true}"#
    let recipe = try? JSONDecoder().decode(Recipe.self, from: Data(good.utf8))
    T.notNil("recipe tolerates missing symbol and map.lines plus unknown field", recipe)
    T.eq("missing map.lines is empty", recipe?.map.lines.count, 0)

    let bad = #"{"recipes":[{"id":"future","name":"Future","fetch":{"method":"telepathy"},"map":{}}]}"#
    let cfg = try? JSONDecoder().decode(Config.self, from: Data(bad.utf8))
    T.eq("unknown fetch method drops recipe", cfg?.recipes.count, 0)
    T.check("unknown fetch method records warning", cfg?.loadWarnings.isEmpty == false)
}

func testRecipeReservedIDRejected() {
    let json = #"{"recipes":[{"id":"claude","name":"Counterfeit","fetch":{"method":"none"},"map":{}}]}"#
    let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8))
    T.eq("reserved recipe is dropped", cfg?.recipes.count, 0)
    T.check("reserved recipe records warning", cfg?.loadWarnings.first?.contains("claude") == true)
}

func testRecipePinMatchHTTP() {
    var recipe = Recipe(id: "typhoon", name: "Typhoon",
        fetch: FetchSpec(method: "http", baseURL: "https://api.example.com", path: "/v1"))
    let pin = RecipePin.proposed(recipe)!
    T.check("matching HTTP pin", RecipePin.matches(recipe, pin))
    recipe.fetch.path = "/v2"
    T.check("HTTP path change does not match", !RecipePin.matches(recipe, pin))
    recipe.fetch.verb = "POST"
    recipe.fetch.path = "/v1"
    T.check("HTTP verb change does not match", !RecipePin.matches(recipe, pin))
    recipe.fetch.verb = "GET"
    recipe.fetch.baseURL = "https://evil.example"
    T.check("different HTTP host does not match", !RecipePin.matches(recipe, pin))
}

func testRecipePinMatchCLI() {
    var recipe = Recipe(id: "command", name: "Command",
        fetch: FetchSpec(method: "cli", binary: "/opt/homebrew/bin/agy", args: ["-p", "/usage"]))
    let pin = RecipePin.proposed(recipe)!
    T.check("matching CLI pin", RecipePin.matches(recipe, pin))
    recipe.fetch.args[1] = "/quota"
    T.check("changed CLI args do not match", !RecipePin.matches(recipe, pin))
}

func testRecipeCLIBinaryMustBeUnderAllowedRoots() {
    T.isNil("tmp binary rejected", CommandRun.allowedBinary("/tmp/x"))
    T.eq("Homebrew binary accepted", CommandRun.allowedBinary("/opt/homebrew/bin/agy"),
         "/opt/homebrew/bin/agy")
    T.isNil("parent traversal rejected", CommandRun.allowedBinary("/opt/homebrew/bin/../evil"))
    T.isNil("security tool explicitly unavailable", CommandRun.allowedBinary("/usr/bin/security"))
}

func testRecipeFileGlobCannotEscapeFolder() {
    T.check("ordinary recursive glob accepted", RecipeFetch.fileGlobIsSafe("**/*.jsonl"))
    T.check("parent traversal glob rejected", !RecipeFetch.fileGlobIsSafe("../../.ssh/*"))
}

func testRecipeMapPathSubset() {
    let obj: [String: Any] = ["data": ["limit": 25.0],
        "buckets": [["remaining_fraction": 0.9], ["remaining_fraction": 0.25]],
        "nested": ["credits": 12.0]]
    T.eq("object JSONPath", RecipeMap.value(at: "$.data.limit", in: obj) as? Double, 25)
    T.eq("array JSONPath", RecipeMap.value(at: "$.buckets[1].remaining_fraction", in: obj) as? Double, 0.25)
    T.eq("bare key recursive search", RecipeMap.value(at: "credits", in: obj) as? Double, 12)
    T.isNil("recursive descent rejected", RecipeMap.value(at: "$..x", in: obj))
    T.isNil("filter expression rejected", RecipeMap.value(at: "$[?()]", in: obj))
}

func testRecipeMapUsedLimitToPercent() {
    let map = MapSpec(gauges: [GaugeSpec(label: "Used", used: "$.used", limit: "$.limit")])
    let reading = RecipeMap.apply(map, to: Data(#"{"used":25,"limit":100}"#.utf8))
    T.near("used over limit becomes used percent", reading.gauges.first?.percent ?? -1, 25)
}

func testRecipeMapRemainingFraction() {
    let map = MapSpec(gauges: [GaugeSpec(label: "Left", remaining: "$.left", unit: "fraction")])
    let reading = RecipeMap.apply(map, to: Data(#"{"left":0.2}"#.utf8))
    T.near("remaining fraction becomes used percent", reading.gauges.first?.percent ?? -1, 80)
}

func testRecipeMapValueMoney() {
    let map = MapSpec(gauges: [GaugeSpec(label: "Balance", value: "$.credits", unit: "usd")])
    let reading = RecipeMap.apply(map, to: Data(#"{"credits":12.5}"#.utf8))
    T.isNil("money has no percentage", reading.gauges.first?.percent)
    T.eq("money uses Fmt.money", reading.gauges.first?.text, "$12.50")
}

func testRecipeMapMissingIsWarnNotZero() {
    let map = MapSpec(gauges: [GaugeSpec(label: "Missing", value: "$.missing", unit: "percent")])
    let reading = RecipeMap.apply(map, to: Data(#"{"other":0}"#.utf8))
    T.eq("missing mapping warns", reading.state, .warn)
    T.eq("missing mapping emits no gauge", reading.gauges.count, 0)
    T.check("missing mapping says unknown", reading.lines.contains(L.t("a.unknown")))
}

func testRecipeLegacyGenericEquivalence() {
    let spec = AccountSpec(name: "Old", keychainService: "AIMeter · generic · Old",
                           baseURL: "https://api.example.com", balancePath: "/credits")
    let data = Data(#"{"data":{"credits":7.25}}"#.utf8)
    let obj = try! JSONSerialization.jsonObject(with: data)
    let old = findNumber(in: obj, names: ["balance", "total_balance", "credits",
                                         "credit", "remaining", "amount"])
    let reading = RecipeMap.apply(Recipe.legacy(spec).map, to: data)
    T.eq("legacy recipe finds same number", reading.gauges.first?.text,
         old.map { Fmt.money($0, "USD") })
    T.eq("legacy recipe emits one balance", reading.gauges.count, 1)
}

func testRecipeMapWindowKinds() {
    T.eq("5h window", RecipeMap.window("5h"), .shortWindow)
    T.eq("weekly window", RecipeMap.window("weekly"), .longWindow)
    T.eq("model window", RecipeMap.window("model"), .modelWindow)
    T.eq("other window", RecipeMap.window("other"), .other)
}

func testRedactRawPreview() {
    let key = "sk-secret"
    let raw = Data(#"{"one":"sk-secret","two":"sk-secret"}"#.utf8)
    let preview = RecipeFetch.redactRawPreview(raw, credential: key)
    T.check("all credential substrings redacted", !preview.contains(key))
    T.eq("both occurrences replaced", preview.components(separatedBy: "••••").count - 1, 2)
}

func testNetRefusesCrossHostRedirect() {
    let origin = URL(string: "https://api.example.com/v1")!
    let same = URLRequest(url: URL(string: "https://api.example.com/next")!)
    let other = URLRequest(url: URL(string: "https://evil.example/collect")!)
    T.notNil("same-origin redirect accepted", Net.redirectTarget(originalURL: origin, proposed: same))
    T.isNil("cross-host redirect rejected", Net.redirectTarget(originalURL: origin, proposed: other))
    let downgrade = URLRequest(url: URL(string: "http://api.example.com/next")!)
    T.isNil("https to http downgrade rejected", Net.redirectTarget(originalURL: origin, proposed: downgrade))
    let otherPort = URLRequest(url: URL(string: "https://api.example.com:8443/next")!)
    T.isNil("different port rejected", Net.redirectTarget(originalURL: origin, proposed: otherPort))
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

func testConfigMigratesAbsentAgyKeyOnce() {
    var old = Config()
    old.intervals.removeValue(forKey: "agy")
    old.agyIntervalKeyPresent = false
    old.agyIntervalMigrated = false

    let migrated = Config.migratingAgyInterval(old, agyKeyPresent: false)
    T.eq("absent agy key migrates to hourly", migrated.intervals["agy"], 3600)
    T.check("migration flag is set", migrated.agyIntervalMigrated)

    var explicit = migrated
    explicit.intervals["agy"] = 0
    explicit.agyIntervalKeyPresent = true
    let untouched = Config.migratingAgyInterval(explicit, agyKeyPresent: true)
    T.eq("explicit agy:0 preserved after migration", untouched.intervals["agy"], 0)
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

func testConfigValidatedClampsExtremeStaleMinutes() {
    var cfg = Config()
    cfg.menuBar.staleAfterMinutes = 9_223_372_036_854_775_807
    let (out, notice) = Config.validated(cfg)
    T.eq("stale minutes clamped", out.menuBar.staleAfterMinutes, 10_080)
    T.notNil("notice names field", notice)
}

func testConfigValidatedPreservesExplicitAgyZero() {
    var cfg = Config()
    cfg.intervals["agy"] = 0
    cfg.agyIntervalKeyPresent = true
    let (out, _) = Config.validated(cfg)
    T.eq("explicit agy zero kept", out.intervals["agy"], 0)
}

func testConfigStoreRevisionMonotonicAndRollback() {
    MainActor.assumeIsolated {
        let tmp = NSTemporaryDirectory() + "aimeter-cfgstore-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let path = tmp + "/config.json"
        defer {
            Config.pathOverride = nil
            try? FileManager.default.removeItem(atPath: tmp)
        }
        Config.pathOverride = path
        let store = ConfigStore(initial: Config())
        let r0 = store.revision
        try? store.mutate { $0.refreshSeconds = 90 }
        T.check("revision increments", store.revision == r0 + 1)
        try? store.mutate { $0.refreshSeconds = 120 }
        T.check("second mutate increments", store.revision == r0 + 2)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        var threw = false
        do { try store.mutate { $0.refreshSeconds = 999 } } catch { threw = true }
        T.check("failed save throws", threw)
        T.eq("cfg unchanged after failed save", store.cfg.refreshSeconds, 120)
    }
}

func testProcessRunnerKillsSlowSleep() {
    let start = Date()
    let sem = DispatchSemaphore(value: 0)
    var out: ProcessRunner.Output?
    Task {
        out = await ProcessRunner.run(binary: "/bin/sleep", args: ["30"],
                                      deadline: .seconds(1))
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 4)
    let elapsed = Date().timeIntervalSince(start)
    guard let out else { T.check("process returned", false); return }
    T.check("timed out", out.timedOut)
    T.check("finished within budget", elapsed < 2.5, "elapsed \(elapsed)s")
}

func testProcessRunnerDoesNotKillCallerOnChildTimeout() {
    let callerPid = getpid()
    let start = Date()
    let sem = DispatchSemaphore(value: 0)
    var out: ProcessRunner.Output?
    Task {
        out = await ProcessRunner.run(binary: "/bin/sh",
                                      args: ["-c", "trap '' TERM; sleep 30"],
                                      deadline: .seconds(1))
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 4)
    T.eq("test process pid unchanged", getpid(), callerPid)
    T.check("follow-up after child kill", out?.timedOut == true)
    // 1s deadline, then the 2s graceful window before SIGKILL: ~3s is the
    // floor for a child that ignores SIGTERM, so this ceiling is 4s.
    T.check("returned within deadline plus grace", Date().timeIntervalSince(start) < 4.0)
}

func testProcessRunnerKillsChildProcessGroup() {
    let sem = DispatchSemaphore(value: 0)
    Task {
        _ = await ProcessRunner.run(
            binary: "/bin/sh",
            args: ["-c", "yes | head -c 100000000 > /dev/null; sleep 30"],
            deadline: .seconds(1))
        try? await Task.sleep(nanoseconds: 300_000_000)
        let probe = await ProcessRunner.run(binary: "/usr/bin/pgrep", args: ["-x", "yes"],
                                            deadline: .seconds(2))
        T.check("no yes process after group kill", probe.exitCode != 0)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 6)
}

func testProcessRunnerTruncatesLargeOutput() {
    let sem = DispatchSemaphore(value: 0)
    var out: ProcessRunner.Output?
    Task {
        out = await ProcessRunner.run(binary: "/usr/bin/yes", args: [],
                                      deadline: .seconds(2))
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 4)
    guard let out else { T.check("process returned", false); return }
    T.check("output truncated", out.outputTruncated)
    T.check("stdout capped", out.stdout.count <= ProcessRunner.outputLimit)
}

func testRingAnimatorStopsTimerWhenMotionOff() {
    MainActor.assumeIsolated {
        let animator = RingAnimator { _ in }
        animator.show(RingIcon.RingModel(outer: 95, inner: 10), animated: true)
        T.check("timer active during animated sweep", animator.hasActiveTimer)
        animator.show(RingIcon.RingModel(outer: 95, inner: 10), animated: false)
        T.check("timer nil when animate false", !animator.hasActiveTimer)
    }
}

func testPanelModelMultiAccountRowsCarryAccountNames() {
    let a = Reading(id: "openrouter", title: "OpenRouter", account: "work",
                    gauges: [Gauge(label: "weekly", percent: 40, text: "40%")])
    let b = Reading(id: "openrouter", title: "OpenRouter", account: "personal",
                    gauges: [Gauge(label: "weekly", percent: 10, text: "10%")])
    let model = PanelModelBuilder.build(readings: ["openrouter": [a, b]], cfg: Config())
    let card = model.cards.first { $0.id == "openrouter" }
    T.check("row mentions account", card?.compact.contains(where: { $0.label.contains("work") }) == true)
}

func testPanelModelOneAccountFailureKeepsOtherGauges() {
    let ok = Reading(id: "openrouter", title: "OpenRouter", account: "good",
                     gauges: [Gauge(label: "weekly", percent: 5, text: "5%")])
    let bad = Reading.failed("openrouter", "OpenRouter", "bad", "nope")
    let model = PanelModelBuilder.build(readings: ["openrouter": [ok, bad]], cfg: Config())
    let card = model.cards.first { $0.id == "openrouter" }
    T.check("healthy gauge survives", card?.compact.contains(where: { $0.percent == 5 }) == true)
    T.isNil("not whole-card failure", card?.failureMessage)
}

func testRefreshCoordinatorSkipsManualOnlyOnLaunch() {
    final class Fake: Provider, @unchecked Sendable {
        let id: String
        var title: String { id }
        var calls = 0
        init(id: String) { self.id = id }
        func fetchAll(manual: Bool) async -> [Reading] {
            calls += 1
            return [Reading(id: id, title: id)]
        }
    }
    let fake = Fake(id: "recipe-x")
    var cfg = Config()
    cfg.intervals["recipe-x"] = 0
    cfg.accounts["recipe-x"] = [AccountSpec(name: "a")]
    let sem = DispatchSemaphore(value: 0)
    Task {
        let coord = RefreshCoordinator()
        await coord.request(reason: .launch, providerIDs: ["recipe-x"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 100_000_000)
        T.eq("launch skips manual-only", fake.calls, 0)
        await coord.request(reason: .manual, providerIDs: ["recipe-x"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 100_000_000)
        T.check("manual calls provider", fake.calls > 0)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 2)
}

func testRefreshCoordinatorManualCoalescesDuringInFlight() {
    final class SlowFake: Provider, @unchecked Sendable {
        let id = "slow"
        var title: String { id }
        var calls = 0
        func fetchAll(manual: Bool) async -> [Reading] {
            calls += 1
            if calls == 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return [Reading(id: id, title: id, account: "a")]
        }
    }
    let fake = SlowFake()
    var cfg = Config()
    cfg.accounts["slow"] = [AccountSpec(name: "a")]
    let sem = DispatchSemaphore(value: 0)
    Task {
        let coord = RefreshCoordinator()
        await coord.request(reason: .manual, providerIDs: ["slow"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coord.request(reason: .manual, providerIDs: ["slow"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        T.eq("manual coalesces to exactly two runs", fake.calls, 2)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 4)
}

func testRefreshCoordinatorDropsStaleGeneration() {
    final class Fake: Provider, @unchecked Sendable {
        let id = "gen"
        var title: String { id }
        var hold: CheckedContinuation<Void, Never>?
        func fetchAll(manual: Bool) async -> [Reading] {
            await withCheckedContinuation { hold = $0 }
            return [Reading(id: id, title: id, account: "a", lines: ["stale"])]
        }
        func release() { hold?.resume(); hold = nil }
    }
    let fake = Fake()
    var cfg = Config()
    cfg.accounts["gen"] = [AccountSpec(name: "a")]
    let sem = DispatchSemaphore(value: 0)
    Task {
        let coord = RefreshCoordinator()
        var published: [Reading] = []
        await coord.request(reason: .manual, providerIDs: ["gen"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { event in
            if !event.dropped { published.append(contentsOf: event.readings) }
        })
        try? await Task.sleep(nanoseconds: 50_000_000)
        await coord.setGeneration(2)
        fake.release()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let snap = await coord.readingsSnapshot()
        T.check("stale result not in readings box", snap["gen"]?.isEmpty != false)
        T.check("stale never published", published.isEmpty)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 3)
}

func testRefreshCoordinatorSlowProviderBudget() {
    final class HangFake: Provider, @unchecked Sendable {
        let id: String
        let delay: TimeInterval
        init(id: String, delay: TimeInterval) { self.id = id; self.delay = delay }
        var title: String { id }
        func fetchAll(manual: Bool) async -> [Reading] {
            if delay > 0 {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { done.resume() }
                }
            }
            return [Reading(id: id, title: id)]
        }
    }
    let slow = HangFake(id: "slow", delay: 10)
    let fast = HangFake(id: "fast", delay: 0)
    var cfg = Config()
    cfg.intervals["slow"] = 60
    cfg.intervals["fast"] = 60
    let sem = DispatchSemaphore(value: 0)
    Task {
        let coord = RefreshCoordinator()
        await coord.setGeneration(1)
        await coord.setTestBudget(1)
        var events: [RefreshCoordinator.PublishEvent] = []
        let start = Date()
        await coord.request(reason: .timer, providerIDs: nil, providers: [slow, fast], cfg: cfg, generation: 1,
                            publish: { events.append($0) })
        while events.filter({ $0.providerID == "fast" && !$0.dropped }).isEmpty,
              Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let fastEvent = events.first { $0.providerID == "fast" && !$0.dropped }
        T.notNil("fast provider published within budget", fastEvent)
        while events.first(where: {
            $0.providerID == "slow" && $0.readings.first?.lines.first == L.t("m.timeout")
        }) == nil, Date().timeIntervalSince(start) < 3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let slowTimeout = events.first {
            $0.providerID == "slow" && $0.readings.first?.lines.first == L.t("m.timeout")
        }
        T.notNil("slow provider got timeout reading", slowTimeout)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 6)
}

func testRefreshCoordinatorRateLimitManualBypassesTimer() {
    final class Fake: Provider, @unchecked Sendable {
        let id = "claude"
        var title: String { id }
        var calls = 0
        func fetchAll(manual: Bool) async -> [Reading] {
            calls += 1
            return [Reading(id: id, title: id)]
        }
    }
    RateLimit.resetForTests()
    RateLimit.mark(host: "api.anthropic.com", account: "*",
                   until: Date().addingTimeInterval(120))
    let fake = Fake()
    var cfg = Config()
    let sem = DispatchSemaphore(value: 0)
    Task {
        let coord = RefreshCoordinator()
        await coord.request(reason: .timer, providerIDs: ["claude"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 100_000_000)
        T.eq("timer skipped under rate limit", fake.calls, 0)
        await coord.request(reason: .manual, providerIDs: ["claude"], providers: [fake], cfg: cfg,
                            generation: 1, publish: { _ in })
        try? await Task.sleep(nanoseconds: 100_000_000)
        T.eq("manual runs under rate limit", fake.calls, 1)
        RateLimit.resetForTests()
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 2)
}

func testConfigStoreLanguagePersistsAfterToggleCardExpanded() {
    MainActor.assumeIsolated {
        let tmp = NSTemporaryDirectory() + "aimeter-a3-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let path = tmp + "/config.json"
        defer {
            Config.pathOverride = nil
            try? FileManager.default.removeItem(atPath: tmp)
        }
        Config.pathOverride = path
        let store = ConfigStore(initial: Config())
        try? store.mutate { $0.language = .zhHant }
        try? store.mutate {
            if !$0.menuBar.expanded.contains("codex") {
                $0.menuBar.expanded.append("codex")
            }
        }
        T.eq("language unchanged after expand toggle", store.cfg.language, .zhHant)
    }
}

func testConfigLoadNegativeRetentionClampedAndHistoryPreserves() {
    let json = Data(#"{"history":{"retentionMonths":-5}}"#.utf8)
    guard let decoded = try? JSONDecoder().decode(Config.self, from: json) else {
        T.check("negative retention decodes", false); return
    }
    // The decoder keeps what the file says so that validation can report it;
    // clamping and the notice both belong to `Config.validated`.
    T.eq("decode keeps the written value", decoded.history.retentionMonths, -5)
    let (validated, notice) = Config.validated(decoded)
    T.eq("validated retention is 1", validated.history.retentionMonths, 1)
    T.notNil("clamping is reported", notice)

    let dir = NSTemporaryDirectory() + "aimeter-e3-\(UUID().uuidString)"
    let historyDir = dir + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let month = History.monthKey(for: Date())
    let path = historyDir + "/\(month).jsonl"
    try? Data("{\"t\":\"x\"}\n".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: dir) }
    History.applyRetention(dir: dir, months: validated.history.retentionMonths)
    T.check("current month history kept", FileManager.default.fileExists(atPath: path))
}

func testConfigStoreLoadSurfacesClampNotice() {
    MainActor.assumeIsolated {
        let tmp = NSTemporaryDirectory() + "aimeter-clamp-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let path = tmp + "/config.json"
        defer {
            Config.pathOverride = nil
            try? FileManager.default.removeItem(atPath: tmp)
        }
        var cfg = Config()
        cfg.menuBar.staleAfterMinutes = 99_999
        Config.pathOverride = path
        try? cfg.save()
        let store = ConfigStore()
        T.notNil("range notice from load", store.rangeNotice)
    }
}


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
    for (name, image) in [("empty", empty), ("numeral", withNumeral), ("full", full)] {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(image.size.width)),
                                   pixelsHigh: max(1, Int(image.size.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        T.check("\(name) ring produces non-empty pixel data", rep.tiffRepresentation?.isEmpty == false)
    }
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
    let json = """
    {"colours": {"service.claude": "#FF0000FF", "text": "#00FF00FF"}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("config with legacy colour key decodes", false)
        return
    }
    T.eq("one-colour service key remains canonical", cfg.colours["service.claude"] ?? "", "#FF0000FF")
    T.isNil("old text role is renamed", cfg.colours["text"])
    T.eq("old text role becomes ink", cfg.colours[Palette.ink] ?? "", "#00FF00FF")
}

@MainActor
func testPanelNavPushPopReset() {
    let nav = PanelNav()
    nav.push(.root)
    nav.push(.services)
    nav.push(.catalogue)
    T.eq("panel nav pushes three levels", nav.stack.count, 3)
    nav.pop()
    T.eq("panel nav pops one level", nav.stack, [.root, .services])
    nav.reset()
    T.check("panel nav reset clears the stack", nav.stack.isEmpty)
}

func testEscapePopsBeforeClosing() {
    T.eq("escape pops a settings page", escapeAction(stackDepth: 2), .pop)
    T.eq("escape closes from usage", escapeAction(stackDepth: 0), .close)
}

func testConfigDecodesLegacyColourSchemeToProvider() {
    let json = "{\"menuBar\":{\"colourScheme\":\"adaptive\"}}"
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("legacy colour scheme config decodes", false)
        return
    }
    T.eq("adaptive colour scheme becomes provider", cfg.menuBar.colourScheme, .provider)
}

func testConfigMigratesTwoColourServiceKeysToOne() {
    let json = """
    {"colours":{"service.claude.5h":"#112233FF","service.claude.week":"#445566FF",
                "panel.5h":"#778899FF"}}
    """
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)) else {
        T.check("two-colour config decodes", false)
        return
    }
    T.eq("5h service colour becomes the one service colour",
         cfg.colours["service.claude"] ?? "", "#112233FF")
    T.isNil("weekly service colour is discarded", cfg.colours["service.claude.week"])
    T.isNil("panel colour is discarded", cfg.colours["panel.5h"])
}

func testConfigIgnoresAdaptiveHueOffset() {
    let json = "{\"menuBar\":{\"adaptiveHueOffset\":47.5}}"
    guard let cfg = try? JSONDecoder().decode(Config.self, from: Data(json.utf8)),
          let encoded = try? JSONEncoder().encode(cfg),
          let output = String(data: encoded, encoding: .utf8) else {
        T.check("config with adaptiveHueOffset round-trips", false)
        return
    }
    T.check("adaptiveHueOffset is not written back", !output.contains("adaptiveHueOffset"))
}

func testPaletteWarnAlarmAreDistinctPerAppearance() {
    var lightWarn = "", lightAlarm = "", lightLabel = ""
    var darkWarn = "", darkAlarm = "", darkLabel = ""
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        lightWarn = Palette.defaultColour(Palette.warn).hexString
        lightAlarm = Palette.defaultColour(Palette.alarm).hexString
        lightLabel = NSColor.labelColor.hexString
    }
    NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
        darkWarn = Palette.defaultColour(Palette.warn).hexString
        darkAlarm = Palette.defaultColour(Palette.alarm).hexString
        darkLabel = NSColor.labelColor.hexString
    }
    T.check("light warn and alarm are distinct", lightWarn != lightAlarm)
    T.check("dark warn and alarm are distinct", darkWarn != darkAlarm)
    T.check("warn changes with appearance", lightWarn != darkWarn)
    T.check("alarm changes with appearance", lightAlarm != darkAlarm)
    T.check("light urgency colours are not labelColor",
            lightWarn != lightLabel && lightAlarm != lightLabel)
    T.check("dark urgency colours are not labelColor",
            darkWarn != darkLabel && darkAlarm != darkLabel)
}

func testPaletteServiceColourFallback() {
    T.eq("unknown service uses neutral fallback", Palette.serviceColour("unknown").hexString,
         NSColor(hex: "#8A8A8F")!.hexString)
}

func testStatusStripWeekHalfDerivesFromServiceColour() {
    let short = StatusStrip.serviceWindowColour(provider: "claude", kind: .shortWindow)
    let week = StatusStrip.serviceWindowColour(provider: "claude", kind: .longWindow)
    T.check("weekly half differs from 5-hour half", week.hexString != short.hexString)
    T.check("weekly half is not pure white", week.hexString != NSColor.white.hexString)
}

func testRingIconTrackAlphaConstant() {
    T.eq("ring track alpha stays at 0.22", RingIcon.trackAlpha, CGFloat(0.22))
}

func testSettingsSubtitlesUseRealCounts() {
    let old = L.current
    L.current = .en
    defer { L.current = old }
    var cfg = Config()
    cfg.enabled["agy"] = false
    cfg.enabled["cursor"] = false
    T.eq("services subtitle uses real total and hidden counts",
         SettingsSubtitle.services(cfg), "7 services · 2 hidden")
    cfg.language = .en
    cfg.refreshSeconds = 0
    T.eq("manual general subtitle does not say every",
         SettingsSubtitle.general(cfg), "English · manual")
    cfg.refreshSeconds = 900
    T.eq("scheduled general subtitle says every",
         SettingsSubtitle.general(cfg), "English · every 15 minutes")
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
func claudeBlob(access: String = "sk-ant-oat-REAL",
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


/// Observed 2026-09-02: Claude Code's keychain item read perfectly well and
/// held `accessToken: ""`, `expiresAt: 0` beside the usual account metadata -
/// the shape the CLI leaves behind when it is signed out (`claude auth status`
/// said `loggedIn: false`). The row said "could not obtain an access token",
/// which reads as this app failing, and offered nothing to do about it.

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
    T.notNil("findString returns a token from a matching subtree",
             findString(in: blob, names: ["token"]))
    var seen = Set<String>()
    for _ in 0..<200 {
        seen.insert(findString(in: blob, names: ["token"]) ?? "nil")
    }
    T.eq("a tie between two subtrees resolves the same way every time", seen.count, 1)
    T.check("the chosen token is never nil", !seen.contains("nil"))
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
    // Uses the haiku alias, not a config field: settings are untrusted, and a
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

func testClaudeCLIRedactsTwoEmailAddresses() {
    let raw = #"{"loggedIn":true,"email":"one@example.com","note":"backup backup@other.org today"}"#
    let safe = ClaudeCLI.redact(raw)
    let emailRe = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#)
    let range = NSRange(safe.startIndex..<safe.endIndex, in: safe)
    T.check("zero unredacted email-shaped substrings remain",
            emailRe.firstMatch(in: safe, range: range) == nil)
    T.check("redaction marker present", safe.contains("<redacted>"))
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
    var reading = Reading(id: "claude", title: "Claude")
    reading.gauges = gauges
    reading.state = .ok
    var cfg = Config()
    cfg.menuBar.primary = "claude"
    let model = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: cfg)
    guard let card = model.cards.first(where: { $0.id == "claude" }) else {
        T.check("claude card exists in panel model", false)
        return
    }
    T.eq("panel card shows all three gauge rows", card.compact.count, 3)
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

// MARK: - distinct failures, quota warnings, and token colours

func testNearLimitIsNotAFetchFailure() {
    let gauges = [Gauge(label: "quota", percent: 95, text: "95%", resetsAt: nil)]
    T.eq("90% is a near-limit state, not a fetch failure", worstState(gauges), .nearLimit)
    let cases: [(NSAppearance.Name, String, String, String)] = [
        (.aqua, "light", "#B87400", "#D94B3B"),
        (.darkAqua, "dark", "#E8B04A", "#F0705F")
    ]
    for (appearanceName, label, warning, failure) in cases {
        NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
            T.eq("\(label) near-limit uses the warning dot", stateColour(.nearLimit).hexString,
                 NSColor(hex: warning)!.hexString)
            T.eq("\(label) failed read alone uses the failure dot", stateColour(.failure).hexString,
                 NSColor(hex: failure)!.hexString)
        }
    }
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
                  resetsAt: now.addingTimeInterval(3600), kind: .shortWindow,
                  observedAt: now, source: "api")
    r.gauges = [g]
    let line = History.line(for: r, gauge: g, at: now)
    guard let data = line.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        T.check("gauge line parses as JSON", false); return
    }
    T.eq("gauge line: provider", obj["provider"] as? String, "claude")
    T.eq("gauge line: account", obj["account"] as? String, "Work")
    T.eq("gauge line: gauge_id", obj["gauge_id"] as? String,
         Parse.gaugeId(label: "5-hour window", kind: .shortWindow))
    T.eq("gauge line: kind", obj["kind"] as? String, "shortWindow")
    T.eq("gauge line: percent", obj["percent"] as? Double, 42.5)
    T.eq("gauge line: state", obj["state"] as? Int, ReadingState.ok.rawValue)
    T.eq("gauge line: source", obj["source"] as? String, "api")
    T.check("gauge line: fresh when observed", obj["fresh"] as? Bool == true)
    T.check("gauge line: t is ISO8601 UTC", (obj["t"] as? String)?.hasSuffix("Z") == true)
    T.check("gauge line: observed_at is ISO8601", (obj["observed_at"] as? String)?.hasSuffix("Z") == true)
    T.isNil("gauge line: no legacy gauge key", obj["gauge"] as? String)
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
    T.isNil("failure line has no gauge_id key", fobj["gauge_id"] as? String)
}

func testHistoryAppendCreatesMonthlyFileWithModeAndTwoLines() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 UTC
    let settings = History.RecordSettings(HistoryConfig())
    let r1 = Reading(id: "claude", title: "Claude Code",
                     gauges: [Gauge(label: "5-hour window", percent: 10, text: "10%", kind: .shortWindow,
                                    observedAt: now)])
    let r2 = Reading(id: "claude", title: "Claude Code",
                     gauges: [Gauge(label: "5-hour window", percent: 20, text: "20%", kind: .shortWindow,
                                    observedAt: now.addingTimeInterval(60))])
    T.check("first record appends", History.record([r1], settings: settings, at: now, dir: tmp))
    T.check("second record appends", History.record([r2], settings: settings,
                                                     at: now.addingTimeInterval(60), dir: tmp))

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
    FileManager.default.createFile(atPath: historyDir + "/history.csv", contents: Data("x".utf8))
    FileManager.default.createFile(atPath: historyDir + "/history.html", contents: Data("<p>x</p>".utf8))

    History.applyRetention(dir: tmp, months: 12, now: now)

    T.check("13-months-old file deleted", !FileManager.default.fileExists(atPath: old))
    T.check("11-months-old file kept", FileManager.default.fileExists(atPath: recent))
    T.check("stale csv export removed", !FileManager.default.fileExists(atPath: historyDir + "/history.csv"))
    T.check("stale html export removed", !FileManager.default.fileExists(atPath: historyDir + "/history.html"))
}

func testHistoryRetentionOnReducedMonthsClearsExports() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let historyDir = tmp + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    let cutoff = cal.date(byAdding: .month, value: -6, to: now)!
    let c = cal.dateComponents([.year, .month], from: cutoff)
    let oldMonth = String(format: "%04d-%02d", c.year!, c.month!)
    let oldPath = historyDir + "/\(oldMonth).jsonl"
    FileManager.default.createFile(atPath: oldPath, contents: Data("{}\n".utf8))
    FileManager.default.createFile(atPath: historyDir + "/history.csv", contents: Data("x".utf8))

    History.applyRetention(dir: tmp, months: 12, now: now)
    T.check("12-month retention keeps six-month-old file", FileManager.default.fileExists(atPath: oldPath))

    History.applyRetention(dir: tmp, months: 3, now: now)
    T.check("reduced retention deletes out-of-window month", !FileManager.default.fileExists(atPath: oldPath))
    T.check("reduced retention clears stale csv export",
            !FileManager.default.fileExists(atPath: historyDir + "/history.csv"))
}

func testHistoryServiceCacheInvalidatesOnRecord() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-cache-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let settings = History.RecordSettings(HistoryConfig())
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let sem = DispatchSemaphore(value: 0)
    Task {
        await HistoryService.shared.setDir(tmp)
        let seed = sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window",
                                       kind: .shortWindow, percent: 10, at: now.addingTimeInterval(-180))
        T.check("seed line appends", History.append([seed], at: now.addingTimeInterval(-180), dir: tmp))
        let seeded = (await HistoryService.shared.loadLines(now: now)).lines.count
        var r2 = Reading(id: "claude", title: "Claude", gauges: [
            Gauge(label: "5-hour window", percent: 90, text: "90%", kind: .shortWindow)
        ])
        _ = await HistoryService.shared.record([r2], settings: settings, at: now.addingTimeInterval(-60))
        let lines2 = (await HistoryService.shared.loadLines(now: now)).lines
        T.eq("record invalidates cache and reloads both lines", lines2.count, seeded + 1)
        let flat2 = Sparkline.flatten(Sparkline.samples(from: lines2, provider: "claude",
                                                         account: "", gaugeId: gaugeId,
                                                         refreshInterval: 60, now: now))
        T.check("second sparkline read includes the new sample", flat2.contains { $0.value == 90 })
        let flatCached = Sparkline.flatten(await HistoryService.shared.sparkline(
            provider: "claude", account: "", gaugeId: gaugeId, refreshInterval: 60, now: now))
        T.check("HistoryService sparkline cache sees the new sample", flatCached.contains { $0.value == 90 })
        sem.signal()
    }
    sem.wait()
}

func testHistoryLoadIgnoresDamagedTrailingLine() {
    let dir = ".build/tests/tmp"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/aimeter-hist-load-\(UUID().uuidString).jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let now = Date()
    var r = Reading(id: "claude", title: "Claude")
    let g = Gauge(label: "5-hour window", percent: 1, text: "1%", kind: .shortWindow, observedAt: now)
    r.gauges = [g]
    let good = History.line(for: r, gauge: g, at: now)
    guard good != "{}" else { T.check("history line encodes", false); return }
    try? (good + "\n{\"truncated\":").write(toFile: path, atomically: true, encoding: .utf8)
    let loaded = History.load(path: path)
    T.eq("valid line kept", loaded.lines.count, 1)
    T.eq("damaged tail counted", loaded.damaged, 1)
}

func testHistoryDedupSkipsSameObservedAt() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let observed = now
    let settings = History.RecordSettings(HistoryConfig())
    let gauge = Gauge(label: "5-hour window", percent: 10, text: "10%", kind: .shortWindow, observedAt: observed)
    let reading = Reading(id: "claude", title: "Claude", gauges: [gauge])
    _ = History.record([reading], settings: settings, at: now, dir: tmp)
    _ = History.record([reading], settings: settings, at: now.addingTimeInterval(60), dir: tmp)
    let monthPath = tmp + "/history/2023-11.jsonl"
    let lines = (try? String(contentsOfFile: monthPath, encoding: .utf8))?
        .split(separator: "\n", omittingEmptySubsequences: true) ?? []
    T.eq("unchanged observed_at is not written twice", lines.count, 1)
}

func testHistoryReportCSVEscapesFormulaInjection() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let historyDir = tmp + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    let now = Date()
    let line = """
    {"t":"\(iso.string(from: now))","observed_at":"\(iso.string(from: now))","provider":"claude","account":"=evil","gauge_id":"shortWindow:5-hour-window","kind":"shortWindow","percent":1,"text":"+cmd","source":"","fresh":true,"state":0}
    """
    try? (line + "\n").write(toFile: historyDir + "/2026-09.jsonl", atomically: true, encoding: .utf8)
    let (csvPath, _) = try! HistoryReport.export(dir: tmp)
    let csv = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? ""
    T.check("formula-like account is escaped", csv.contains("'=evil") || csv.contains("\"'=evil\""))
    T.check("formula-like text is escaped", csv.contains("'+cmd") || csv.contains("\"'+cmd\""))
}

// MARK: - HistoryReport: export produces a self-contained, secret-free HTML+CSV

func testHistoryReportExportProducesHTMLAndCSVWithNoSecrets() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let now = Date()
    let settings = History.RecordSettings(HistoryConfig())
    let fakeKey = "sk-ant-export-test-secret-key-12345"
    var claude = Reading(id: "claude", title: "Claude Code",
                         gauges: [Gauge(label: "5-hour window", percent: 30, text: "30%",
                                       resetsAt: now.addingTimeInterval(3600), kind: .shortWindow,
                                       observedAt: now.addingTimeInterval(-120))])
    claude.lines = ["token=\(fakeKey)", "Bearer \(fakeKey)"]
    let codex = Reading(id: "codex", title: "Codex",
                        gauges: [Gauge(label: "Weekly window", percent: 55, text: "55%", kind: .longWindow,
                                       observedAt: now.addingTimeInterval(-60))])
    _ = History.record([claude], settings: settings, at: now.addingTimeInterval(-120), dir: tmp)
    _ = History.record([codex], settings: settings, at: now.addingTimeInterval(-60), dir: tmp)

    let (csvPath, htmlPath) = try! HistoryReport.export(dir: tmp, providerTitle: { id in
        id == "claude" ? "Claude Code" : (id == "codex" ? "Codex" : id)
    })
    T.check("csv file exists", FileManager.default.fileExists(atPath: csvPath))
    T.check("html file exists", FileManager.default.fileExists(atPath: htmlPath))

    let html = (try? String(contentsOfFile: htmlPath, encoding: .utf8)) ?? ""
    T.check("html contains Claude Code title", html.contains("Claude Code"))
    T.check("html contains Codex title", html.contains("Codex"))
    for secret in ["Bearer", "sk-", "eyJ", "accessToken", fakeKey] {
        T.check("html contains no \"\(secret)\"", !html.contains(secret))
    }
    T.check("html has at least one svg chart", html.contains("<svg"))

    let csv = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? ""
    T.check("csv export omits fixture secret", !csv.contains(fakeKey))
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

func testPanelHeightClampsToScreen() {
    T.eq("panel height is clipped to screen", panelHeight(content: 900, chrome: 90, screenLimit: 800), 800)
    T.eq("panel height follows content below screen", panelHeight(content: 300, chrome: 90, screenLimit: 800), 390)
    T.eq("panel height keeps a 120pt minimum", panelHeight(content: 0, chrome: 0, screenLimit: 800), 120)
}

func testPanelHeightNewPageNotInflatedByPreviousPageMax() {
    // After a page change, measured content must reflect the new page (400), not
    // the old page's max (900). panelHeight with the reset values must not clip
    // to screenLimit when content+chrome fits.
    T.eq("new page 400+chrome stays below 880 limit",
         panelHeight(content: 400, chrome: 90, screenLimit: 880), 490)
    T.check("old page 900 would wrongly hit the 880 cap",
            panelHeight(content: 900, chrome: 90, screenLimit: 880) == 880)
}

// MARK: - Reading.merge: rate-limit warn keeps previous gauges (v1.0.32)

func testReadingMergeUsesNextWhenNextHasGauges() {
    let previous = Reading(id: "claude", title: "Claude",
                           gauges: [Gauge(label: "5h", percent: 10, text: "10%")])
    var next = Reading(id: "claude", title: "Claude",
                       gauges: [Gauge(label: "5h", percent: 80, text: "80%")])
    next.state = .ok
    let merged = Reading.merge(previous: previous, next: next)
    T.eq("next with gauges replaces wholesale", merged.gauges.first?.percent, 80)
}

func testReadingMergeKeepsGaugesOnWarnWithoutGauges() {
    let previous = Reading(id: "claude", title: "Claude",
                           gauges: [Gauge(label: "5h", percent: 10, text: "10%")])
    let next = Reading(id: "claude", title: "Claude",
                       lines: [L.t("c.ratelimited", "5 m")], state: .warn)
    let merged = Reading.merge(previous: previous, next: next)
    T.eq("warn without gauges keeps previous percent", merged.gauges.first?.percent, 10)
    T.eq("warn without gauges takes next state", merged.state, .warn)
    T.eq("warn without gauges takes next lines", merged.lines.first, L.t("c.ratelimited", "5 m"))
}

func testReadingMergeUsesNextOnFailure() {
    let previous = Reading(id: "claude", title: "Claude",
                           gauges: [Gauge(label: "5h", percent: 10, text: "10%")])
    let next = Reading.failed("claude", "Claude", nil, "HTTP 500")
    let merged = Reading.merge(previous: previous, next: next)
    T.check("failure replaces even when previous had gauges", merged.gauges.isEmpty)
    T.eq("failure state is visible", merged.state, .failure)
}

// MARK: - RateLimit: 429 backoff (v1.0.32)

func testRateLimitShouldSkip() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    RateLimit.mark(id: "test-skip", until: now.addingTimeInterval(120))
    T.check("skip while before until", RateLimit.shouldSkip(id: "test-skip", now: now))
    T.check("no skip once until passed",
            !RateLimit.shouldSkip(id: "test-skip", now: now.addingTimeInterval(121)))
}

func testRateLimitRetryAfter() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    T.near("integer seconds", RateLimit.retryAfter(header: "120", now: now), 120, tol: 0.001)
    T.near("missing header defaults to 300", RateLimit.retryAfter(header: nil, now: now), 300, tol: 0.001)
    T.near("empty header defaults to 300", RateLimit.retryAfter(header: "  ", now: now), 300, tol: 0.001)
    T.eq("oversized value capped at 24h", RateLimit.retryAfter(header: "99999", now: now), 86_400)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let httpDate = formatter.string(from: now.addingTimeInterval(120))
    T.near("HTTP-date header", RateLimit.retryAfter(header: httpDate, now: now), 120, tol: 1)
}

// MARK: - AgyProvider.mergePrintAndFallback (v1.0.32)

private func agyPrintReading(snapshotAt: Date) -> Reading {
    var r = Reading(id: "agy", title: "Antigravity", account: "test")
    r.gauges = [
        Gauge(label: "Gemini 5h", percent: 3, text: "3%", kind: .shortWindow),
        Gauge(label: "Gemini week", percent: 7, text: "7%", kind: .longWindow),
        Gauge(label: "Claude 5h", percent: 0, text: "0%", kind: .other),
        Gauge(label: "Claude week", percent: 0, text: "0%", kind: .other)
    ]
    r.snapshotAt = snapshotAt
    r.source = "print"
    return r
}

private func agySilentLogReading() -> Reading {
    var r = Reading(id: "agy", title: "Antigravity", account: "test",
                    lines: [L.t("a.silent"), L.t("a.silent2")])
    r.source = "log"
    return r
}

func testAgyMergePrintFreshBeatsSilentLog() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let print = agyPrintReading(snapshotAt: now.addingTimeInterval(-300))
    let log = agySilentLogReading()
    let merged = AgyProvider.mergePrintAndFallback(print: print, fallback: log,
                                                   printInterval: 3600, now: now)
    T.eq("fresh print keeps four gauges", merged.gauges.count, 4)
    T.eq("fresh print wins over silent log", merged.source, "print")
}

func testAgyMergeStalePrintYieldsLogWithNote() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let print = agyPrintReading(snapshotAt: now.addingTimeInterval(-3 * 3600))
    var log = Reading(id: "agy", title: "Antigravity", account: "test")
    log.gauges = [Gauge(label: L.t("g.quota"), percent: 42, text: "42%")]
    log.source = "log"
    let merged = AgyProvider.mergePrintAndFallback(print: print, fallback: log,
                                                   printInterval: 3600, now: now)
    T.eq("stale print yields log gauge", merged.gauges.first?.percent, 42)
    T.eq("stale print adds from-log line", merged.lines.first,
         L.t("a.fromlog", Fmt.relative(print.snapshotAt!)))
}

func testAgyMergeBothEmptyIsSilent() {
    let log = agySilentLogReading()
    let merged = AgyProvider.mergePrintAndFallback(print: nil, fallback: log,
                                                   printInterval: 3600)
    T.check("no gauges -> silent message", merged.gauges.isEmpty)
    T.eq("silent line preserved", merged.lines.first, L.t("a.silent"))
}

// MARK: - AgyProvider.fetch end-to-end (v1.0.32)

private func agyFetchFixtureDirs() -> (config: String, home: String) {
    let base = NSTemporaryDirectory() + "aimeter-agy-fetch-\(UUID().uuidString)"
    let config = base + "/config"
    let home = base + "/home"
    let cliDir = home + "/.gemini/antigravity-cli"
    try? FileManager.default.createDirectory(atPath: cliDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
    return (config, home)
}

private func agyFetchProvider(config: String, home: String) -> AgyProvider {
    var cfg = Config()
    cfg.accounts = ["agy": [AccountSpec(name: "test", home: home)]]
    cfg.agyQuotaViaPrint = false
    cfg.agyQuotaViaTUI = false
    cfg.intervals = ["agy": 3600]
    return AgyProvider(cfg: cfg, files: AgyFileLocations(configDir: config))
}

private func agyFetchAwait(_ provider: AgyProvider, manual: Bool) -> Reading? {
    var readings: [Reading] = []
    let sem = DispatchSemaphore(value: 0)
    Task { readings = await provider.fetchAll(manual: manual); sem.signal() }
    sem.wait()
    return readings.first
}

private func agyWriteSnapshot(at path: String, account: String, home: String, observedAt: Date) {
    let envelope = AgyPrint.SnapshotEnvelope(account: account, home: home,
                                             observedAt: observedAt,
                                             stdout: Data(agyUsageFixture.utf8))
    if let data = try? JSONEncoder().encode(envelope) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func testAgyFetchPausedWithFreshSnapshotShowsGauges() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    let now = Date()
    agyWriteSnapshot(at: dirs.config + "/agy-print-test.json", account: "test", home: dirs.home,
                     observedAt: now.addingTimeInterval(-300))
    let provider = agyFetchProvider(config: dirs.config, home: dirs.home)
    provider.pauseState.paused = true
    let reading = agyFetchAwait(provider, manual: false)
    guard let r = reading else { T.check("paused+fresh snapshot yields a reading", false); return }
    T.eq("paused+fresh snapshot keeps four gauges", r.gauges.count, 4)
    T.check("paused+fresh snapshot is not failure", r.state != .failure)
    T.eq("paused+fresh snapshot notes pause", r.lines.first,
         L.t("a.paused.cached", Fmt.relative(r.snapshotAt!)))
}

func testAgyFetchPausedWithoutSnapshotFails() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    let provider = agyFetchProvider(config: dirs.config, home: dirs.home)
    provider.pauseState.paused = true
    let reading = agyFetchAwait(provider, manual: false)
    guard let r = reading else { T.check("paused+no snapshot yields a reading", false); return }
    T.eq("paused+no snapshot is failure", r.state, .failure)
    T.eq("paused+no snapshot message", r.lines.first, L.t("a.print.paused"))
}

func testAgyPausedAutomaticTickSpawnsNoProcesses() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    var cfg = Config()
    cfg.accounts = ["agy": [AccountSpec(name: "test", home: dirs.home)]]
    cfg.agyQuotaViaPrint = true
    cfg.agyQuotaViaTUI = false
    cfg.intervals = ["agy": 3600]
    let provider = AgyProvider(cfg: cfg, files: AgyFileLocations(configDir: dirs.config))
    provider.pauseState.paused = true
    var launches = 0
    CommandRun.testHook = { _, _, _, _, _ in
        launches += 1
        return CommandRun.Attempt(exitCode: 0, stdout: Data("{}".utf8), stderr: "")
    }
    CommandRun.isRunningTestHook = { _ in launches += 1; return false }
    defer { CommandRun.testHook = nil; CommandRun.isRunningTestHook = nil }
    _ = agyFetchAwait(provider, manual: false)
    T.eq("paused automatic tick spawns zero processes", launches, 0)
}

func testAgyFetchStaleSnapshotFallsBackToLog() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    let now = Date()
    agyWriteSnapshot(at: dirs.config + "/agy-print-test.json", account: "test", home: dirs.home,
                     observedAt: now.addingTimeInterval(-3 * 3600))
    let logPath = dirs.home + "/.gemini/antigravity-cli/cli.log"
    let logLine = "2026-09-04 11:25:50 INFO retrieveUserQuotaSummary ok quota 42% left\n"
    try? Data(logLine.utf8).write(to: URL(fileURLWithPath: logPath))
    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: logPath)
    let reading = agyFetchAwait(agyFetchProvider(config: dirs.config, home: dirs.home), manual: false)
    guard let r = reading else { T.check("stale snapshot+log yields a reading", false); return }
    T.eq("stale snapshot+log uses 58% used from 42% left", r.gauges.first?.percent, 58)
    T.eq("stale snapshot+log notes from-log", r.lines.first,
         L.t("a.fromlog", Fmt.relative(now.addingTimeInterval(-3 * 3600))))
}

func testExpandedDefaultsToPrimary() {
    let oldJSON = Data(#"{"menuBar":{"primary":"codex"}}"#.utf8)
    let explicitJSON = Data(#"{"menuBar":{"primary":"codex","expanded":["claude","deepseek"]}}"#.utf8)
    guard let old = try? JSONDecoder().decode(Config.self, from: oldJSON),
          let explicit = try? JSONDecoder().decode(Config.self, from: explicitJSON) else {
        T.check("expanded config shapes decode", false); return
    }
    T.eq("missing expanded defaults to primary", old.menuBar.expanded, ["codex"])
    T.eq("present expanded is preserved", explicit.menuBar.expanded, ["claude", "deepseek"])
}

func testCardOrderPrimaryFirst() {
    let ids = ["claude", "codex", "openrouter", "deepseek", "agy", "local", "cursor", "custom"]
    var readings: [String: [Reading]] = [:]
    for id in ids {
        var reading = Reading(id: id, title: id)
        reading.gauges = [Gauge(label: "usage", percent: 10, text: "10%", kind: .other)]
        readings[id] = [reading]
    }
    var cfg = Config(); cfg.menuBar.primary = "deepseek"
    let model = PanelModelBuilder.build(readings: readings, cfg: cfg)
    T.eq("primary first then fixed and remaining order", model.cards.map(\.id),
         ["deepseek", "codex", "openrouter", "agy", "local", "cursor", "claude", "custom"])
}

func testHeroPicksShortWindowFirst() {
    var reading = Reading(id: "claude", title: "Claude")
    reading.gauges = [
        Gauge(label: "other", percent: 8, text: "8%", kind: .other),
        Gauge(label: "long", percent: 40, text: "40%", kind: .longWindow),
        Gauge(label: "short", percent: 12, text: "12%", kind: .shortWindow)
    ]
    let card = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: Config()).cards[0]
    T.eq("short window is the hero", card.hero?.label, "short")
    T.eq("the other two gauges become chips", card.chips.count, 2)
}

func testHeroFallsBackToValueWhenNoPercent() {
    var reading = Reading(id: "claude", title: "Claude")
    reading.gauges = [Gauge(label: "Balance", percent: nil, text: "$12.40", kind: .other)]
    let hero = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: Config()).cards[0].hero
    T.isNil("value-only hero has no percent", hero?.percent)
    T.eq("value-only hero keeps gauge text", hero?.text, "$12.40")
}

func testMonthKeyIsGregorianPOSIX() {
    let date = ISO8601DateFormatter().date(from: "2026-09-05T12:00:00Z")!
    let localFormatter = DateFormatter()
    localFormatter.locale = Locale(identifier: "th_TH")
    localFormatter.calendar = Calendar(identifier: .buddhist)
    localFormatter.timeZone = TimeZone(identifier: "UTC")
    localFormatter.dateFormat = "yyyy-MM"
    T.eq("Thai Buddhist formatting would select the wrong history file",
         localFormatter.string(from: date), "2569-09")
    T.eq("month key stays Gregorian POSIX", History.monthKey(for: date), "2026-09")
}

func testHistoryTitleNotMenuString() {
    let old = L.current
    defer { L.current = old }
    for language in [Lang.en, .zhHant, .fr, .de] {
        L.current = language
        T.check("history page title differs from menu wording in \(language.rawValue)",
                L.t("pn.history") != L.t("m.history"))
    }
}

func testPanelModelBuilderLocalizesCursorAndLocalTitles() {
    let old = L.current
    L.current = .en
    defer { L.current = old }
    T.eq("cursor title is localized", PanelModelBuilder.title(for: "cursor"), L.t("p.cursor"))
    T.eq("local title is localized", PanelModelBuilder.title(for: "local"), L.t("p.local"))
}

func testPanelModelPrimaryPicksConfiguredProvider() {
    var codex = Reading(id: "codex", title: "Codex")
    codex.gauges = [Gauge(label: "5h", percent: 40, text: "40%", kind: .shortWindow)]
    var cfg = Config()
    cfg.menuBar.primary = "codex"
    let model = PanelModelBuilder.build(readings: ["codex": [codex]], cfg: cfg)
    T.eq("primary card is the configured provider", model.cards.first?.id, "codex")
    T.eq("primary hero comes from that provider's gauge", model.cards.first?.hero?.percent, 40)
}

func testPanelModelHeroUsesShortWindowGauge() {
    var claude = Reading(id: "claude", title: "Claude")
    claude.gauges = [
        Gauge(label: "week", percent: 97, text: "97%", kind: .longWindow),
        Gauge(label: "5h", percent: 19, text: "19%", kind: .shortWindow)
    ]
    let model = PanelModelBuilder.build(readings: ["claude": [claude]], cfg: Config())
    T.eq("hero percent is the shortWindow gauge, not the first gauge", model.cards.first?.hero?.percent, 19)
    T.eq("hero window label follows the shortWindow gauge", model.cards.first?.hero?.label, "5h")
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
         model.cards.first?.chips.map(\.label), ["week", "Alpha", "Zebra", "Extra usage"])
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
         model.cards.dropFirst().map(\.id), ["codex", "openrouter", "deepseek", "agy", "local", "cursor", "zzzgeneric"])
}

func testPanelModelSecondaryOrderExcludesThePrimary() {
    var codex = Reading(id: "codex", title: "Codex")
    codex.gauges = [Gauge(label: "5h", percent: 40, text: "40%", kind: .shortWindow)]
    var cfg = Config()
    cfg.menuBar.primary = "codex"
    let model = PanelModelBuilder.build(readings: ["codex": [codex]], cfg: cfg)
    T.check("the primary provider does not also appear as a secondary card",
           !model.cards.dropFirst().contains { $0.id == "codex" })
}

func testPanelModelFailureReadingYieldsTheAlarmMessage() {
    let failed = Reading.failed("claude", "Claude", nil, "Connection failed: timed out")
    let model = PanelModelBuilder.build(readings: ["claude": [failed]], cfg: Config())
    T.eq("primary state is .failure", model.cards.first?.state, .failure)
    T.eq("primary failure message is the reading's first line",
         model.cards.first?.failureMessage, "Connection failed: timed out")

    var cfg = Config()
    cfg.menuBar.primary = "somethingElse"
    let failedCodex = Reading.failed("codex", "Codex", nil, "HTTP 500")
    let model2 = PanelModelBuilder.build(readings: ["codex": [failedCodex]], cfg: cfg)
    guard let card = model2.cards.dropFirst().first(where: { $0.id == "codex" }) else {
        T.check("codex produced a secondary card", false); return
    }
    T.eq("secondary card state is .failure", card.state, .failure)
    T.eq("secondary card failure message is the reading's first line", card.failureMessage, "HTTP 500")
}

func testPanelModelMissingPrimaryYieldsTheNoDataState() {
    let model = PanelModelBuilder.build(readings: [:], cfg: Config())
    T.check("no reading at all -> primary has no data", model.cards.first?.hasData == false)
    T.eq("no reading at all -> primary state is .off", model.cards.first?.state, .off)

    var otherOnly = Reading(id: "codex", title: "Codex")
    otherOnly.gauges = [Gauge(label: "5h", percent: 10, text: "10%", kind: .shortWindow)]
    let model2 = PanelModelBuilder.build(readings: ["codex": [otherOnly]], cfg: Config())
    T.check("primary's own id absent from readings -> no data even though others exist",
           model2.cards.first?.hasData == false)
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

private func sparklineLedgerLine(provider: String, account: String, label: String, kind: GaugeKind,
                                 percent: Double, at: Date) -> String {
    var reading = Reading(id: provider, title: provider, account: account.isEmpty ? nil : account)
    let gauge = Gauge(label: label, percent: percent, text: "\(Int(percent))%", kind: kind)
    reading.gauges = [gauge]
    return History.line(for: reading, gauge: gauge, at: at)
}

func testSparklineSamplesFiltersByProviderAccountAndGauge() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    let lines = [
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 10, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "codex", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 99, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "claude", account: "Work", label: "5-hour window", kind: .shortWindow,
                            percent: 55, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "claude", account: "", label: "Weekly window", kind: .longWindow,
                            percent: 55, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 20, at: now.addingTimeInterval(-60))
    ]
    let segments = Sparkline.samples(from: lines, provider: "claude", account: "", gaugeId: gaugeId,
                                     refreshInterval: 60, now: now)
    let samples = Sparkline.flatten(segments)
    T.eq("only matching provider/account/gauge survive", samples.count, 2)
    T.check("no sample carries foreign percent",
           !samples.contains { $0.value == 99 || $0.value == 55 })
}

func testSparklineSamplesIgnoresBadLines() {
    let now = Date()
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    let good1 = sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window",
                                    kind: .shortWindow, percent: 30, at: now.addingTimeInterval(-60))
    let good2 = sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window",
                                    kind: .shortWindow, percent: 31, at: now.addingTimeInterval(-30))
    let lines = ["not json at all", "{\"provider\":\"claude\"}", "", good1,
                 "{\"provider\":\"claude\",\"account\":\"\",\"gauge_id\":\"\(gaugeId)\","
                     + "\"percent\":null,\"t\":\"\(iso8601UTC().string(from: now))\",\"state\":0}",
                 good2]
    let segments = Sparkline.samples(from: lines, provider: "claude", account: "", gaugeId: gaugeId,
                                     refreshInterval: 60, now: now)
    T.eq("only well-formed lines with numeric percents survive",
         Sparkline.flatten(segments).count, 2)
}

func testSparklineSamplesRespectsTheTwentyFourHourWindow() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    let lines = [
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 50, at: now.addingTimeInterval(-25 * 3600)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 50, at: now.addingTimeInterval(-23 * 3600)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 50, at: now.addingTimeInterval(-23 * 3600 + 60))
    ]
    let samples = Sparkline.flatten(Sparkline.samples(from: lines, provider: "claude", account: "",
                                                      gaugeId: gaugeId, refreshInterval: 60, now: now))
    T.eq("a line older than 24h is dropped", samples.count, 2)
}

func testSparklineBreaksOnGapAndFailure() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    func failure(_ t: Date) -> String {
        var reading = Reading.failed("claude", "Claude", nil, "down")
        return History.line(for: reading, gauge: nil, at: t)
    }
    let lines = [
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 10, at: now.addingTimeInterval(-300)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 20, at: now.addingTimeInterval(-240)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 30, at: now.addingTimeInterval(-80)),
        failure(now.addingTimeInterval(-60)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 40, at: now.addingTimeInterval(-40)),
        sparklineLedgerLine(provider: "claude", account: "", label: "5-hour window", kind: .shortWindow,
                            percent: 50, at: now.addingTimeInterval(-20))
    ]
    let segments = Sparkline.samples(from: lines, provider: "claude", account: "", gaugeId: gaugeId,
                                     refreshInterval: 60, now: now)
    T.eq("wide gap and failure split into two segments", segments.count, 2)
}

// MARK: - v1.0.33 security adversarial tests

func testRecipeCLIEnvPinMismatchBlocksCommand() {
    var recipe = Recipe(id: "cmd", name: "Cmd",
        fetch: FetchSpec(method: "cli", binary: "/opt/homebrew/bin/echo", args: ["ok"],
                         environment: ["MY_TOKEN_FILE": "/tmp/token"]))
    let account = AccountSpec(name: "a", home: expand("~"))
    let pin = RecipePin.proposed(recipe, account: account)!
    recipe.fetch.environment["NODE_OPTIONS"] = "--import=data:text/javascript,throw 1"
    T.check("env tamper breaks pin", !RecipePin.matches(recipe, pin, account: account))
    var launches = 0
    CommandRun.testHook = { _, _, _, _, _ in launches += 1; return CommandRun.Attempt(exitCode: 0, stdout: Data("{}".utf8), stderr: "") }
    defer { CommandRun.testHook = nil }
    let sem = DispatchSemaphore(value: 0)
    var result: Result<RecipeFetch.Output, Fail>?
    Task {
        result = await RecipeFetch.run(recipe, account: account, pin: pin)
        sem.signal()
    }
    sem.wait()
    guard case .failure(let fail) = result else { T.check("tampered env is failure", false); return }
    T.check("reapproval message", fail.message.contains(L.t("rc.reapprove")) || fail.message.contains("re-approv"))
    T.eq("no process launched", launches, 0)
}

func testRecipeEnvDeniedAtValidation() {
    var draft = RecipeDraft()
    draft.id = "envtest"; draft.name = "Env"; draft.method = "cli"
    draft.binary = "/opt/homebrew/bin/echo"; draft.environmentLines = "NODE_OPTIONS=--eval=1"
    let recipe = draft.recipe()
    let account = AccountSpec(name: "a", home: expand("~"))
    T.notNil("denied env fails validation", Credential.validateRecipeCredential(recipe, account: account))
}

func testRecipeAllowedCustomEnvHashesIntoPin() {
    var recipe = Recipe(id: "cmd", name: "Cmd",
        fetch: FetchSpec(method: "cli", binary: "/opt/homebrew/bin/echo", args: ["ok"],
                         environment: ["MY_TOKEN_FILE": "/tmp/token"]))
    let account = AccountSpec(name: "a", home: expand("~"))
    let pin = RecipePin.proposed(recipe, account: account)!
    T.check("allowed env matches", RecipePin.matches(recipe, pin, account: account))
    T.eq("env hash recorded", pin.envHash, RecipePin.envHash(recipe.fetch.environment))
}

func testRecipeForbiddenClaudeKeychainRejected() {
    var recipe = Recipe(id: "evil", name: "Evil",
        credential: CredentialSource(source: "keychain"),
        fetch: FetchSpec(method: "http", baseURL: "https://api.example.com", path: "/v1"))
    var account = AccountSpec(name: "a", keychainService: ClaudeCLI.credentialService)
    T.notNil("save validation rejects Claude keychain", Credential.validateRecipeCredential(recipe, account: account))
    var httpCalls = 0
    var keychainReads = 0
    RecipeFetch.httpTestHook = { _ in httpCalls += 1; return .failure(Fail(message: "should not run")) }
    Credential.readTestHook = { keychainReads += 1 }
    defer { RecipeFetch.httpTestHook = nil; Credential.readTestHook = nil }
    let pin = RecipePin.Pin(host: "https://api.example.com", method: "GET",
                            pathPolicy: RecipePin.pathPolicy("/v1"), bodyHash: "")
    let sem = DispatchSemaphore(value: 0)
    var result: Result<RecipeFetch.Output, Fail>?
    Task {
        result = await RecipeFetch.run(recipe, account: account, pin: pin)
        sem.signal()
    }
    sem.wait()
    guard case .failure = result else { T.check("forbidden credential fails fetch", false); return }
    T.eq("no http call", httpCalls, 0)
    T.eq("no keychain reads", keychainReads, 0)
}

func testRecipeCredentialFieldPinMismatch() {
    var recipe = Recipe(id: "http", name: "HTTP",
        credential: CredentialSource(source: "keyFile", path: "/tmp/k.json", jsonField: "token"),
        fetch: FetchSpec(method: "http", baseURL: "https://api.example.com", path: "/v1"))
    var account = AccountSpec(name: "a", keyFile: "/tmp/k.json", keyJSONField: "token")
    let pin = RecipePin.proposed(recipe, account: account)!
    recipe.credential.jsonField = "other"
    account.keyJSONField = "other"
    T.check("json field change mismatches", !RecipePin.matches(recipe, pin, account: account))
}

func testRecipeAuthModePinMismatch() {
    var recipe = Recipe(id: "http", name: "HTTP",
        credential: CredentialSource(source: "none"),
        fetch: FetchSpec(method: "http", baseURL: "https://api.example.com", path: "/v1",
                         auth: "header", authName: "X-Api-Key"))
    let pin = RecipePin.proposed(recipe)!
    recipe.fetch.auth = "query"
    T.check("auth mode change mismatches", !RecipePin.matches(recipe, pin))
}

func testCredentialMissingFieldFailsClosed() {
    let blob = #"{"mcpOAuth":{"srv":{"accessToken":"secret-mcp"}}}"#
    let obj = try! JSONSerialization.jsonObject(with: Data(blob.utf8))
    T.isNil("missing claudeAiOauth does not leak MCP token", Credential.unwrap(json: obj, field: nil))
    T.isNil("explicit missing field", Credential.unwrap(json: ["token": "abc"], field: "missing"))
}

func testWritePrivateCreatesAndReplaces() {
    let dir = NSTemporaryDirectory() + "aimeter-write-\(UUID().uuidString)"
    let path = dir + "/out.json"
    do {
        try writePrivate(Data("one".utf8), to: path)
        T.check("creates new file", FileManager.default.fileExists(atPath: path))
        try writePrivate(Data("two".utf8), to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        T.eq("replaces existing", text, "two")
    } catch {
        T.check("writePrivate succeeds on temp dir", false)
    }
    try? FileManager.default.removeItem(atPath: dir)
}

func testWritePrivateThrowsOnUnwritableDir() {
    let path = "/dev/null/cannot-write/out.json"
    var threw = false
    do { try writePrivate(Data("x".utf8), to: path) } catch { threw = true }
    T.check("unwritable path throws", threw)
    let dir = (path as NSString).deletingLastPathComponent
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasPrefix(".tmp-") } ?? []
    T.eq("no tmp residue", leftovers.count, 0)
}

func testReadingMergePreservesObservedAt() {
    let observed = Date(timeIntervalSince1970: 1_700_000_000)
    let fresh = Date(timeIntervalSince1970: 1_800_000_000)
    let previous = Reading(id: "claude", title: "Claude",
                           gauges: [Gauge(label: "5h", percent: 10, text: "10%",
                                          observedAt: observed, source: "api")])
    var nextFresh = Reading(id: "claude", title: "Claude",
                            gauges: [Gauge(label: "5h", percent: 80, text: "80%",
                                           observedAt: fresh, source: "print")])
    nextFresh.state = .ok
    let mergedFresh = Reading.merge(previous: previous, next: nextFresh)
    T.eq("fresh next keeps observedAt", mergedFresh.gauges.first?.observedAt, fresh)
    T.eq("fresh next keeps source", mergedFresh.gauges.first?.source, "print")

    var nextBorrowed = Reading(id: "claude", title: "Claude",
                               gauges: [Gauge(label: "5h", percent: 80, text: "80%")])
    nextBorrowed.state = .ok
    let mergedBorrowed = Reading.merge(previous: previous, next: nextBorrowed)
    T.eq("borrowed next keeps previous observedAt", mergedBorrowed.gauges.first?.observedAt, observed)
    T.eq("borrowed next keeps previous source", mergedBorrowed.gauges.first?.source, "api")
}

func testReadingMergeKeepsNearLimitOnWarnTransport() {
    var previous = Reading(id: "claude", title: "Claude",
                           gauges: [Gauge(label: "5h", percent: 95, text: "95%")])
    previous.state = .nearLimit
    let next = Reading(id: "claude", title: "Claude",
                       lines: [L.t("c.ratelimited", "5 m")], state: .warn)
    let merged = Reading.merge(previous: previous, next: next)
    T.eq("near-limit not downgraded", merged.state, ReadingState.nearLimit)
}

func testAgySnapshotAccountIsolation() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    let files = AgyFileLocations(configDir: dirs.config)
    agyWriteSnapshot(at: files.snapshotPath("bob"), account: "mallory", home: dirs.home, observedAt: Date())
    var cfgBob = Config()
    cfgBob.accounts = ["agy": [AccountSpec(name: "bob", home: dirs.home)]]
    let bobProvider = AgyProvider(cfg: cfgBob, files: files)
    T.isNil("wrong envelope account rejected for bob path",
            bobProvider.cachedPrintSnapshot(account: "bob", home: dirs.home))
    agyWriteSnapshot(at: files.snapshotPath("alice"), account: "alice", home: dirs.home, observedAt: Date())
    var cfgAlice = Config()
    cfgAlice.accounts = ["agy": [AccountSpec(name: "alice", home: dirs.home)]]
    let aliceProvider = AgyProvider(cfg: cfgAlice, files: files)
    T.notNil("alice reads own snapshot",
             aliceProvider.cachedPrintSnapshot(account: "alice", home: dirs.home))
}

func testAgyFailedAttemptDoesNotOverwriteSnapshot() {
    let dirs = agyFetchFixtureDirs()
    defer { try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent) }
    let files = AgyFileLocations(configDir: dirs.config)
    let now = Date()
    agyWriteSnapshot(at: files.snapshotPath("test"), account: "test", home: dirs.home, observedAt: now)
    CommandRun.testHook = { _, _, _, _, _ in
        CommandRun.Attempt(exitCode: 1, stdout: Data(), stderr: "timeout")
    }
    defer { CommandRun.testHook = nil }
    _ = AgyPrint.attempt(binary: "/opt/homebrew/bin/echo", home: dirs.home,
                         locations: files, account: "test")
    let provider = agyFetchProvider(config: dirs.config, home: dirs.home)
    T.notNil("successful snapshot survives failed attempt",
             provider.cachedPrintSnapshot(account: "test", home: dirs.home))
}

func testAgyTransientFailureUsesBackoffNotPause() {
    let dirs = agyFetchFixtureDirs()
    defer {
        AgyTUI.binaryTestHook = nil
        try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent)
    }
    let files = AgyFileLocations(configDir: dirs.config)
    var cfg = Config()
    cfg.accounts = ["agy": [AccountSpec(name: "test", home: dirs.home)]]
    cfg.agyQuotaViaPrint = true
    cfg.agyQuotaViaTUI = false
    cfg.intervals = ["agy": 3600]
    AgyTUI.binaryTestHook = { "/bin/echo" }
    CommandRun.testHook = { _, _, _, _, _ in
        CommandRun.Attempt(exitCode: 1, stdout: Data(), stderr: "timeout")
    }
    defer { CommandRun.testHook = nil }
    let provider = AgyProvider(cfg: cfg, files: files)
    _ = agyFetchAwait(provider, manual: false)
    T.check("transient failure does not set paused",
            !provider.pauseState.paused)
    T.check("transient failure records backoff state",
            provider.pauseState.backoff != nil)
}

func testRecipePinBodyHashIgnoresDictionaryInsertionOrder() {
    let first = JSONValue.object(["z": .number(1), "a": .string("x")])
    let second = JSONValue.object(["a": .string("x"), "z": .number(1)])
    T.eq("body hash is canonical", RecipePin.bodyHash(first), RecipePin.bodyHash(second))
}

func testAgyPrintArgvIsFourTokens() {
    var captured: [String]?
    CommandRun.testHook = { _, args, _, _, _ in
        captured = args
        return CommandRun.Attempt(exitCode: 1, stdout: Data(), stderr: "")
    }
    defer { CommandRun.testHook = nil }
    _ = AgyPrint.attempt(binary: "/bin/echo", home: NSHomeDirectory())
    T.eq("argv count", captured?.count, 4)
    T.eq("argv tokens", captured, ["-p", "/usage", "--output-format", "json"])
}

func testConfigSaveFailureShowsNoticeAndRevertsCfg() {
    MainActor.assumeIsolated {
        let tmp = NSTemporaryDirectory() + "aimeter-savefail-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let path = tmp + "/config.json"
        defer {
            Config.pathOverride = nil
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp)
            try? FileManager.default.removeItem(atPath: tmp)
        }
        var baseline = Config()
        baseline.refreshSeconds = 120
        Config.pathOverride = path
        do { try baseline.save() } catch { T.check("baseline save", false); return }
        let store = SettingsStore(config: baseline)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        let ok = store.mutate { $0.refreshSeconds = 999 }
        T.check("persist reports failure", !ok)
        T.notNil("save notice set", store.saveNotice)
        T.eq("cfg reverted to disk", store.cfg.refreshSeconds, 120)
    }
}

func testRecipeAppKeychainMalformedJSONFailsWithoutLeakingBlob() {
    let blob = "not-json-{{secret-token}}"
    RecipeFetch.appKeychainTestHook = { _ in .success(blob) }
    defer { RecipeFetch.appKeychainTestHook = nil }
    let recipe = Recipe(id: "x", name: "X",
                        credential: CredentialSource(source: "appKeychain", jsonField: "token", service: "TestApp"),
                        fetch: FetchSpec(method: "http", baseURL: "https://api.example.com", path: "/v1"))
    let account = AccountSpec(name: "a")
    let sem = DispatchSemaphore(value: 0)
    var result: Result<RecipeFetch.Output, Fail>?
    Task {
        result = await RecipeFetch.run(recipe, account: account, pin: RecipePin.proposed(recipe)!)
        sem.signal()
    }
    sem.wait()
    guard case .failure(let fail) = result else { T.check("malformed appKeychain fails", false); return }
    T.check("failure does not leak blob", !fail.message.contains("secret-token"))
}

func testPanelModelCompactAndExpandedCardsCarryNotices() {
    var reading = Reading(id: "claude", title: "Claude")
    let now = Date()
    reading.gauges = [
        Gauge(label: "5h", percent: 42, text: "42%", kind: .shortWindow, observedAt: now, source: "api"),
        Gauge(label: "week", percent: 18, text: "18%", kind: .longWindow, observedAt: now, source: "api")
    ]
    reading.lines = [L.t("c.ratelimited", Fmt.relative(now.addingTimeInterval(300)))]
    reading.state = .warn
    var compactCfg = Config()
    compactCfg.menuBar.expanded = []
    let compact = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: compactCfg)
    T.check("compact card has notices", compact.cards.first?.notices.count == 1)
    var expandedCfg = Config()
    expandedCfg.menuBar.expanded = ["claude"]
    let expanded = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: expandedCfg)
    T.check("expanded card has notices", expanded.cards.first?.notices.count == 1)
}

func testAgyManualPrintSuccessSkipsTUI() {
    let dirs = agyFetchFixtureDirs()
    defer {
        AgyTUI.binaryTestHook = nil
        AgyTUI.readTestHook = nil
        CommandRun.testHook = nil
        try? FileManager.default.removeItem(atPath: (dirs.config as NSString).deletingLastPathComponent)
    }
    let files = AgyFileLocations(configDir: dirs.config)
    var cfg = Config()
    cfg.accounts = ["agy": [AccountSpec(name: "test", home: dirs.home)]]
    cfg.agyQuotaViaPrint = true
    cfg.agyQuotaViaTUI = true
    cfg.intervals = ["agy": 3600]
    var tuiCalls = 0
    AgyTUI.binaryTestHook = { "/bin/echo" }
    AgyTUI.readTestHook = { tuiCalls += 1; return nil }
    CommandRun.testHook = { _, _, _, _, _ in
        CommandRun.Attempt(exitCode: 0, stdout: Data(agyUsageFixture.utf8), stderr: "")
    }
    let provider = AgyProvider(cfg: cfg, files: files)
    let reading = agyFetchAwait(provider, manual: true)
    T.eq("manual print success skips TUI", tuiCalls, 0)
    T.check("manual print success returns gauges", (reading?.gauges.count ?? 0) > 0)
}

// MARK: - entry point
//
// @main rather than a plain main.swift: top-level executable statements are
// only allowed in a file literally named main.swift, and that name is already
// taken by the app itself (deliberately excluded from this build - see
// test.sh).

import AppKit
import Foundation

// MARK: - v1.0.35: strict parsing (A8), history/sparkline (B6), output bounds (C6), D2

private func iso8601UTC() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}

func testParseNumberRejectsNaNInfinityBoolAndHugeMagnitude() {
    func expectInvalid(_ name: String, _ value: Any?) {
        switch Parse.number(value) {
        case .invalid: T.check(name, true)
        default: T.check(name, false, "expected invalid")
        }
    }
    expectInvalid("NaN string rejected", "NaN")
    expectInvalid("Infinity string rejected", "Infinity")
    expectInvalid("bool rejected", true)
    expectInvalid("huge magnitude rejected", 1e16)
    switch Parse.number(42) {
    case .value(let n): T.eq("finite int accepted", n, 42)
    default: T.check("finite int accepted", false)
    }
}

func testParsePercentRejectsNonPositiveLimit() {
    switch Parse.percent(used: 10, limit: 0) {
    case .invalid: T.check("zero limit rejected", true)
    default: T.check("zero limit rejected", false)
    }
    switch Parse.percent(used: 10, limit: -5) {
    case .invalid: T.check("negative limit rejected", true)
    default: T.check("negative limit rejected", false)
    }
    switch Parse.percent(used: 25, limit: 100) {
    case .value(let p): T.near("valid percent", p, 25)
    default: T.check("valid percent", false)
    }
}

private func codexRolloutLine(used: Double, timestamp: String = "2026-09-05T12:00:00Z") -> String {
    let payload: [String: Any] = [
        "rate_limits": [
            "primary": ["used_percent": used, "window_minutes": 300, "resets_at": 1_787_894_162]
        ]
    ]
    let obj: [String: Any] = ["timestamp": timestamp, "payload": payload]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return String(data: data, encoding: .utf8)! + "\n"
}

func testCodexNewestSnapshotOnlySearchesFirstNineFilesPerDay() {
    let base = NSTemporaryDirectory() + "aimeter-codex-\(UUID().uuidString)"
    let day = base + "/.codex/sessions/2026/09/05"
    defer { try? FileManager.default.removeItem(atPath: base) }
    try? FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
    let now = Date()
    for i in 0..<10 {
        let path = day + "/rollout-\(i).jsonl"
        let body = i == 0 ? codexRolloutLine(used: 77) : "{\"timestamp\":\"2026-09-05T12:00:00Z\",\"payload\":{}}\n"
        FileManager.default.createFile(atPath: path, contents: Data(body.utf8))
        let age = TimeInterval(i * 60)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)],
                                               ofItemAtPath: path)
    }
    var cfg = Config()
    cfg.accounts = ["codex": [AccountSpec(name: "t", home: base)]]
    let provider = CodexProvider(cfg: cfg)
    var readings: [Reading] = []
    let sem = DispatchSemaphore(value: 0)
    Task { readings = await provider.fetchAll(manual: false); sem.signal() }
    _ = sem.wait(timeout: .now() + 5)
    guard let r = readings.first else { T.check("codex reading from ninth file", false); return }
    T.near("ninth-newest file supplies used percent", r.gauges.first?.percent ?? -1, 77, tol: 0.01)
    T.check("searching >9 files marks partial", r.lines.contains(L.t("x.partial")))
}

func testAgyParseQuotaLogLine42PercentLeftMeans58Used() {
    let line = "2026-09-04 11:25:50 INFO retrieveUserQuotaSummary ok quota 42% left"
    let used = AgyProvider.parseQuotaLogLine(line)
    T.near("42% left becomes 58% used", used ?? -1, 58, tol: 0.01)
    T.check("fixture still names left not used", line.contains("42% left"))
}

func testHistoryReportCSVEscapesMaliciousGaugeLabels() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let historyDir = tmp + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    let now = Date()
    let line = """
    {"t":"\(iso.string(from: now))","observed_at":"\(iso.string(from: now))","provider":"claude","account":"work","gauge_id":"=evil","kind":"shortWindow","percent":1,"text":"+cmd","source":"","fresh":true,"state":0}
    """
    try? (line + "\n").write(toFile: historyDir + "/2026-09.jsonl", atomically: true, encoding: .utf8)
    let (csvPath, _) = try! HistoryReport.export(dir: tmp)
    let csv = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? ""
    T.check("malicious gauge_id escaped", csv.contains("'=evil") || csv.contains("\"'=evil\""))
    T.check("malicious text escaped", csv.contains("'+cmd") || csv.contains("\"'+cmd\""))
}

func testHistoryReportCSVEscapesEmbeddedCR() {
    let tmp = NSTemporaryDirectory() + "aimeter-hist-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let historyDir = tmp + "/history"
    try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    let now = Date()
    let line = """
    {"t":"\(iso.string(from: now))","observed_at":"\(iso.string(from: now))","provider":"claude","account":"","gauge_id":"g","kind":"shortWindow","percent":1,"text":"mid\\rline","source":"","fresh":true,"state":0}
    """
    try? (line + "\n").write(toFile: historyDir + "/2026-09.jsonl", atomically: true, encoding: .utf8)
    let (csvPath, _) = try! HistoryReport.export(dir: tmp)
    let csv = (try? String(contentsOfFile: csvPath, encoding: .utf8)) ?? ""
    T.check("embedded CR in text is quoted", csv.contains("\"mid\rline\""))
}

func testSparklineDoesNotMergeAcrossAccounts() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let gaugeId = Parse.gaugeId(label: "5-hour window", kind: .shortWindow)
    let lines = [
        sparklineLedgerLine(provider: "claude", account: "Work", label: "5-hour window", kind: .shortWindow,
                            percent: 10, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "claude", account: "Personal", label: "5-hour window", kind: .shortWindow,
                            percent: 90, at: now.addingTimeInterval(-120)),
        sparklineLedgerLine(provider: "claude", account: "Work", label: "5-hour window", kind: .shortWindow,
                            percent: 20, at: now.addingTimeInterval(-60))
    ]
    let segments = Sparkline.samples(from: lines, provider: "claude", account: "Work",
                                     gaugeId: gaugeId, refreshInterval: 60, now: now)
    let samples = Sparkline.flatten(segments)
    T.eq("only the requested account's samples survive", samples.count, 2)
    T.check("foreign account percent never appears", !samples.contains { $0.value == 90 })
}

func testNetRejectsResponsesLargerThanTwoMiB() {
    T.eq("max response cap is 2 MiB", Net.maxResponseBytes, 2 * 1024 * 1024)
    switch Parse.number(Double(Net.maxResponseBytes)) {
    case .value(let n): T.eq("cap fits Parse.number magnitude bound", n, Double(Net.maxResponseBytes))
    default: T.check("cap fits Parse.number magnitude bound", false)
    }
}

func testDisplayLimitTruncatesLongStrings() {
    let long = String(repeating: "x", count: 100)
    let (display, full) = DisplayLimit.truncate(long, max: DisplayLimit.label)
    T.eq("display is capped with ellipsis", display.count, DisplayLimit.label + 1)
    T.check("display ends with ellipsis", display.hasSuffix("…"))
    T.eq("full text preserved", full, long)
}

func testPollingTimerSetsTenPercentTolerance() {
    let interval: TimeInterval = 60
    let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in }
    timer.tolerance = interval * 0.1
    T.near("timer tolerance is 10% of interval", timer.tolerance, 6.0, tol: 0.01)
    timer.invalidate()
}

func testLocalAIProbesRunInParallel() {
    let delay: UInt64 = 150_000_000
    let sem = DispatchSemaphore(value: 0)
    var parallel = 0.0
    var serial = 0.0
    Task {
        let start = Date()
        async let a: Void = { try? await Task.sleep(nanoseconds: delay) }()
        async let b: Void = { try? await Task.sleep(nanoseconds: delay) }()
        async let c: Void = { try? await Task.sleep(nanoseconds: delay) }()
        _ = await (a, b, c)
        parallel = Date().timeIntervalSince(start)
        let start2 = Date()
        try? await Task.sleep(nanoseconds: delay)
        try? await Task.sleep(nanoseconds: delay)
        try? await Task.sleep(nanoseconds: delay)
        serial = Date().timeIntervalSince(start2)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 3)
    T.check("three parallel delays finish faster than serial", parallel < serial * 0.85,
            "parallel \(parallel)s serial \(serial)s")
}

func testPanelHeightBuildsViewAndMeasuresContent() {
    MainActor.assumeIsolated {
        let state = PanelState()
        state.screenLimit = 800
        var cfg = Config()
        cfg.menuBar.expanded = ["claude"]
        var reading = Reading(id: "claude", title: "Claude Code")
        reading.gauges = [
            Gauge(label: "5-hour window", percent: 42, text: "42%", kind: .shortWindow),
            Gauge(label: "Weekly window", percent: 18, text: "18%", kind: .longWindow)
        ]
        state.model = PanelModelBuilder.build(readings: ["claude": [reading]], cfg: cfg)
        let hosting = NSHostingView(rootView: PanelView(state: state, opaqueBackground: true))
        hosting.frame = CGRect(x: 0, y: 0, width: 372, height: 10)
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        T.check("built panel view measures non-trivial height", height > 120, "got \(height)")
        let clipped = panelHeight(content: 500, chrome: 90, screenLimit: 400)
        T.eq("panelHeight clips tall content to screen", clipped, 400)
    }
}

func testRecipeFileGlobRejectsSymlinkEscape() {
    let base = NSTemporaryDirectory() + "aimeter-recipe-\(UUID().uuidString)"
    let folder = base + "/data"
    let outside = base + "/outside.json"
    defer { try? FileManager.default.removeItem(atPath: base) }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: outside, contents: Data(#"{"credits":99}"#.utf8))
    let link = folder + "/escape.json"
    try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
    var recipe = Recipe(id: "filetest", name: "File",
                        fetch: FetchSpec(method: "file", folder: folder, glob: "*.json"))
    let pin = RecipePin.proposed(recipe)!
    let sem = DispatchSemaphore(value: 0)
    var result: Result<RecipeFetch.Output, Fail>?
    Task {
        result = await RecipeFetch.run(recipe, account: AccountSpec(name: "a"), pin: pin)
        sem.signal()
    }
    sem.wait()
    switch result {
    case .success(let out):
        T.check("symlink escape must not read outside folder", !String(decoding: out.data, as: UTF8.self).contains("99"))
    case .failure:
        T.check("symlink escape rejected", true)
    case .none:
        T.check("file fetch completed", false)
    }
}

func runHermeticTests() {
    T.beginTest("testRecipeURLSafety")
    testRecipeURLSafety()
    T.beginTest("testRecipeDecodeTolerant")
    testRecipeDecodeTolerant()
    T.beginTest("testRecipeReservedIDRejected")
    testRecipeReservedIDRejected()
    T.beginTest("testRecipePinMatchHTTP")
    testRecipePinMatchHTTP()
    T.beginTest("testRecipePinMatchCLI")
    testRecipePinMatchCLI()
    T.beginTest("testRecipeCLIBinaryMustBeUnderAllowedRoots")
    testRecipeCLIBinaryMustBeUnderAllowedRoots()
    T.beginTest("testRecipeFileGlobCannotEscapeFolder")
    testRecipeFileGlobCannotEscapeFolder()
    T.beginTest("testRecipeMapPathSubset")
    testRecipeMapPathSubset()
    T.beginTest("testRecipeMapUsedLimitToPercent")
    testRecipeMapUsedLimitToPercent()
    T.beginTest("testRecipeMapRemainingFraction")
    testRecipeMapRemainingFraction()
    T.beginTest("testRecipeMapValueMoney")
    testRecipeMapValueMoney()
    T.beginTest("testRecipeMapMissingIsWarnNotZero")
    testRecipeMapMissingIsWarnNotZero()
    T.beginTest("testRecipeLegacyGenericEquivalence")
    testRecipeLegacyGenericEquivalence()
    T.beginTest("testRecipeMapWindowKinds")
    testRecipeMapWindowKinds()
    T.beginTest("testRedactRawPreview")
    testRedactRawPreview()
    T.beginTest("testNetRefusesCrossHostRedirect")
    testNetRefusesCrossHostRedirect()
    T.beginTest("testAgyTUIStripRemovesEscapeSequences")
    testAgyTUIStripRemovesEscapeSequences()
    T.beginTest("testAgyTUIStripLeavesPlainTextUnchanged")
    testAgyTUIStripLeavesPlainTextUnchanged()
    T.beginTest("testAgyTUIParseHandlesMixedLineEndings")
    testAgyTUIParseHandlesMixedLineEndings()
    T.beginTest("testAgyTUIParseRejectsTextWithoutAPanel")
    testAgyTUIParseRejectsTextWithoutAPanel()
    T.beginTest("testAgyPrintParsesTheMeasuredFixtureIntoTwoGroupsOfTwoPercents")
    testAgyPrintParsesTheMeasuredFixtureIntoTwoGroupsOfTwoPercents()
    T.beginTest("testAgyPrintRemainingFractionOneMeansZeroUsed")
    testAgyPrintRemainingFractionOneMeansZeroUsed()
    T.beginTest("testAgyPrintResetTimeParsesWithAndWithoutFractionalSeconds")
    testAgyPrintResetTimeParsesWithAndWithoutFractionalSeconds()
    T.beginTest("testAgyPrintStatusFailedYieldsNil")
    testAgyPrintStatusFailedYieldsNil()
    T.beginTest("testAgyPrintEmptyStdoutYieldsNil")
    testAgyPrintEmptyStdoutYieldsNil()
    T.beginTest("testAgyPrintMissingBucketsYieldsNil")
    testAgyPrintMissingBucketsYieldsNil()
    T.beginTest("testAgyPrintTSVTextModeIsNotParsedAsJSON")
    testAgyPrintTSVTextModeIsNotParsedAsJSON()
    T.beginTest("testAgyProviderRefusedIgnoresADigitRunThatMerelyContains403")
    testAgyProviderRefusedIgnoresADigitRunThatMerelyContains403()
    T.beginTest("testAgyProviderRefusedRecognisesAnActualHTTP403")
    testAgyProviderRefusedRecognisesAnActualHTTP403()
    T.beginTest("testAgyProviderRefusedRecognisesPermissionDenied")
    testAgyProviderRefusedRecognisesPermissionDenied()
    T.beginTest("testAgyProviderRefusedIsFalseForOrdinaryStderr")
    testAgyProviderRefusedIsFalseForOrdinaryStderr()
    T.beginTest("testAgyTUIBinaryWhitelist")
    testAgyTUIBinaryWhitelist()
    T.beginTest("testTrustedHomeRequiresExistingMarkedDirectory")
    testTrustedHomeRequiresExistingMarkedDirectory()
    T.beginTest("testColourHexRoundTrip")
    testColourHexRoundTrip()
    T.beginTest("testFmtMoney")
    testFmtMoney()
    T.beginTest("testFmtGB")
    testFmtGB()
    T.beginTest("testConfigDecodesMinimalJSON")
    testConfigDecodesMinimalJSON()
    T.beginTest("testConfigDefaultAgyIntervalIsNowHourly")
    testConfigDefaultAgyIntervalIsNowHourly()
    T.beginTest("testConfigMigratesAbsentAgyKeyOnce")
    testConfigMigratesAbsentAgyKeyOnce()
    T.beginTest("testConfigValidatedClampsExtremeStaleMinutes")
    testConfigValidatedClampsExtremeStaleMinutes()
    T.beginTest("testConfigValidatedPreservesExplicitAgyZero")
    testConfigValidatedPreservesExplicitAgyZero()
    T.beginTest("testConfigStoreRevisionMonotonicAndRollback")
    MainActor.assumeIsolated { testConfigStoreRevisionMonotonicAndRollback() }
    T.beginTest("testProcessRunnerKillsSlowSleep")
    testProcessRunnerKillsSlowSleep()
    T.beginTest("testProcessRunnerDoesNotKillCallerOnChildTimeout")
    testProcessRunnerDoesNotKillCallerOnChildTimeout()
    T.beginTest("testProcessRunnerKillsChildProcessGroup")
    testProcessRunnerKillsChildProcessGroup()
    T.beginTest("testProcessRunnerTruncatesLargeOutput")
    testProcessRunnerTruncatesLargeOutput()
    T.beginTest("testRingAnimatorStopsTimerWhenMotionOff")
    MainActor.assumeIsolated { testRingAnimatorStopsTimerWhenMotionOff() }
    T.beginTest("testPanelModelMultiAccountRowsCarryAccountNames")
    testPanelModelMultiAccountRowsCarryAccountNames()
    T.beginTest("testPanelModelOneAccountFailureKeepsOtherGauges")
    testPanelModelOneAccountFailureKeepsOtherGauges()
    T.beginTest("testRefreshCoordinatorSkipsManualOnlyOnLaunch")
    testRefreshCoordinatorSkipsManualOnlyOnLaunch()
    T.beginTest("testRefreshCoordinatorManualCoalescesDuringInFlight")
    testRefreshCoordinatorManualCoalescesDuringInFlight()
    T.beginTest("testRefreshCoordinatorDropsStaleGeneration")
    testRefreshCoordinatorDropsStaleGeneration()
    T.beginTest("testRefreshCoordinatorSlowProviderBudget")
    testRefreshCoordinatorSlowProviderBudget()
    T.beginTest("testRefreshCoordinatorRateLimitManualBypassesTimer")
    testRefreshCoordinatorRateLimitManualBypassesTimer()
    T.beginTest("testConfigStoreLanguagePersistsAfterToggleCardExpanded")
    MainActor.assumeIsolated { testConfigStoreLanguagePersistsAfterToggleCardExpanded() }
    T.beginTest("testConfigLoadNegativeRetentionClampedAndHistoryPreserves")
    testConfigLoadNegativeRetentionClampedAndHistoryPreserves()
    T.beginTest("testConfigStoreLoadSurfacesClampNotice")
    MainActor.assumeIsolated { testConfigStoreLoadSurfacesClampNotice() }
    T.beginTest("testConfigDecodingAnOldSettingsFileStillCarryingAgyDirectQuotaKeyIsTolerant")
    testConfigDecodingAnOldSettingsFileStillCarryingAgyDirectQuotaKeyIsTolerant()
    T.beginTest("testColourBandThresholds")
    testColourBandThresholds()
    T.beginTest("testRingModelPicksPrimarysShortAndUnscopedLongWindow")
    testRingModelPicksPrimarysShortAndUnscopedLongWindow()
    T.beginTest("testRingModelPrimaryWithNoGaugesIsNilOuterAndInner")
    testRingModelPrimaryWithNoGaugesIsNilOuterAndInner()
    T.beginTest("testRingModelAlertDotOnlyFromNonPrimaryProvider")
    testRingModelAlertDotOnlyFromNonPrimaryProvider()
    T.beginTest("testRingModelNumeralFormattingByStyle")
    testRingModelNumeralFormattingByStyle()
    T.beginTest("testEasedIsZeroToOneMonotoneAndEaseOut")
    testEasedIsZeroToOneMonotoneAndEaseOut()
    T.beginTest("testMenuBarConfigStyleDefaultsSurviveAnOldConfigJSON")
    testMenuBarConfigStyleDefaultsSurviveAnOldConfigJSON()
    T.beginTest("testRingImageSanityAndNoCrashOnNilValues")
    testRingImageSanityAndNoCrashOnNilValues()
    T.beginTest("testConfigIgnoresUnknownFieldsAndFillsMissingOnes")
    testConfigIgnoresUnknownFieldsAndFillsMissingOnes()
    T.beginTest("testConfigMigratesLegacyPerServiceColourKey")
    testConfigMigratesLegacyPerServiceColourKey()
    T.beginTest("testPanelNavPushPopReset")
    MainActor.assumeIsolated { testPanelNavPushPopReset() }
    T.beginTest("testEscapePopsBeforeClosing")
    testEscapePopsBeforeClosing()
    T.beginTest("testConfigDecodesLegacyColourSchemeToProvider")
    testConfigDecodesLegacyColourSchemeToProvider()
    T.beginTest("testConfigMigratesTwoColourServiceKeysToOne")
    testConfigMigratesTwoColourServiceKeysToOne()
    T.beginTest("testConfigIgnoresAdaptiveHueOffset")
    testConfigIgnoresAdaptiveHueOffset()
    T.beginTest("testPaletteWarnAlarmAreDistinctPerAppearance")
    testPaletteWarnAlarmAreDistinctPerAppearance()
    T.beginTest("testPaletteServiceColourFallback")
    testPaletteServiceColourFallback()
    T.beginTest("testStatusStripWeekHalfDerivesFromServiceColour")
    testStatusStripWeekHalfDerivesFromServiceColour()
    T.beginTest("testRingIconTrackAlphaConstant")
    testRingIconTrackAlphaConstant()
    T.beginTest("testSettingsSubtitlesUseRealCounts")
    testSettingsSubtitlesUseRealCounts()
    T.beginTest("testConfigMigratesLegacyRowsToMenuLines")
    testConfigMigratesLegacyRowsToMenuLines()
    T.beginTest("testResolveStripLineSplitsTwoWindowsIntoTopAndBottom")
    testResolveStripLineSplitsTwoWindowsIntoTopAndBottom()
    T.beginTest("testResolveStripLineMergesASingleWindowService")
    testResolveStripLineMergesASingleWindowService()
    T.beginTest("testResolveStripLineHandlesSeveralSameWindowGauges")
    testResolveStripLineHandlesSeveralSameWindowGauges()
    T.beginTest("testResolveStripLineKeepsAnExpiredWindowInATwoWindowShape")
    testResolveStripLineKeepsAnExpiredWindowInATwoWindowShape()
    T.beginTest("testResolveStripLineReturnsNoDataWhenProviderAbsent")
    testResolveStripLineReturnsNoDataWhenProviderAbsent()
    T.beginTest("testResolveStripLineReturnsNoDataWhenGaugesHaveNoPercent")
    testResolveStripLineReturnsNoDataWhenGaugesHaveNoPercent()
    T.beginTest("testCredentialPrefersTheSubscriptionTokenOverMCPTokens")
    testCredentialPrefersTheSubscriptionTokenOverMCPTokens()
    T.beginTest("testCredentialExpiryReadsBothHalvesOfTheOAuthPair")
    testCredentialExpiryReadsBothHalvesOfTheOAuthPair()
    T.beginTest("testCredentialKeyFileHonoursJSONFieldThroughTheSameNarrowing")
    testCredentialKeyFileHonoursJSONFieldThroughTheSameNarrowing()
    T.beginTest("testKeychainSecurityToolRouteIsAnAllowlistNotAPrefix")
    testKeychainSecurityToolRouteIsAnAllowlistNotAPrefix()
    T.beginTest("testClaudeProviderSeparatesAStaleTokenFromARealSignOut")
    testClaudeProviderSeparatesAStaleTokenFromARealSignOut()
    T.beginTest("testClaudeCLIBinaryWhitelist")
    testClaudeCLIBinaryWhitelist()
    T.beginTest("testClaudeCLIOnlyClaimsTheCLIsOwnCredential")
    testClaudeCLIOnlyClaimsTheCLIsOwnCredential()
    T.beginTest("testClaudeCLIEnvironmentCarriesWhatTheCredentialLookupNeeds")
    testClaudeCLIEnvironmentCarriesWhatTheCredentialLookupNeeds()
    T.beginTest("testClaudeCLIStatusStaysTheReadOnlySubcommand")
    testClaudeCLIStatusStaysTheReadOnlySubcommand()
    T.beginTest("testClaudeCLIRefreshRunsARealButMinimalPrompt")
    testClaudeCLIRefreshRunsARealButMinimalPrompt()
    T.beginTest("testClaudeCLIPromptFailureReadsTheRunWithoutJudgingIt")
    testClaudeCLIPromptFailureReadsTheRunWithoutJudgingIt()
    T.beginTest("testClaudeCLIOutcomeReadsTheReportNotJustTheExitCode")
    testClaudeCLIOutcomeReadsTheReportNotJustTheExitCode()
    T.beginTest("testClaudeCLIRedactsTheAccountFromTheDump")
    testClaudeCLIRedactsTheAccountFromTheDump()
    T.beginTest("testClaudeCLIRedactsTwoEmailAddresses")
    testClaudeCLIRedactsTwoEmailAddresses()
    T.beginTest("testClaudeProviderOffersTheRefreshOnlyWhenItCouldWork")
    testClaudeProviderOffersTheRefreshOnlyWhenItCouldWork()
    T.beginTest("testClaudeUsageParserReadsTheMeasuredThreeGaugeShape")
    testClaudeUsageParserReadsTheMeasuredThreeGaugeShape()
    T.beginTest("testClaudeUsageParserPreservesAnUnknownKindByItsRawName")
    testClaudeUsageParserPreservesAnUnknownKindByItsRawName()
    T.beginTest("testClaudeUsageParserAcceptsPercentAsIntDoubleOrString")
    testClaudeUsageParserAcceptsPercentAsIntDoubleOrString()
    T.beginTest("testClaudeUsageParserExtraUsageGaugeOnlyWhenEnabled")
    testClaudeUsageParserExtraUsageGaugeOnlyWhenEnabled()
    T.beginTest("testClaudeUsageParserFallsBackToUnifiedWindowsWhenLimitsIsEmpty")
    testClaudeUsageParserFallsBackToUnifiedWindowsWhenLimitsIsEmpty()
    T.beginTest("testClaudeUsageParserLockedReasonAddsALineAndNearLimitState")
    testClaudeUsageParserLockedReasonAddsALineAndNearLimitState()
    T.beginTest("testResolveStripLineIgnoresAModelScopedWeeklyEntry")
    testResolveStripLineIgnoresAModelScopedWeeklyEntry()
    T.beginTest("testClaudeUsagePanelShowsAllThreeGaugesEvenThoughTheStripIgnoresOne")
    testClaudeUsagePanelShowsAllThreeGaugesEvenThoughTheStripIgnoresOne()
    T.beginTest("testFindStringVisitsKeysInAStableOrder")
    testFindStringVisitsKeysInAStableOrder()
    T.beginTest("testTailBytesSurvivesACutInsideACharacter")
    testTailBytesSurvivesACutInsideACharacter()
    T.beginTest("testTailBytesReadsASmallFileWhole")
    testTailBytesReadsASmallFileWhole()
    T.beginTest("testAsOfWithdrawsAWindowThatHasAlreadyEnded")
    testAsOfWithdrawsAWindowThatHasAlreadyEnded()
    T.beginTest("testAsOfDropsTheColourTheDeadNumberWasDriving")
    testAsOfDropsTheColourTheDeadNumberWasDriving()
    T.beginTest("testAsOfKeepsAStateSomethingElseSet")
    testAsOfKeepsAStateSomethingElseSet()
    T.beginTest("testAsOfLeavesLiveReadingsAlone")
    testAsOfLeavesLiveReadingsAlone()
    T.beginTest("testStripDrawsNoBarForAWindowThatHasEnded")
    testStripDrawsNoBarForAWindowThatHasEnded()
    T.beginTest("testNearLimitIsNotAFetchFailure")
    testNearLimitIsNotAFetchFailure()
    T.beginTest("testCodexQuotaWireStatusesNeverReachTheUI")
    testCodexQuotaWireStatusesNeverReachTheUI()
    T.beginTest("testCodexSkipsAWindowlessRateLimitsEntry")
    testCodexSkipsAWindowlessRateLimitsEntry()
    T.beginTest("testTimeoutDoesNotWaitForAnUncooperativeOperation")
    testTimeoutDoesNotWaitForAnUncooperativeOperation()
    T.beginTest("testEveryLocalizationCallSiteHasATableRow")
    testEveryLocalizationCallSiteHasATableRow()
    T.beginTest("testHistoryLineShapeForAGaugeAndAFailure")
    testHistoryLineShapeForAGaugeAndAFailure()
    T.beginTest("testHistoryAppendCreatesMonthlyFileWithModeAndTwoLines")
    testHistoryAppendCreatesMonthlyFileWithModeAndTwoLines()
    T.beginTest("testHistoryRetentionDeletesOldMonthKeepsRecent")
    testHistoryRetentionDeletesOldMonthKeepsRecent()
    T.beginTest("testHistoryRetentionOnReducedMonthsClearsExports")
    testHistoryRetentionOnReducedMonthsClearsExports()
    T.beginTest("testHistoryServiceCacheInvalidatesOnRecord")
    testHistoryServiceCacheInvalidatesOnRecord()
    T.beginTest("testHistoryLoadIgnoresDamagedTrailingLine")
    testHistoryLoadIgnoresDamagedTrailingLine()
    T.beginTest("testHistoryDedupSkipsSameObservedAt")
    testHistoryDedupSkipsSameObservedAt()
    T.beginTest("testHistoryReportCSVEscapesFormulaInjection")
    testHistoryReportCSVEscapesFormulaInjection()
    T.beginTest("testHistoryReportExportProducesHTMLAndCSVWithNoSecrets")
    testHistoryReportExportProducesHTMLAndCSVWithNoSecrets()
    T.beginTest("testCursorProviderHasNoGaugesAndTheLinkLine")
    testCursorProviderHasNoGaugesAndTheLinkLine()
    T.beginTest("testResolveStripLineYieldsNoStripLineForAGaugelessCursorReading")
    testResolveStripLineYieldsNoStripLineForAGaugelessCursorReading()
    T.beginTest("testPanelHeightClampsToScreen")
    testPanelHeightClampsToScreen()
    T.beginTest("testPanelHeightNewPageNotInflatedByPreviousPageMax")
    testPanelHeightNewPageNotInflatedByPreviousPageMax()
    T.beginTest("testReadingMergeUsesNextWhenNextHasGauges")
    testReadingMergeUsesNextWhenNextHasGauges()
    T.beginTest("testReadingMergeKeepsGaugesOnWarnWithoutGauges")
    testReadingMergeKeepsGaugesOnWarnWithoutGauges()
    T.beginTest("testReadingMergeUsesNextOnFailure")
    testReadingMergeUsesNextOnFailure()
    T.beginTest("testRateLimitShouldSkip")
    testRateLimitShouldSkip()
    T.beginTest("testRateLimitRetryAfter")
    testRateLimitRetryAfter()
    T.beginTest("testAgyMergePrintFreshBeatsSilentLog")
    testAgyMergePrintFreshBeatsSilentLog()
    T.beginTest("testAgyMergeStalePrintYieldsLogWithNote")
    testAgyMergeStalePrintYieldsLogWithNote()
    T.beginTest("testAgyMergeBothEmptyIsSilent")
    testAgyMergeBothEmptyIsSilent()
    T.beginTest("testAgyFetchPausedWithFreshSnapshotShowsGauges")
    testAgyFetchPausedWithFreshSnapshotShowsGauges()
    T.beginTest("testAgyFetchPausedWithoutSnapshotFails")
    testAgyFetchPausedWithoutSnapshotFails()
    T.beginTest("testAgyPausedAutomaticTickSpawnsNoProcesses")
    testAgyPausedAutomaticTickSpawnsNoProcesses()
    T.beginTest("testAgyFetchStaleSnapshotFallsBackToLog")
    testAgyFetchStaleSnapshotFallsBackToLog()
    T.beginTest("testRecipeCLIEnvPinMismatchBlocksCommand")
    testRecipeCLIEnvPinMismatchBlocksCommand()
    T.beginTest("testRecipeEnvDeniedAtValidation")
    testRecipeEnvDeniedAtValidation()
    T.beginTest("testRecipeAllowedCustomEnvHashesIntoPin")
    testRecipeAllowedCustomEnvHashesIntoPin()
    T.beginTest("testRecipeForbiddenClaudeKeychainRejected")
    testRecipeForbiddenClaudeKeychainRejected()
    T.beginTest("testRecipeCredentialFieldPinMismatch")
    testRecipeCredentialFieldPinMismatch()
    T.beginTest("testRecipeAuthModePinMismatch")
    testRecipeAuthModePinMismatch()
    T.beginTest("testCredentialMissingFieldFailsClosed")
    testCredentialMissingFieldFailsClosed()
    T.beginTest("testWritePrivateCreatesAndReplaces")
    testWritePrivateCreatesAndReplaces()
    T.beginTest("testWritePrivateThrowsOnUnwritableDir")
    testWritePrivateThrowsOnUnwritableDir()
    T.beginTest("testReadingMergePreservesObservedAt")
    testReadingMergePreservesObservedAt()
    T.beginTest("testReadingMergeKeepsNearLimitOnWarnTransport")
    testReadingMergeKeepsNearLimitOnWarnTransport()
    T.beginTest("testAgySnapshotAccountIsolation")
    testAgySnapshotAccountIsolation()
    T.beginTest("testAgyFailedAttemptDoesNotOverwriteSnapshot")
    testAgyFailedAttemptDoesNotOverwriteSnapshot()
    T.beginTest("testAgyTransientFailureUsesBackoffNotPause")
    testAgyTransientFailureUsesBackoffNotPause()
    T.beginTest("testRecipePinBodyHashIgnoresDictionaryInsertionOrder")
    testRecipePinBodyHashIgnoresDictionaryInsertionOrder()
    T.beginTest("testAgyPrintArgvIsFourTokens")
    testAgyPrintArgvIsFourTokens()
    T.beginTest("testConfigSaveFailureShowsNoticeAndRevertsCfg")
    MainActor.assumeIsolated { testConfigSaveFailureShowsNoticeAndRevertsCfg() }
    T.beginTest("testRecipeAppKeychainMalformedJSONFailsWithoutLeakingBlob")
    testRecipeAppKeychainMalformedJSONFailsWithoutLeakingBlob()
    T.beginTest("testPanelModelCompactAndExpandedCardsCarryNotices")
    testPanelModelCompactAndExpandedCardsCarryNotices()
    T.beginTest("testAgyManualPrintSuccessSkipsTUI")
    testAgyManualPrintSuccessSkipsTUI()
    T.beginTest("testExpandedDefaultsToPrimary")
    testExpandedDefaultsToPrimary()
    T.beginTest("testCardOrderPrimaryFirst")
    testCardOrderPrimaryFirst()
    T.beginTest("testHeroPicksShortWindowFirst")
    testHeroPicksShortWindowFirst()
    T.beginTest("testHeroFallsBackToValueWhenNoPercent")
    testHeroFallsBackToValueWhenNoPercent()
    T.beginTest("testMonthKeyIsGregorianPOSIX")
    testMonthKeyIsGregorianPOSIX()
    T.beginTest("testHistoryTitleNotMenuString")
    testHistoryTitleNotMenuString()
    T.beginTest("testPanelModelBuilderLocalizesCursorAndLocalTitles")
    testPanelModelBuilderLocalizesCursorAndLocalTitles()
    T.beginTest("testPanelModelPrimaryPicksConfiguredProvider")
    testPanelModelPrimaryPicksConfiguredProvider()
    T.beginTest("testPanelModelHeroUsesShortWindowGauge")
    testPanelModelHeroUsesShortWindowGauge()
    T.beginTest("testPanelModelChipOrderIsLongThenModelSortedThenOther")
    testPanelModelChipOrderIsLongThenModelSortedThenOther()
    T.beginTest("testPanelModelSecondaryOrderIsFixed")
    testPanelModelSecondaryOrderIsFixed()
    T.beginTest("testPanelModelSecondaryOrderExcludesThePrimary")
    testPanelModelSecondaryOrderExcludesThePrimary()
    T.beginTest("testPanelModelFailureReadingYieldsTheAlarmMessage")
    testPanelModelFailureReadingYieldsTheAlarmMessage()
    T.beginTest("testPanelModelMissingPrimaryYieldsTheNoDataState")
    testPanelModelMissingPrimaryYieldsTheNoDataState()
    T.beginTest("testPanelFormatResetTextPastIsEndedFutureIsUntilReset")
    testPanelFormatResetTextPastIsEndedFutureIsUntilReset()
    T.beginTest("testConfigPanelDefaultsToCardsForAnOldConfigJSON")
    testConfigPanelDefaultsToCardsForAnOldConfigJSON()
    T.beginTest("testSparklineSamplesFiltersByProviderAccountAndGauge")
    testSparklineSamplesFiltersByProviderAccountAndGauge()
    T.beginTest("testSparklineSamplesIgnoresBadLines")
    testSparklineSamplesIgnoresBadLines()
    T.beginTest("testSparklineSamplesRespectsTheTwentyFourHourWindow")
    testSparklineSamplesRespectsTheTwentyFourHourWindow()
    T.beginTest("testSparklineBreaksOnGapAndFailure")
    testSparklineBreaksOnGapAndFailure()
    T.beginTest("testParseNumberRejectsNaNInfinityBoolAndHugeMagnitude")
    testParseNumberRejectsNaNInfinityBoolAndHugeMagnitude()
    T.beginTest("testParsePercentRejectsNonPositiveLimit")
    testParsePercentRejectsNonPositiveLimit()
    T.beginTest("testCodexNewestSnapshotOnlySearchesFirstNineFilesPerDay")
    testCodexNewestSnapshotOnlySearchesFirstNineFilesPerDay()
    T.beginTest("testAgyParseQuotaLogLine42PercentLeftMeans58Used")
    testAgyParseQuotaLogLine42PercentLeftMeans58Used()
    T.beginTest("testHistoryReportCSVEscapesMaliciousGaugeLabels")
    testHistoryReportCSVEscapesMaliciousGaugeLabels()
    T.beginTest("testHistoryReportCSVEscapesEmbeddedCR")
    testHistoryReportCSVEscapesEmbeddedCR()
    T.beginTest("testSparklineDoesNotMergeAcrossAccounts")
    testSparklineDoesNotMergeAcrossAccounts()
    T.beginTest("testNetRejectsResponsesLargerThanTwoMiB")
    testNetRejectsResponsesLargerThanTwoMiB()
    T.beginTest("testDisplayLimitTruncatesLongStrings")
    testDisplayLimitTruncatesLongStrings()
    T.beginTest("testPollingTimerSetsTenPercentTolerance")
    testPollingTimerSetsTenPercentTolerance()
    T.beginTest("testLocalAIProbesRunInParallel")
    testLocalAIProbesRunInParallel()
    T.beginTest("testPanelHeightBuildsViewAndMeasuresContent")
    testPanelHeightBuildsViewAndMeasuresContent()
    T.beginTest("testRecipeFileGlobRejectsSymlinkEscape")
    testRecipeFileGlobRejectsSymlinkEscape()
}
