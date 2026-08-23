import Foundation

/// Any vendor with a plain "GET this URL with a bearer token, get a balance
/// back" endpoint. Add entries under `accounts.generic` in config.json and they
/// appear without recompiling - that is the escape hatch for vendors added later.
///
/// The credential must be one pasted into the Accounts window, which lives in
/// the keychain. It may NOT be an arbitrary file path: this provider sends the
/// credential to a host named in the settings file, so an arbitrary path plus an
/// arbitrary host is a "read that file, post it to my server" gadget for anyone
/// who can edit that plain-text file - including anyone who hands the user a
/// "fixed" config. The host must also be https.
///
/// Example entry (key added by pasting, so it is referenced by keychain service):
///   { "name": "Typhoon", "keychainService": "AIMeter · generic · Typhoon",
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
        guard base.lowercased().hasPrefix("https://") else {
            return .failed(id, a.name, nil, L.t("e.httpsonly"))
        }
        // Only our own keychain items: see the note above.
        guard let svc = a.keychainService, svc.hasPrefix("AIMeter · ") else {
            return .failed(id, a.name, nil, L.t("e.pasteonly"))
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
