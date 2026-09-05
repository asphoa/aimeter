import Foundation

/// Claude Code subscription utilisation, one row per configured account.
///
/// There *is* a "read my usage" endpoint, and every earlier version of this
/// file was wrong to say otherwise. Measured 2026-09-04 against Claude Code
/// CLI 2.1.260: a plain `GET https://api.anthropic.com/api/oauth/usage`, with
/// exactly the OAuth headers already sent below, returns HTTP 200 and a JSON
/// body describing every window the CLI's own `/usage` screen shows -
/// `limits[]` (session, weekly, and per-model-scoped weekly entries, each with
/// a `percent` and `resets_at`), the unified `five_hour`/`seven_day` windows,
/// and `extra_usage` (pay-as-you-go credits). A binary grep of the CLI found
/// `api/oauth/usage` as the only usage path it calls - this is that endpoint,
/// not a guess at one. Every refresh used to spend a real `POST v1/messages`
/// probe (1 output token of the cheapest model) purely to read the
/// rate-limit headers off its response; that request is gone. Nothing here
/// speaks any part of Anthropic's authentication protocol beyond presenting
/// the token already stored for this account, same as the old probe did.
///
/// The parsed structure - kinds, percents, resets, extra_usage numbers, never
/// the request headers or the token - is dumped to
/// ~/.config/aimeter/last-usage-<account>.json so the parsing can be checked
/// against reality instead of assumed.
final class ClaudeProvider: Provider, @unchecked Sendable {
    let id = "claude"
    var title: String { L.t("p.claude") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.claude())
        var out: [Reading] = []
        for a in accounts {
            // A manual check may launch the CLI twice to unstick a stale token
            // - once for the free local status check, once for the prompt that
            // does the refreshing - and then still has the probe request to
            // make. Budgeting the automatic 25s for all three is how that path
            // would report a timeout instead of the reading it had just gone
            // and fetched. This is a ceiling on three sub-timeouts (20 + 30 +
            // 20), not an expectation: measured end to end, the two CLI runs
            // take about three seconds together.
            let budget: Double = manual ? 90 : 25
            out.append(await withTimeout(budget, { await self.fetch(a, manual: manual) },
                                         onTimeout: { .failed(self.id, self.title, a.name,
                                                              L.t("e.timeout.keychain")) }))
        }
        return out
    }

    private func fetch(_ account: AccountSpec, manual: Bool = false,
                       retryingAfter401: Bool = false, afterCLI: Bool = false) async -> Reading {
        // Claude Code's stored access token is short-lived - the item on the
        // machine this was written against carried an expiry a few hours out,
        // against a refresh token good for another twelve days. The CLI trades
        // one for the other when it next runs, and nothing else does. A menu bar
        // polling every sixty seconds is not a Claude Code session, so on a
        // machine where someone signed in once and then only watched this app,
        // the access token goes stale by itself while the account behind it is
        // untouched. That is the whole of the "expired after a few hours" report.
        //
        // The cached copy used to be dropped here on every refresh whose token
        // looked expired, so that a rotation by the CLI would be noticed. It
        // was the right worry and the wrong instrument: a stale token stays
        // stale for hours, and dropping the cache each minute meant a real,
        // uncached keychain read each minute - every one of them a chance for
        // macOS to put its password panel in front of someone who was not
        // asking for anything. `Credential.blob` now settles the same question
        // off the item's modification date, which costs no authorisation at
        // all, so a rotation is still picked up on the very next refresh and
        // an unrotated item is not touched. See `Keychain.modified`.

        // A person pressing the button is the one thing allowed to re-ask a
        // question the keychain panel was told "no" to. Only the refusal is
        // forgotten; a token read successfully stays cached, so a manual check
        // on a healthy row costs no panel at all.
        if manual, !retryingAfter401, !afterCLI {
            Credential.forgetRefusal(account)
        }

        let token: String
        switch Credential.read(account) {
        case .success(let t): token = t
        case .failure(let e):
            if e.blank, ClaudeCLI.ownsCLICredential(account) {
                // The item read fine and holds no token right now. That is
                // not necessarily a sign-out - see `Fail.blank`'s doc comment
                // for the 2026-09-04 correction of an earlier claim here that
                // it was - so the message says only what is true and what to
                // do about it: press "Check now", which runs claude and
                // re-reads, or run claude directly in a terminal.
                return .failed(id, title, account.name, L.t("c.blank.cli"))
            }
            guard e.denied else { return .failed(id, title, account.name, e.message) }
            // Not a lost sign-in, and not this app malfunctioning: macOS threw
            // away the grant when Claude Code last rewrote its own stored
            // token, and is asking again. Said plainly, because the previous
            // message told the user to relaunch the app, which does not help -
            // the panel returns after the next token refresh whatever they do.
            // Deliberately .warn: nothing is broken and nothing is spent.
            return Reading(id: id, title: title, account: account.name,
                           lines: [e.message, L.t("k.denied.why")], state: .warn)
        }

        let expiry = Credential.expiry(account)
        if expiry.accessExpired {
            // The one thing that refreshes this token is the CLI running, and
            // this app is not the CLI. So run it - once, because a person asked,
            // and only when a refresh could actually work.
            if manual, !afterCLI, cfg.claudeRefreshViaCLI, expiry.refreshAlive,
               ClaudeCLI.ownsCLICredential(account) {
                return await refreshViaCLI(account, expiry)
            }
            return refused(account, expiry)
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("cli", forHTTPHeaderField: "x-app")

        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch Net.JSONError.tooLarge {
            return Reading(id: id, title: title, account: account.name,
                           lines: [L.t("n.toolarge")], state: .warn)
        }
        catch Net.JSONError.invalid {
            return .failed(id, title, account.name, L.t("e.connplain"))
        }
        catch { return .failed(id, title, account.name, L.t("e.conn", error.localizedDescription)) }

        if http.statusCode == 401 {
            // The cached token may simply have been rotated by Claude Code
            // since launch; drop it and read the keychain once more before
            // telling the user their session expired.
            guard retryingAfter401 else {
                Credential.invalidate(account)
                return await fetch(account, manual: manual,
                                   retryingAfter401: true, afterCLI: afterCLI)
            }
            return refused(account, Credential.expiry(account))
        }
        if http.statusCode == 429 {
            let seconds = RateLimit.retryAfter(header: http.value(forHTTPHeaderField: "Retry-After"))
            let until = Date().addingTimeInterval(seconds)
            RateLimit.mark(id: id, until: until)
            var r = Reading(id: id, title: title, account: account.name,
                            lines: [L.t("c.ratelimited", Fmt.relative(until))], state: .warn)
            r.snapshotAt = Date()
            return r
        }
        if http.statusCode != 200 {
            let msg = findString(in: obj, names: ["message"]) ?? L.t("c.noheaders")
            return .failed(id, title, account.name, L.t("e.http2", "\(http.statusCode)", msg))
        }

        dumpUsage(obj, account: account.name)

        let (gauges, lines, parsedState) = ClaudeProvider.readings(fromUsage: obj)
        var r = Reading(id: id, title: title, account: account.name)
        let now = Date()
        r.gauges = gauges.map { gauge in
            var g = gauge
            g.observedAt = now
            g.source = "api"
            return g
        }
        r.lines = lines
        r.state = max(parsedState, worstState(r.gauges))
        return r
    }

    /// Pure, testable parse of the `/api/oauth/usage` body. Nothing here
    /// touches the network or the keychain, so the whole shape can be pinned
    /// with fixtures copied straight from a measured response.
    static func readings(fromUsage obj: Any) -> (gauges: [Gauge], lines: [String], state: ReadingState) {
        var gauges: [Gauge] = []
        var lines: [String] = []
        var state: ReadingState = .ok

        func resetDate(_ raw: Any?) -> Date? {
            guard let s = raw as? String else { return nil }
            return ISO8601DateFormatter.withFractional.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
        }

        func unifiedGauge(_ win: [String: Any], label: String, kind: GaugeKind) -> Gauge? {
            switch Parse.number(win["utilization"]) {
            case .value(let pct):
                var g = Gauge(label: label, percent: pct, text: String(format: "%.0f%%", pct),
                                resetsAt: resetDate(win["resets_at"]))
                g.kind = kind
                return g
            case .missing, .invalid:
                return nil
            }
        }

        let root = obj as? [String: Any]
        let limits = root?["limits"] as? [[String: Any]] ?? []
        var hasSession = false
        var hasWeeklyAll = false

        for entry in limits {
            let kind = entry["kind"] as? String ?? "?"
            let label: String
            var gk: GaugeKind = .other
            switch kind {
            case "session":
                label = L.t("g.5h"); gk = .shortWindow
            case "weekly_all":
                label = L.t("g.week"); gk = .longWindow
            case "weekly_scoped":
                let model = (((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)
                    ?? "?"
                label = L.t("g.week.model", model); gk = .modelWindow
            default:
                // Never dropped silently, even for a shape not seen yet - the
                // raw kind string is a better label than no row at all.
                label = kind; gk = .other
            }
            switch Parse.number(entry["percent"]) {
            case .value(let pct):
                var g = Gauge(label: label, percent: pct, text: String(format: "%.0f%%", pct),
                                resetsAt: resetDate(entry["resets_at"]))
                g.kind = gk
                gauges.append(g)
                if kind == "session" { hasSession = true }
                if kind == "weekly_all" { hasWeeklyAll = true }
                if let severity = entry["severity"] as? String, severity != "normal" {
                    state = max(state, .warn)
                }
            case .invalid:
                state = max(state, .warn)
            case .missing:
                break
            }
        }

        if let root {
            if !hasSession, let win = root["five_hour"] as? [String: Any],
               let g = unifiedGauge(win, label: L.t("g.5h"), kind: .shortWindow) {
                gauges.append(g)
            }
            if !hasWeeklyAll, let win = root["seven_day"] as? [String: Any],
               let g = unifiedGauge(win, label: L.t("g.week"), kind: .longWindow) {
                gauges.append(g)
            }

            for key in ["five_hour", "seven_day"] {
                guard let win = root[key] as? [String: Any],
                      let reason = win["locked_reason"] as? String else { continue }
                lines.append(L.t("c.locked", reason))
                state = max(state, .nearLimit)
            }
            if let extra = root["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true {
                switch (Parse.number(extra["used_credits"]), Parse.number(extra["monthly_limit"])) {
                case (.value(let used), .value(let limitAmt)):
                    let places = (extra["decimal_places"] as? Int) ?? 2
                    let currency = (extra["currency"] as? String) ?? "USD"
                    let scale = pow(10.0, Double(places))
                    let usedMoney = used / scale
                    let limitMoney = limitAmt / scale
                    let pct = limitAmt > 0 ? (used / limitAmt) * 100 : 0
                    let text = "\(Fmt.money(usedMoney, currency)) of \(Fmt.money(limitMoney, currency))"
                    var g = Gauge(label: L.t("g.extra"), percent: pct, text: text)
                    g.kind = .other
                    gauges.append(g)
                case (.invalid, _), (_, .invalid):
                    state = max(state, .warn)
                case (.missing, _), (_, .missing):
                    break
                }
            }
        }

        if gauges.isEmpty {
            lines.append(L.t("c.schema"))
            state = max(state, .warn)
        }

        return (gauges, lines, state)
    }

    /// Runs the vendor's own CLI, then reads the keychain again.
    ///
    /// Nothing here writes a credential or speaks any part of Anthropic's
    /// authentication protocol: it starts the genuine binary and lets that
    /// program refresh its own token the way it does for its own sake. See
    /// ClaudeCLI for why that line matters and where it is drawn.
    ///
    /// Two steps, and the first one is free. `auth status` cannot refresh
    /// anything - measured, twice, on 2026-08-27, which is the whole subject of
    /// ClaudeCLI's opening comment - but it can say whether this machine is
    /// signed in at all, locally, in under half a second, and without any
    /// possibility of a browser window. Only when it says yes does the second
    /// step run a real one-turn prompt, which is what makes the CLI need a
    /// working token and therefore go and get one.
    ///
    /// **The keychain is the verdict, not the subprocess.** Whatever the prompt
    /// run says about itself, the question being asked is "is the stored token
    /// fresh now", and the only place that can be answered is the keychain. The
    /// broken version asked the subprocess instead, was told `"loggedIn": true`,
    /// and reported success at refreshing a token it had not refreshed. So the
    /// run's own complaint, if it has one, is used for the message and never for
    /// the decision.
    ///
    /// Each way this can fail says something different, and each is reported as
    /// itself. An earlier draft returned the unchanged stale message whatever
    /// happened, which would have reproduced the original complaint exactly -
    /// a button pressed, nothing visibly different, no way to tell whether it
    /// had even tried.
    private func refreshViaCLI(_ account: AccountSpec,
                               _ expiry: Credential.Expiry) async -> Reading {
        guard let bin = ClaudeCLI.binary(cfg.claudeBinary) else {
            return refused(account, expiry, note: L.t("c.refresh.nobin"))
        }
        guard let home = trustedHome(account.home ?? "~", marker: ".claude") else {
            return refused(account, expiry, note: L.t("c.refresh.nobin"))
        }
        switch await Task.detached(priority: .utility, operation: {
            ClaudeCLI.status(binary: bin, home: home)
        }).value {
        case .failed(let why):
            return refused(account, expiry, note: L.t("c.refresh.failed", why))
        case .signedOut:
            // The CLI has the last word on this: it can see a credential this
            // app cannot, and if it says there is none, the stored blob's own
            // dates are not the thing to report. Nothing is spent finding out.
            return .failed(id, title, account.name, L.t("c.refresh.signedout"))
        case .signedIn:
            break
        }

        let complaint = await Task.detached(priority: .utility) {
            ClaudeCLI.prompt(binary: bin, home: home)
        }.value
        Credential.invalidate(account)
        let fresh = Credential.expiry(account)
        guard !fresh.accessExpired else {
            return refused(account, fresh,
                           note: complaint.map { L.t("c.refresh.failed", $0) }
                               ?? L.t("c.refresh.stale"))
        }
        return await fetch(account, manual: true, afterCLI: true)
    }

    /// A refused token, reported in the terms that decide what the user has to
    /// do about it. Two different situations arrive wearing the same 401: an
    /// access token that has merely gone stale needs the CLI to run once, which
    /// takes a second and keeps the session; a refresh token past its own expiry
    /// needs a real sign-in. Telling the user to log in again when they only
    /// needed the first is how this app spent its first version being wrong.
    ///
    /// What this deliberately does *not* do is perform the refresh itself. The
    /// refresh token is right there in the same blob, and the exchange is a
    /// single POST - but the endpoint is Anthropic's private one, reachable only
    /// by presenting the Claude Code CLI's own client_id, which is that
    /// application's identity and not this one's. This project already drew that
    /// line for Antigravity: calling an API with a token the real client issued
    /// is fair use of a credential the user owns; reimplementing another
    /// application's authentication handshake to mint fresh sessions in its name
    /// is impersonating it. The technical case says the same thing - the
    /// exchange rotates the refresh token, so this app would have to write the
    /// replacement back into the CLI's own keychain item, unlocked, racing any
    /// running claude process. Losing that race logs the user out for real,
    /// which is the very complaint this code exists to answer.
    /// Internal rather than private so the test suite can hold the two branches
    /// apart: which of these a user reads decides whether they spend a second
    /// or re-authenticate, and that is worth pinning by string, not by inspection.
    ///
    /// `note` carries what a CLI run just established, when there was one. With
    /// no note, the row also gains the line telling the user that pressing
    /// Check now will do the run for them - the affordance is the point, and it
    /// belongs where the problem is described, not in a manual nobody reads.
    func refused(_ account: AccountSpec, _ expiry: Credential.Expiry,
                 note: String? = nil) -> Reading {
        guard let refresh = expiry.refresh, refresh > Date() else {
            return .failed(id, title, account.name, L.t("c.expired"))
        }
        // Deliberately .warn, not .failure: the whole point of telling these two
        // cases apart is that this one is a one-second fix and the sign-in is
        // fine, so it should not read as urgent as an actual logout - the red
        // dot was undermining the message right next to it.
        var r = Reading(id: id, title: title, account: account.name,
                        lines: [L.t("c.stale")], state: .warn)
        r.lines.append(L.t("c.stale.session", Fmt.relative(refresh)))
        if let note {
            r.lines.append(note)
        } else if cfg.claudeRefreshViaCLI, ClaudeCLI.ownsCLICredential(account),
                  ClaudeCLI.binary(cfg.claudeBinary) != nil {
            r.lines.append(L.t("c.refresh.offer"))
        }
        return r
    }

    /// Dumps the parsed usage *structure* only - kinds, percents, resets,
    /// extra_usage numbers - never the request headers, which is where a
    /// token would have lived on the old probe path. There are no tokens in
    /// this response at all, but the rule is kept anyway: this file writes
    /// what it parsed, not what it received.
    private func dumpUsage(_ obj: Any, account: String) {
        let (gauges, lines, state) = ClaudeProvider.readings(fromUsage: obj)
        let payload: [String: Any] = [
            "_fetched_at": ISO8601DateFormatter().string(from: Date()),
            "_state": "\(state)",
            "lines": lines,
            "gauges": gauges.map { g -> [String: Any] in
                [
                    "label": g.label,
                    "percent": g.percent as Any,
                    "text": g.text,
                    "kind": g.kind.rawValue,
                    "resets_at": g.resetsAt.map { ISO8601DateFormatter().string(from: $0) } as Any
                ]
            }
        ]
        let safe = account.replacingOccurrences(of: "/", with: "_")
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        if (try? writePrivate(data, to: Config.dir + "/last-usage-\(safe).json")) == nil {
            Diagnostics.warn("claude usage snapshot write failed: \(safe)")
        }
    }
}

