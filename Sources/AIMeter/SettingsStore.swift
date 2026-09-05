import Foundation
import SwiftUI

enum AuthMode: String, CaseIterable, Identifiable {
    case keychain, paste, file, folder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keychain: return L.t("w.auth.keychain")
        case .paste:    return L.t("w.auth.paste")
        case .file:     return L.t("w.auth.file")
        case .folder:   return L.t("w.auth.folder")
        }
    }
}

struct ProviderKind: Identifiable {
    let id: String
    let title: String
    let modes: [AuthMode]
    let folderMarker: String?
    let needsURL: Bool
    let defaultKeychainService: String?
    var keyPage: String? = nil

    static var all: [ProviderKind] {
        [
            .init(id: "claude", title: L.t("p.claude"), modes: [.keychain, .file],
                  folderMarker: nil, needsURL: false,
                  defaultKeychainService: "Claude Code-credentials"),
            .init(id: "codex", title: L.t("p.codex"), modes: [.folder],
                  folderMarker: ".codex", needsURL: false, defaultKeychainService: nil),
            .init(id: "agy", title: L.t("p.agy"), modes: [.folder],
                  folderMarker: ".gemini/antigravity-cli", needsURL: false, defaultKeychainService: nil),
            .init(id: "openrouter", title: L.t("p.openrouter"), modes: [.paste, .file],
                  folderMarker: nil, needsURL: false, defaultKeychainService: nil,
                  keyPage: "openrouter.ai/keys"),
            .init(id: "deepseek", title: L.t("p.deepseek"), modes: [.paste, .file],
                  folderMarker: nil, needsURL: false, defaultKeychainService: nil,
                  keyPage: "platform.deepseek.com/api_keys"),
            .init(id: "generic", title: L.t("p.generic"), modes: [.paste],
                  folderMarker: nil, needsURL: true, defaultKeychainService: nil)
        ]
    }

    static func find(_ id: String) -> ProviderKind? { all.first { $0.id == id } }
}

@MainActor
final class SettingsStore: ObservableObject {
    static let changed = Notification.Name("AIMeterConfigChanged")
    static let restyled = Notification.Name("AIMeterRestyled")

    let configStore: ConfigStore
    @Published var results: [String: String] = [:]
    @Published var busy: Set<String> = []
    @Published var saveNotice: String?

    var cfg: Config { configStore.cfg }

    init(config: Config? = nil, store: ConfigStore? = nil) {
        if let store {
            configStore = store
        } else if let config {
            configStore = ConfigStore(initial: config)
        } else {
            configStore = ConfigStore.shared
        }
    }

    static func key(_ provider: String, _ name: String) -> String {
        provider + "\u{1}" + name
    }

    func accounts(_ provider: String) -> [AccountSpec] { cfg.accounts[provider] ?? [] }

    @discardableResult
    func persist(cosmetic: Bool = false) -> Bool {
        let snapshot = cfg
        do {
            if cosmetic {
                try configStore.mutateCosmetic { $0 = snapshot }
            } else {
                try configStore.mutate { $0 = snapshot }
            }
            saveNotice = configStore.rangeNotice ?? nil
            return true
        } catch {
            saveNotice = L.t("s.save.failed", saveFailureReason(error))
            return false
        }
    }

    /// Field-level mutation through the shared store.
    @discardableResult
    func mutate(cosmetic: Bool = false, _ change: (inout Config) -> Void) -> Bool {
        do {
            if cosmetic {
                try configStore.mutateCosmetic(change)
            } else {
                try configStore.mutate(change)
            }
            saveNotice = configStore.rangeNotice ?? nil
            return true
        } catch {
            saveNotice = L.t("s.save.failed", saveFailureReason(error))
            return false
        }
    }

