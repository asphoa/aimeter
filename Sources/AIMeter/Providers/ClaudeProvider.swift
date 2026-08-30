import Foundation

/// Claude Code subscription utilisation, one row per configured account.
///
/// There is no "read my usage" endpoint, so we do what Clawdmeter does: send a
/// deliberately minimal request (1 output token of the cheapest model) and read
/// the rate-limit headers off the response. Every `anthropic-ratelimit-*` header
/// received is dumped to ~/.config/aimeter/last-headers-<account>.json so the
/// parsing can be checked against reality instead of assumed.
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

        let token: String
        switch Credential.read(account) {
        case .success(let t): token = t
        case .failure(let e):
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

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": cfg.claudeProbeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]]
        ])

        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch { return .failed(id, title, account.name, L.t("e.conn", error.localizedDescription)) }

        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let ks = k as? String, let vs = v as? String else { continue }
            if ks.lowercased().hasPrefix("anthropic-ratelimit") { headers[ks.lowercased()] = vs }
        }
        dumpHeaders(headers, status: http.statusCode, account: account.name)

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
        if headers.isEmpty {
            let msg = findString(in: obj, names: ["message"]) ?? L.t("c.noheaders")
            return .failed(id, title, account.name, L.t("e.http2", "\(http.statusCode)", msg))
        }

        var r = Reading(id: id, title: title, account: account.name)
        for (key, label, kind) in [("5h", L.t("g.5h"), GaugeKind.shortWindow),
                                   ("7d", L.t("g.week"), GaugeKind.longWindow)] {
            if var g = gauge(headers: headers, window: key, label: label) {
                g.kind = kind
                r.gauges.append(g)
            }
        }
        // Overage only matters once it is actually being used; showing a
        // permanent 0% row would just be noise.
        if let over = gauge(headers: headers, window: "overage", label: L.t("g.overage")),
           (over.percent ?? 0) > 0 {
            r.gauges.append(over)
        }
        if r.gauges.isEmpty {
            r.lines = headers.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            r.state = .warn
            return r
        }
        if let status = headers.first(where: { $0.key.contains("status") })?.value, status != "allowed" {
            r.lines.append(L.t("c.status", status))
            r.state = .warn
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
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

    private func gauge(headers: [String: String], window: String, label: String) -> Gauge? {
        func value(_ needles: [String]) -> String? {
            headers.first { h in h.key.contains(window) && needles.contains { h.key.contains($0) } }?.value
        }
        guard let raw = value(["utilization", "utilisation", "used"]), var pct = Double(raw) else { return nil }
        // Confirmed 2026-08-23: Anthropic reports these as a 0...1 fraction
        // ("0.54" = 54%). Anything at or below 1.0 is treated as a fraction -
        // reading a real 100% as 1% would be the dangerous direction to be wrong in.
        if pct <= 1.0 { pct *= 100 }
        var resets: Date?
        if let rs = value(["reset"]) {
            resets = Double(rs).map { Date(timeIntervalSince1970: $0) } ?? ISO8601DateFormatter().date(from: rs)
        }
        return Gauge(label: label, percent: pct, text: String(format: "%.0f%%", pct), resetsAt: resets)
    }

    private func dumpHeaders(_ h: [String: String], status: Int, account: String) {
        var payload: [String: Any] = h
        payload["_http_status"] = status
        payload["_fetched_at"] = ISO8601DateFormatter().string(from: Date())
        let safe = account.replacingOccurrences(of: "/", with: "_")
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        writePrivate(data, to: Config.dir + "/last-headers-\(safe).json")
    }
}

func worstState(_ gauges: [Gauge]) -> ReadingState {
    var s = ReadingState.ok
    for g in gauges {
        guard let p = g.percent else { continue }
        if p >= 90 { s = max(s, .nearLimit) } else if p >= 70 { s = max(s, .warn) }
    }
    return s
}

extension ReadingState: Comparable {
    static func < (a: ReadingState, b: ReadingState) -> Bool { a.rawValue < b.rawValue }
}
