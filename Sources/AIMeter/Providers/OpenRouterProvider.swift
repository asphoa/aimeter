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

        for a in accounts {
            guard case .success(let key) = Credential.read(a) else {
                r.lines.append(L.t("o.err.key", a.name))
                r.state = .warn
                continue
            }
            guard let req = Net.get("https://openrouter.ai/api/v1/key", bearer: key, timeout: 15) else {
                r.lines.append(L.t("o.err.net", a.name, L.t("e.connplain")))
                r.state = .warn
                continue
            }

            let obj: Any, http: HTTPURLResponse
            do { (obj, http) = try await Net.json(req) }
            catch Net.JSONError.tooLarge {
                r.lines.append(L.t("n.toolarge"))
                r.state = .warn
                continue
            }
            catch {
                r.lines.append(L.t("o.err.net", a.name, error.localizedDescription))
                r.state = .warn
                continue
            }

            guard http.statusCode == 200 else {
                r.lines.append(L.t("o.err.http", a.name, "\(http.statusCode)"))
                r.state = .warn
                continue
            }
            guard let data = (obj as? [String: Any])?["data"] as? [String: Any] else {
                r.lines.append(L.t("p.invalid"))
                r.state = .warn
                continue
            }

            let usageWeekly = parseNumber(in: data, names: ["usage_weekly"])
            let usageTotal = parseNumber(in: data, names: ["usage"])
            let limitReset = data["limit_reset"] as? String

            switch parseNumber(in: data, names: ["limit"]) {
            case .value(let limit) where limit > 0:
                let kind: GaugeKind = limitReset == "weekly" ? .longWindow : .other
                switch parseNumber(in: data, names: ["limit_remaining"]) {
                case .value(let remaining):
                    let pct = max(0, min(100, (limit - remaining) / limit * 100))
                    r.gauges.append(Gauge(label: a.name, percent: pct,
                                          text: L.t("o.left", Fmt.money(remaining, "USD"), Fmt.money(limit, "USD")),
                                          resetsAt: nil, kind: kind))
                case .missing:
                    if let reset = limitReset, let usage = usageForPeriod(reset, weekly: usageWeekly) {
                        let remaining = limit - usage
                        let pct = max(0, min(100, (limit - remaining) / limit * 100))
                        r.gauges.append(Gauge(label: a.name, percent: pct,
                                              text: L.t("o.left", Fmt.money(remaining, "USD"), Fmt.money(limit, "USD")),
                                              resetsAt: nil, kind: kind))
                    } else {
                        r.gauges.append(Gauge(label: a.name, percent: nil,
                                              text: L.t("o.left", "?", Fmt.money(limit, "USD")),
                                              resetsAt: nil, kind: kind))
                        r.lines.append(L.t("o.unknown.remaining"))
                        r.state = .warn
                    }
                case .invalid:
                    r.lines.append(L.t("p.invalid"))
                    r.state = .warn
                }
            case .value:
                r.gauges.append(Gauge(label: a.name, percent: nil,
                                      text: L.t("o.nocap", moneyText(usageWeekly), moneyText(usageTotal)),
                                      resetsAt: nil))
            case .missing, .invalid:
                r.gauges.append(Gauge(label: a.name, percent: nil,
                                      text: L.t("o.nocap", moneyText(usageWeekly), moneyText(usageTotal)),
                                      resetsAt: nil))
            }
        }

        if r.gauges.isEmpty && r.lines.isEmpty { return [.off(id, title, nil, L.t("o.nokeys"))] }
        r.state = max(r.state, worstState(r.gauges))
        return [r]
    }

    private func parseNumber(in obj: Any, names: [String]) -> ParseResult<Double> {
        Parse.findNumber(in: obj, names: names)
    }

    private func usageForPeriod(_ reset: String, weekly: ParseResult<Double>) -> Double? {
        switch reset {
        case "weekly":
            switch weekly {
            case .value(let n): return n
            case .missing, .invalid: return nil
            }
        default: return nil
        }
    }

    private func moneyText(_ result: ParseResult<Double>) -> String {
        switch result {
        case .value(let value): return Fmt.money(value, "USD")
        case .missing, .invalid: return "?"
        }
    }
}