    /// SwiftUI binding into a `Config` field via the shared store.
    func configBinding<Value>(_ keyPath: WritableKeyPath<Config, Value>,
                              cosmetic: Bool = false) -> Binding<Value> {
        Binding(
            get: { self.cfg[keyPath: keyPath] },
            set: { newValue in self.mutate(cosmetic: cosmetic) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func enabledBinding(_ providerID: String) -> Binding<Bool> {
        Binding(
            get: { self.cfg.isEnabled(providerID) },
            set: { on in self.mutate { $0.enabled[providerID] = on } }
        )
    }

    func intervalBinding(_ providerID: String) -> Binding<Int> {
        Binding(
            get: { self.cfg.interval(providerID) },
            set: { secs in self.mutate { $0.intervals[providerID] = secs } }
        )
    }

    private func saveFailureReason(_ error: Error) -> String {
        if case PrivateWriteError.failed(let path) = error { return path }
        return error.localizedDescription
    }

    func setEnabled(_ provider: String, _ index: Int, _ on: Bool) {
        mutate {
            guard $0.accounts[provider]?.indices.contains(index) == true else { return }
            $0.accounts[provider]?[index].enabled = on
        }
    }

    func remove(_ provider: String, _ index: Int) {
        mutate {
            guard var list = $0.accounts[provider], list.indices.contains(index) else { return }
            let spec = list[index]
            if let svc = spec.keychainService, svc.hasPrefix("AIMeter · ") {
                Credential.delete(service: svc)
            }
            list.remove(at: index)
            $0.accounts[provider] = list
        }
    }

    func removeRecipe(_ id: String) {
        mutate {
            for spec in $0.accounts[id] ?? [] {
                if let service = spec.keychainService, service.hasPrefix("AIMeter · ") {
                    Credential.delete(service: service)
                }
            }
            RecipePin.delete(id)
            $0.accounts[id] = nil
            $0.recipes.removeAll { $0.id == id }
            $0.enabled[id] = nil; $0.intervals[id] = nil
        }
    }

    func addRecipe(_ recipe: Recipe, account: AccountSpec) {
        mutate {
            $0.recipes.append(recipe)
            $0.accounts[recipe.id] = [account]
            $0.enabled[recipe.id] = true
            $0.intervals[recipe.id] = recipe.interval
        }
    }

    func convertLegacy(_ index: Int) -> Bool {
        guard var old = cfg.accounts["generic"], old.indices.contains(index) else { return false }
        let account = old[index]
        guard let base = Credential.approvedBase(account) else { return false }
        let baseID = account.name.lowercased().replacingOccurrences(
            of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var id = Recipe.validID(baseID) && !Recipe.reservedIDs.contains(baseID) ? baseID : "recipe"
        var n = 2
        while cfg.recipes.contains(where: { $0.id == id }) || Recipe.reservedIDs.contains(id) {
            id = "\(baseID.isEmpty ? "recipe" : baseID)-\(n)"; n += 1
        }
        var recipe = Recipe.legacy(account)
        recipe.id = id; recipe.name = account.name; recipe.legacy = false; recipe.fetch.baseURL = base
        guard RecipePin.write(recipe) else { return false }
        old.remove(at: index)
        let ok = mutate {
            $0.accounts["generic"] = old
            $0.recipes.append(recipe); $0.accounts[id] = [account]
        }
        return ok
    }

    func rename(_ provider: String, _ index: Int, to newName: String) {
        mutate {
            guard var list = $0.accounts[provider], list.indices.contains(index) else { return }
            let trimmed = newName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != list[index].name,
                  !exists(provider, trimmed) else { return }
            if let old = list[index].keychainService, old.hasPrefix("AIMeter · ") {
                let secret = try? Credential.read(list[index]).get()
                let new = Credential.service(provider: provider, account: trimmed)
                if let secret { Credential.store(secret, service: new) }
                Credential.delete(service: old)
                list[index].keychainService = new
            }
            list[index].name = trimmed
            $0.accounts[provider] = list
        }
    }

    func add(_ provider: String, _ spec: AccountSpec) {
        mutate { $0.accounts[provider, default: []].append(spec) }
    }

    func exists(_ provider: String, _ name: String) -> Bool {
        accounts(provider).contains { $0.name == name }
    }

    static func source(_ account: AccountSpec) -> String {
        [account.keychainService, account.keyFile, account.keyJSONField,
         account.home, account.baseURL]
            .map { $0 ?? "" }.joined(separator: "\u{1}")
    }

    func hasSource(_ provider: String, _ spec: AccountSpec) -> Bool {
        accounts(provider).contains { Self.source($0) == Self.source(spec) }
    }

    func uniqueName(_ provider: String, _ wanted: String) -> String {
        guard exists(provider, wanted) else { return wanted }
        var n = 2
        while exists(provider, "\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    func test(_ provider: String, _ spec: AccountSpec) {
        let k = Self.key(provider, spec.name)
        busy.insert(k)
        results[k] = nil
        let recipes = cfg.recipes
        Task { @MainActor in
            let reading = await Self.probe(provider: provider, spec: spec, recipes: recipes)
            busy.remove(k)
            results[k] = Self.summarise(reading)
        }
    }

    // Recipes must ride along: a recipe-backed provider only exists when
    // `cfg.recipes` names it, so probing with a bare Config() finds nothing.
    nonisolated static func probe(provider: String, spec: AccountSpec,
                                  recipes: [Recipe] = []) async -> Reading? {
        var one = Config()
        one.accounts = [provider: [spec]]
        one.recipes = recipes
        return await buildProviders(one).first { $0.id == provider }?.fetchAll(manual: true).first
    }

    nonisolated static func summarise(_ reading: Reading?) -> String {
        guard let reading else { return "✗ —" }
        var parts = reading.gauges.map { gauge in
            gauge.percent.map { String(format: "%@ %.0f%%", gauge.label, $0) }
                ?? "\(gauge.label) \(gauge.text)"
        }
        if parts.isEmpty { parts = reading.lines }
        let mark = reading.state == .failure ? "✗" : (reading.state == .off ? "—" : "✓")
        return ([mark] + parts).joined(separator: " ")
    }
}
