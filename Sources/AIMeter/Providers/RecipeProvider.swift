import Foundation

final class RecipeProvider: Provider, @unchecked Sendable {
    let id: String
    var title: String { recipe?.name ?? L.t("p.generic") }
    private let recipe: Recipe?
    private let legacyAccounts: [AccountSpec]
    private let cfg: Config

    init(recipe: Recipe, cfg: Config) {
        self.recipe = recipe; self.legacyAccounts = []; self.cfg = cfg; self.id = recipe.id
    }

    init(legacyAccounts: [AccountSpec], cfg: Config) {
        self.recipe = nil; self.legacyAccounts = legacyAccounts; self.cfg = cfg; self.id = "generic"
    }

    func fetchAll(manual: Bool) async -> [Reading] {
        guard manual || cfg.interval(id) > 0 else { return [] }
        if let recipe {
            let accounts = cfg.accounts(recipe.id, fallback: [])
            if accounts.isEmpty, recipe.fetch.method == "none" {
                return [await fetch(recipe, AccountSpec(name: recipe.name), pin: RecipePin.Pin())]
            }
            var readings: [Reading] = []
            for account in accounts { readings.append(await fetch(recipe, account, pin: nil)) }
            return readings
        }

        var readings: [Reading] = []
        for account in legacyAccounts where account.enabled {
            var implicit = Recipe.legacy(account)
            guard let base = Credential.approvedBase(account),
                  let approved = RecipeURL.approvedDestination(from: base) else {
                readings.append(.failed(id, account.name, nil, L.t("e.reapprove")))
                continue
            }
            implicit.fetch.baseURL = approved.comps.string
            let pin = RecipePin.Pin(host: approved.comps.string, binary: nil, argsHash: nil,
                                    authName: nil, folder: nil)
            readings.append(await fetch(implicit, account, pin: pin))
        }
        return readings
    }

    private func fetch(_ recipe: Recipe, _ account: AccountSpec,
                       pin: RecipePin.Pin?) async -> Reading {
        switch await RecipeFetch.run(recipe, account: account, pin: pin) {
        case .failure(let fail):
            return .failed(recipe.id, recipe.name, account.name, fail.message)
        case .success(let output):
            var reading = RecipeMap.apply(recipe.map, to: output.data)
            reading.id = recipe.id; reading.title = recipe.name; reading.account = account.name
            if let stamp = output.meta.snapshotAt { reading.snapshotAt = stamp }
            return reading
        }
    }
}
