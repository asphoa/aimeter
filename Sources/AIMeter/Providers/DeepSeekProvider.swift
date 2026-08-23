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

    func fetchAll() async -> [Reading] {
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
        guard let (obj, http) = try? await Net.json(
                Net.get("https://api.deepseek.com/user/balance", bearer: key, timeout: 15)) else {
            return .failed(id, title, account.name, L.t("e.connplain"))
        }
        guard http.statusCode == 200, let d = obj as? [String: Any] else {
            return .failed(id, title, account.name, L.t("e.http", "\(http.statusCode)"))
        }

        var r = Reading(id: id, title: title, account: account.name)
        let infos = (d["balance_infos"] as? [[String: Any]]) ?? []
        for info in infos {
            let cur = (info["currency"] as? String) ?? "?"
            let total = Double((info["total_balance"] as? String) ?? "0") ?? 0
            // Skip rounding-error rows in a currency that is not actually funded.
            if abs(total) < 0.05 && infos.count > 1 { continue }
            r.gauges.append(Gauge(label: L.t("g.balance", cur), percent: nil,
                                  text: Fmt.money(total, cur), resetsAt: nil))
        }
        if (d["is_available"] as? Bool) == false {
            r.lines.append(L.t("d.unavailable"))
            r.state = .error
        }
        r.lines.append(Self.peakHourNote())
        return r
    }

    /// Peak window: Mon-Fri 09:00-12:00 and 14:00-18:00 China time.
    static func peakHourNote() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date()
        let weekday = cal.component(.weekday, from: now)      // 1 = Sunday
        let hour = cal.component(.hour, from: now)
        let inPeak = (2...6).contains(weekday) && ((9..<12).contains(hour) || (14..<18).contains(hour))
        let cn = String(format: "%02d:%02d", hour, cal.component(.minute, from: now))
        return inPeak ? L.t("d.peak", cn) : L.t("d.offpeak", cn)
    }
}
