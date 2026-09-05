import Foundation

/// Codex (ChatGPT plan) limits, one row per CODEX_HOME.
///
/// Codex exposes no usage endpoint, but it writes a `rate_limits` snapshot into
/// every session rollout file as it works, so we read the newest one. The number
/// is therefore accurate as of the last time Codex ran, not live - each reading
/// carries its own timestamp so a stale figure is labelled stale rather than
/// passed off as current.
///
/// There is no fresher local source and no read-only way to ask. Checked on
/// 2026-08-27 against codex-cli 0.149.1: `codex doctor --json` reports auth,
/// config and daemon health and no usage at all, and none of the four SQLite
/// databases in `~/.codex` (`state_5`, `logs_2`, `queue_1`, `thread_history_1`)
/// contains the string `rate_limits`. The rollout files are the whole of it.
/// The only way to a live figure is to make a model request, which would spend
/// the very quota being reported - so this row is a snapshot by construction,
/// and the work is in saying so accurately. `Reading.asOf` does that part.
///
/// The shape of what is parsed here moves under us, which is why nothing below
/// keys off slot names. Observed in this machine's own session files:
/// `primary` was a weekly window (`window_minutes: 10080`) from 31 July to 25
/// August, a 30-day one (43200) on 2 August, both slots null on 7 August, and
/// from 26 August a five-hour window (300) with the weekly demoted to
/// `secondary`. Labelling by `window_minutes` survived all four; labelling by
/// slot would have called the weekly figure "5-hour" for a month.
final class CodexProvider: Provider, @unchecked Sendable {
    let id = "codex"
    var title: String { L.t("p.codex") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        cfg.accounts(id, fallback: Discovery.codex()).map { read($0) }
    }

