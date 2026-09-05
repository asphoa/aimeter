import Foundation

/// DeepSeek official API balance, one row per key. This is the channel OpenCode
/// runs on, so the number is real money rather than a subscription percentage.
/// Also flags peak-hour pricing, since starting a batch in the peak window
/// costs materially more.
final class DeepSeekProvider: Provider, @unchecked Sendable {
    let id = "deepseek"
    var title: String { L.t("p.deepseek") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.deepseek())
        guard !accounts.isEmpty else { return [.off(id, title, nil, L.t("d.nokey"))] }
        var out: [Reading] = []
        for a in accounts { out.append(await fetch(a)) }
        return out
    }

    private func fetch(_ account: AccountSpec) async -> Reading {
        guard case .success(let key) = Credential.read(account) else {
            return .off(id, title, account.name, L.t("d.unread", Credential.describe(account)))
        }
        guard let req = Net.get("https://api.deepseek.com/user/balance", bearer: key, timeout: 15) else {
            return .failed(id, title, account.name, L.t("e.connplain"))
        }

        let obj: Any, http: HTTPURLResponse
        do { (obj, http) = try await Net.json(req) }
        catch Net.JSONError.tooLarge {
            return Reading(id: id, title: title, account: account.name,
                           lines: [L.t("n.toolarge")], state: .warn)
        }
        catch {
            return .failed(id, title, account.name, L.t("e.connplain"))
        }

        guard http.statusCode == 200, let d = obj as? [String: Any] else {
            return .failed(id, title, account.name, L.t("e.http", "\(http.statusCode)"))
        }

        var r = Reading(id: id, title: title, account: account.name)
        let infos = (d["balance_infos"] as? [[String: Any]]) ?? []
        for info in infos {
            let cur = (info["currency"] as? String) ?? "?"
            switch Parse.number(info["total_balance"]) {
            case .value(let total):
                if abs(total) < 0.05 && infos.count > 1 { continue }
                r.gauges.append(Gauge(label: L.t("g.balance", cur), percent: nil,
                                      text: Fmt.money(total, cur), resetsAt: nil))
            case .missing:
                r.state = max(r.state, .warn)
                r.lines.append(L.t("p.missing"))
            case .invalid:
                r.state = max(r.state, .warn)
                r.lines.append(L.t("p.invalid"))
            }
        }
        if infos.isEmpty || r.gauges.isEmpty {
            r.state = max(r.state, .warn)
            if r.lines.isEmpty { r.lines.append(L.t("p.missing")) }
        }
        if (d["is_available"] as? Bool) == false {
            r.lines.append(L.t("d.unavailable"))
            r.state = .failure
        }
        r.lines.append(L.t("d.localrule"))
        r.lines.append(peakHourNote())
        return r
    }

    /// Peak window from config (`deepseek.peakHours`), defaulting to the
    /// Mon–Fri 09:00–12:00 and 14:00–18:00 China-time schedule this card
    /// has always shown.
    func peakHourNote() -> String {
        let ph = cfg.deepseek.peakHours
        var cal = Calendar(identifier: .gregorian)
        guard let tz = TimeZone(identifier: ph.timezone) else { return L.t("d.offpeak", "?") }
        cal.timeZone = tz
        let now = Date()
        let weekday = cal.component(.weekday, from: now)
        let hour = cal.component(.hour, from: now)
        let inPeak = ph.weekdays.contains(weekday) &&
            ph.ranges.contains { range in
                guard range.count >= 2 else { return false }
                return hour >= range[0] && hour < range[1]
            }
        let cn = String(format: "%02d:%02d", hour, cal.component(.minute, from: now))
        return inPeak ? L.t("d.peak", cn) : L.t("d.offpeak", cn)
    }
}
