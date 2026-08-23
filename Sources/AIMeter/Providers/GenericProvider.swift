import Foundation

/// Any vendor with a plain "GET this URL with a bearer token, get a balance
/// back" endpoint. Add entries under `accounts.generic` in config.json and they
/// appear without recompiling - that is the escape hatch for vendors added later.
///
/// Example entry:
///   { "name": "Typhoon", "keyFile": "~/.typhoon_key",
///     "baseURL": "https://api.opentyphoon.ai", "balancePath": "/v1/credits" }
final class GenericProvider: Provider, @unchecked Sendable {
    let id = "generic"
    var title: String { L.t("p.generic") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: [])
        guard !accounts.isEmpty else { return [] }
        var out: [Reading] = []
        for a in accounts { out.append(await fetch(a)) }
        return out
    }

    private func fetch(_ a: AccountSpec) async -> Reading {
        guard let base = a.baseURL, let path = a.balancePath else {
            return .off(id, a.name, nil, L.t("e.needurl"))
        }
        let key = try? Credential.read(a).get()
        guard let (obj, http) = try? await Net.json(
                Net.get(base + path, bearer: key, timeout: 15)) else {
            return .failed(id, a.name, nil, L.t("e.connplain"))
        }
        guard http.statusCode == 200 else { return .failed(id, a.name, nil, L.t("e.http", "\(http.statusCode)")) }

        var r = Reading(id: id, title: a.name)
        if let bal = findNumber(in: obj, names: ["balance", "total_balance", "credits",
                                                 "credit", "remaining", "amount"]) {
            r.gauges.append(Gauge(label: L.t("g.balance", ""), percent: nil,
                                  text: Fmt.money(bal, "USD"), resetsAt: nil))
        } else {
            r.lines.append(L.t("a.unknown"))
            r.state = .warn
        }
        return r
    }
}
