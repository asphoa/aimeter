import Foundation

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

    @Published var cfg: Config
    @Published var results: [String: String] = [:]
    @Published var busy: Set<String> = []

    init(config: Config? = nil) { cfg = config ?? Config.load() }

    static func key(_ provider: String, _ name: String) -> String {
        provider + "\u{1}" + name
    }

    func accounts(_ provider: String) -> [AccountSpec] { cfg.accounts[provider] ?? [] }

    func persist(cosmetic: Bool = false) {
        cfg.save()
        if cosmetic { Palette.overrides = cfg.colours }
        NotificationCenter.default.post(name: cosmetic ? Self.restyled : Self.changed, object: nil)
    }

    func setEnabled(_ provider: String, _ index: Int, _ on: Bool) {
        guard cfg.accounts[provider]?.indices.contains(index) == true else { return }
        cfg.accounts[provider]?[index].enabled = on
        persist()
    }

    func remove(_ provider: String, _ index: Int) {
        guard var list = cfg.accounts[provider], list.indices.contains(index) else { return }
        let spec = list[index]
        if let svc = spec.keychainService, svc.hasPrefix("AIMeter · ") {
            Credential.delete(service: svc)
        }
        list.remove(at: index)
        cfg.accounts[provider] = list
        persist()
    }

    func rename(_ provider: String, _ index: Int, to newName: String) {
        guard var list = cfg.accounts[provider], list.indices.contains(index) else { return }
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
        cfg.accounts[provider] = list
        persist()
    }

    func add(_ provider: String, _ spec: AccountSpec) {
        cfg.accounts[provider, default: []].append(spec)
        persist()
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
        Task { @MainActor in
            let reading = await Self.probe(provider: provider, spec: spec)
            busy.remove(k)
            results[k] = Self.summarise(reading)
        }
    }

    nonisolated static func probe(provider: String, spec: AccountSpec) async -> Reading? {
        var one = Config()
        one.accounts = [provider: [spec]]
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
