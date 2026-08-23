import Foundation

/// OpenRouter, one gauge per key. Each key is effectively its own account and
/// has its own weekly cap, so aider's spend is visible separately from the
/// OCR and cross-verification keys.
final class OpenRouterProvider: Provider, @unchecked Sendable {
    let id = "openrouter"
    var title: String { L.t("p.openrouter") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.openrouter())
        guard !accounts.isEmpty else { return [.off(id, title, nil, L.t("o.nokeys"))] }

        var r = Reading(id: id, title: title)
        var failures: [String] = []

        for a in accounts {
            guard case .success(let key) = Credential.read(a) else {
                failures.append(a.name); continue
            }
            guard let req = Net.get("https://openrouter.ai/api/v1/key", bearer: key, timeout: 15),
                  let (obj, http) = try? await Net.json(req),
                  http.statusCode == 200,
                  let data = (obj as? [String: Any])?["data"] as? [String: Any] else {
                failures.append(a.name); continue
            }

            let usageWeekly = findNumber(in: data, names: ["usage_weekly"]) ?? 0
            let usageTotal = findNumber(in: data, names: ["usage"]) ?? 0
            if let limit = findNumber(in: data, names: ["limit"]), limit > 0 {
                let remaining = findNumber(in: data, names: ["limit_remaining"]) ?? (limit - usageWeekly)
                let pct = max(0, min(100, (limit - remaining) / limit * 100))
                r.gauges.append(Gauge(label: a.name, percent: pct,
                                      text: L.t("o.left", Fmt.money(remaining, "USD"), Fmt.money(limit, "USD")),
                                      resetsAt: nil,
                                      kind: (data["limit_reset"] as? String) == "weekly" ? .longWindow : .other))
            } else {
                r.gauges.append(Gauge(label: a.name, percent: nil,
                                      text: L.t("o.nocap", Fmt.money(usageWeekly, "USD"), Fmt.money(usageTotal, "USD")),
                                      resetsAt: nil))
            }
        }

        if !failures.isEmpty {
            r.lines.append(L.t("o.unread", failures.joined(separator: ", ")))
            r.state = .warn
        }
        if r.gauges.isEmpty && failures.isEmpty { return [.off(id, title, nil, L.t("o.nokeys"))] }
        r.state = max(r.state, worstState(r.gauges))
        return [r]
    }
}
