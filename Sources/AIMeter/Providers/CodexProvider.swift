import Foundation

/// Codex (ChatGPT plan) limits, one row per CODEX_HOME.
///
/// Codex exposes no usage endpoint, but it writes a `rate_limits` snapshot into
/// every session rollout file as it works, so we read the newest one. The number
/// is therefore accurate as of the last time Codex ran, not live - each reading
/// carries its own timestamp so a stale figure is labelled stale rather than
/// passed off as current.
final class CodexProvider: Provider, @unchecked Sendable {
    let id = "codex"
    var title: String { L.t("p.codex") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll() async -> [Reading] {
        cfg.accounts(id, fallback: Discovery.codex()).map { read($0) }
    }

    private func read(_ account: AccountSpec) -> Reading {
        let root = expand(account.home ?? "~") + "/.codex/sessions"
        guard FileManager.default.fileExists(atPath: root) else {
            return .off(id, title, account.name, L.t("e.notfound", root))
        }
        guard let (payload, when) = newestSnapshot(root),
              let limits = payload["rate_limits"] as? [String: Any] else {
            return .off(id, title, account.name, L.t("x.nosnapshot"))
        }

        var r = Reading(id: id, title: title, account: account.name)
        r.snapshotAt = when

        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let used = findNumber(in: w, names: ["used_percent"]) else { continue }
            let minutes = findNumber(in: w, names: ["window_minutes"]) ?? 0
            let label: String
            switch minutes {
            case 0: label = L.t(key == "primary" ? "g.limit.main" : "g.limit.sec")
            case ..<61: label = L.t("g.window.min", Int(minutes))
            case ..<1440: label = L.t("g.window.hour", Int(minutes / 60))
            case 10080: label = L.t("g.week")
            default: label = L.t("g.window.day", Int(minutes / 1440))
            }
            let resets = findNumber(in: w, names: ["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            let kind: GaugeKind = minutes > 0 && minutes <= 300 ? .shortWindow
                                : (minutes >= 1440 ? .longWindow : .other)
            r.gauges.append(Gauge(label: label, percent: used,
                                  text: String(format: "%.0f%%", used), resetsAt: resets, kind: kind))
        }
        if r.gauges.isEmpty { return .off(id, title, account.name, L.t("x.nopercent")) }

        if let plan = limits["plan_type"] as? String { r.lines.append(L.t("x.plan", plan)) }
        if let credits = limits["credits"] as? [String: Any] {
            if (credits["unlimited"] as? Bool) == true {
                r.lines.append(L.t("x.credits.unl"))
            } else if let bal = findString(in: credits, names: ["balance"]), bal != "0" {
                r.lines.append(L.t("x.credits", bal))
            }
        }
        if let reached = limits["rate_limit_reached_type"] as? String {
            r.lines.append(L.t("x.reached", reached))
            r.state = .error
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
    }

    /// Walks sessions/YYYY/MM/DD newest-first for the first token_count event
    /// carrying rate_limits.
    private func newestSnapshot(_ root: String) -> ([String: Any], Date)? {
        let fm = FileManager.default
        func children(_ p: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted(by: >).map { p + "/" + $0 }
        }
        var dayDirs: [String] = []
        outer: for year in children(root) {
            for month in children(year) {
                dayDirs.append(contentsOf: children(month))
                if dayDirs.count > 6 { break outer }
            }
        }
        for day in dayDirs.prefix(6) {
            let files = ((try? fm.contentsOfDirectory(atPath: day)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .map { name -> (path: String, date: Date) in
                    let full = day + "/" + name
                    let d = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date
                    return (full, d ?? .distantPast)
                }
                .sorted { $0.date > $1.date }
            for f in files.prefix(8) {
                guard let text = tailBytes(f.path) else { continue }
                for line in text.split(separator: "\n").reversed() {
                    guard line.contains("\"rate_limits\"") ,
                          let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                          let dict = obj as? [String: Any],
                          let payload = dict["payload"] as? [String: Any],
                          payload["rate_limits"] is [String: Any] else { continue }
                    var when = f.date
                    if let ts = dict["timestamp"] as? String,
                       let d = ISO8601DateFormatter.withFractional.date(from: ts) { when = d }
                    return (payload, when)
                }
            }
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