    private func read(_ account: AccountSpec) -> Reading {
        let root = sessionsRoot(account)
        guard FileManager.default.fileExists(atPath: root) else {
            return .off(id, title, account.name, L.t("e.notfound", root))
        }
        guard let (payload, when, partial) = newestSnapshot(root),
              let limits = payload["rate_limits"] as? [String: Any] else {
            return .off(id, title, account.name, L.t("x.nosnapshot"))
        }

        var r = Reading(id: id, title: title, account: account.name)
        r.snapshotAt = when
        if partial { r.lines.append(L.t("x.partial")) }

        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any] else { continue }
            switch Parse.findNumber(in: w, names: ["used_percent"]) {
            case .value(let used):
                let minutes = parseNumber(in: w, names: ["window_minutes"]) ?? 0
                let label: String
                switch minutes {
                case 0: label = L.t(key == "primary" ? "g.limit.main" : "g.limit.sec")
                case ..<61: label = L.t("g.window.min", Int(minutes))
                case ..<1440: label = L.t("g.window.hour", Int(minutes / 60))
                case 10080: label = L.t("g.week")
                default: label = L.t("g.window.day", Int(minutes / 1440))
                }
                let resets = parseNumber(in: w, names: ["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                let kind: GaugeKind = minutes > 0 && minutes <= 300 ? .shortWindow
                                    : (minutes >= 1440 ? .longWindow : .other)
                r.gauges.append(Gauge(label: label, percent: used,
                                      text: String(format: "%.0f%%", used), resetsAt: resets, kind: kind))
            case .missing, .invalid:
                continue
            }
        }
        if r.gauges.isEmpty { return .off(id, title, account.name, L.t("x.nopercent")) }

        if let plan = limits["plan_type"] as? String { r.lines.append(L.t("x.plan", plan)) }
        if let credits = limits["credits"] as? [String: Any] {
            if (credits["unlimited"] as? Bool) == true {
                r.lines.append(L.t("x.credits.unl"))
            } else {
                switch Parse.findString(in: credits, names: ["balance"]) {
                case .value(let bal) where bal != "0":
                    r.lines.append(L.t("x.credits", bal))
                default:
                    break
                }
            }
        }
        if let rawStatus = limits["rate_limit_reached_type"] as? String,
           let status = Self.rateLimitStatus(rawStatus) {
            r.lines.append(L.t(status.key))
            r.state = max(r.state, status.state)
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
    }

    private func sessionsRoot(_ account: AccountSpec) -> String {
        let home = expand(account.home ?? "~")
        let nested = home + "/.codex/sessions"
        if FileManager.default.fileExists(atPath: nested) { return nested }
        return home + "/sessions"
    }

    /// This field is an implementation enum from Codex's local snapshot, not
    /// language for a person.  Do not leak a new wire value into the menu: an
    /// unrecognised value is still a useful warning, but it is described in
    /// stable human terms until this mapping can be extended deliberately.
    static func rateLimitStatus(_ raw: String) -> (key: String, state: ReadingState)? {
        switch raw.lowercased() {
        case "", "allowed":
            return nil
        case "allowed_warning":
            return ("x.rate.allowedwarning", .warn)
        case "rate_limit_reached", "reached", "blocked":
            return ("x.rate.reached", .nearLimit)
        default:
            return ("x.rate.unknown", .warn)
        }
    }

    /// Walks sessions/YYYY/MM/DD newest-first for the most recent token_count
    /// event carrying rate_limits.
    ///
    /// Within a day it reads every candidate file and keeps the entry with the
    /// newest event timestamp, rather than taking the first hit in the
    /// most-recently-touched file. Those are not the same file when several
    /// Codex sessions are open at once, which is normal here - 26 August has
    /// thirteen rollouts, several written within the same minute. A session
    /// that is still being appended to for other reasons wins on modification
    /// time while another session logged the newer quota line, and the older
    /// figure would then be shown as the current one.
    /// Whether a `rate_limits` object actually carries a number to show.
    /// Codex has been observed writing entries for a `limit_id` (e.g.
    /// "premium") whose `primary`/`secondary` are both null - a real object
    /// under the same key, just with nothing in it. Internal rather than
    /// private so the test suite can hold it against real captured shapes.
    static func hasUsableWindow(_ rateLimits: [String: Any]) -> Bool {
        for key in ["primary", "secondary"] {
            if let w = rateLimits[key] as? [String: Any] {
                switch Parse.findNumber(in: w, names: ["used_percent"]) {
                case .value: return true
                case .missing, .invalid: break
                }
            }
        }
        return false
    }

    private func parseNumber(in obj: Any, names: [String]) -> Double? {
        switch Parse.findNumber(in: obj, names: names) {
        case .value(let n): return n
        case .missing, .invalid: return nil
        }
    }

    private func newestSnapshot(_ root: String) -> ([String: Any], Date, Bool)? {
        let fm = FileManager.default
        func children(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted(by: >).map { p + "/" + $0 }
        }
        var dayDirs: [String] = []
        var truncatedDays = false
        outer: for year in children(root) {
            for month in children(year) {
                dayDirs.append(contentsOf: children(month))
                if dayDirs.count > 6 { truncatedDays = true; break outer }
            }
        }
        var partial = truncatedDays
        for day in dayDirs.prefix(6) {
            let files = ((try? fm.contentsOfDirectory(atPath: day)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .map { name -> (path: String, date: Date) in
                    let full = day + "/" + name
                    let d = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date
                    return (full, d ?? .distantPast)
                }
                .sorted { $0.date > $1.date }
            if files.count > 9 { partial = true }
            var best: ([String: Any], Date)?
            for f in files.prefix(9) {
                guard let text = tailBytes(f.path) else { continue }
                for line in text.split(separator: "\n").reversed() {
                    guard line.contains("\"rate_limits\"") ,
                          let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                          let dict = obj as? [String: Any],
                          let payload = dict["payload"] as? [String: Any],
                          let rateLimits = payload["rate_limits"] as? [String: Any] else { continue }
                    guard Self.hasUsableWindow(rateLimits) else { continue }
                    var when = f.date
                    if let parsed = Self.eventTimestamp(dict["timestamp"]) { when = parsed }
                    if best == nil || when > best!.1 { best = (payload, when) }
                    break
                }
            }
            if let best { return (best.0, best.1, partial) }
        }
        return nil
    }

    /// Parses rollout event timestamps: ISO-8601 strings (with or without
    /// fractional seconds) or unix epoch numbers.
    static func eventTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            return ISO8601DateFormatter.withFractional.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
        }
        switch Parse.number(raw) {
        case .value(let n): return Date(timeIntervalSince1970: n)
        case .missing, .invalid: return nil
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
