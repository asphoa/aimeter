import Foundation

/// Antigravity quota - one row per account HOME, so a pool of accounts shows
/// up as several rows.
///
/// agy refreshes its own quota through an internal Google endpoint
/// (v1internal:retrieveUserQuotaSummary) on every CLI start and logs the outcome.
/// We read that log rather than calling Google ourselves: repeated automated
/// calls against Google's internal endpoints - multiplied by an account pool -
/// are the traffic shape that gets accounts flagged. The direct call exists
/// behind `agyAllowDirectQuotaCall` and is off by default.
final class AgyProvider: Provider, @unchecked Sendable {
    let id = "agy"
    var title: String { L.t("p.agy") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.agy())
        if accounts.isEmpty { return [.off(id, title, nil, L.t("a.nostate"))] }
        var out: [Reading] = []
        for a in accounts {
            let dir = expand(a.home ?? "~") + "/.gemini/antigravity-cli"
            // The direct request happens only when a person asked for it. On a
            // timer it would be exactly the automated pattern that gets accounts
            // flagged; triggered by hand it is the same single call the CLI
            // itself makes every time it starts.
            if manual, cfg.agyQuotaViaTUI,
               let home = trustedHome(a.home ?? "~", marker: ".gemini/antigravity-cli"),
               let panel = await tuiQuota(home: home, account: a.name) {
                out.append(panel)
            } else if manual, cfg.agyDirectQuotaOnManualCheck,
                      let live = await directQuota(dir: dir, account: a.name) {
                out.append(live)
            } else {
                out.append(fromLog(dir: dir, account: a.name))
            }
        }
        return out
    }

    /// Drives the vendor's own client to read the one place these numbers
    /// exist. See AgyTUI for why this rather than an HTTP request.
    private func tuiQuota(home: String, account: String) async -> Reading? {
        guard let bin = AgyTUI.binary(cfg.agyBinary.isEmpty ? nil : cfg.agyBinary) else {
            return .failed(id, title, account, L.t("a.tui.nobin"))
        }
        let result: AgyTUI.Result? = await Task.detached(priority: .utility) {
            AgyTUI.read(binary: bin, home: home)
        }.value
        guard let result else {
            return .failed(id, title, account, L.t("a.tui.fail"))
        }

        var r = Reading(id: id, title: title, account: result.account ?? account)
        for group in result.groups {
            let isGemini = group.name.contains("GEMINI")
            let key = isGemini ? "g.gemini" : "g.claudegpt"
            if let used = group.fiveHourUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.5h.short")), percent: used,
                                      text: String(format: "%.0f%%", used), resetsAt: nil,
                                      kind: isGemini ? .shortWindow : .other))
            }
            if let used = group.weeklyUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.week.short")), percent: used,
                                      text: String(format: "%.0f%%", used),
                                      resetsAt: group.weeklyResets,
                                      kind: isGemini ? .longWindow : .other))
            }
        }
        guard !r.gauges.isEmpty else { return .failed(id, title, account, L.t("a.tui.fail")) }
        // Nothing refreshes this on its own, so it must carry its age: an hour
        // later it is still the last thing anyone measured, not the current one.
        r.snapshotAt = Date()
        r.state = worstState(r.gauges)
        return r
    }

    private func fromLog(dir: String, account: String) -> Reading {
        guard let path = newestLog(dir), let text = tailBytes(path, limit: 256 * 1024) else {
            return .off(id, title, account, L.t("a.nolog"))
        }
        var lastLine: String?
        for line in text.split(separator: "\n").reversed()
        where line.contains("retrieveUserQuotaSummary") || line.contains("quota_manager") {
            lastLine = String(line); break
        }
        guard let line = lastLine else { return .off(id, title, account, L.t("a.norecord")) }

        var r = Reading(id: id, title: title, account: account)
        r.snapshotAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date()

        if line.contains("PERMISSION_DENIED") || line.contains("403") {
            r.state = .error
            r.lines = [L.t("a.403"), L.t("a.403b")]
        } else if line.lowercased().contains("failed") {
            r.state = .warn
            r.lines = [L.t("a.failed")]
        } else if let pct = firstPercent(line) {
            r.gauges.append(Gauge(label: L.t("g.quota"), percent: pct,
                                  text: String(format: "%.0f%%", pct), resetsAt: nil))
            r.state = worstState(r.gauges)
        } else {
            r.lines = [L.t("a.silent"), L.t("a.silent2")]
        }
        return r
    }

    private func newestLog(_ dir: String) -> String? {
        let fm = FileManager.default
        let symlink = dir + "/cli.log"
        if fm.fileExists(atPath: symlink) { return symlink }
        let logs = dir + "/log"
        return ((try? fm.contentsOfDirectory(atPath: logs)) ?? [])
            .filter { $0.hasSuffix(".log") }.sorted(by: >).first.map { logs + "/" + $0 }
    }

    private func firstPercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3}(\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        return Double(line[r].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private func directQuota(dir: String, account: String) async -> Reading? {
        guard let raw = try? String(contentsOfFile: dir + "/antigravity-oauth-token", encoding: .utf8) else { return nil }
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = try? JSONSerialization.jsonObject(with: Data(token.utf8)),
           let t = findString(in: obj, names: ["access_token", "accessToken", "token"]) { token = t }

        var req = URLRequest(url: URL(string:
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        guard let (obj, http) = try? await Net.json(req) else { return nil }
        if http.statusCode != 200 {
            return .failed(id, title, account,
                           L.t("a.direct.fail", findString(in: obj, names: ["message"]) ?? "HTTP \(http.statusCode)"))
        }
        var r = Reading(id: id, title: title, account: account)
        if let used = findNumber(in: obj, names: ["usedPercent", "used_percent"]) {
            r.gauges.append(Gauge(label: L.t("g.quota"), percent: used,
                                  text: String(format: "%.0f%%", used), resetsAt: nil))
        } else if let remaining = findNumber(in: obj, names: ["remaining", "remainingQuota"]) {
            r.lines.append(L.t("a.remaining", "\(Int(remaining))"))
        } else {
            r.lines.append(L.t("a.unknown"))
            r.state = .warn
        }
        r.state = max(r.state, worstState(r.gauges))
        return r
    }
}
