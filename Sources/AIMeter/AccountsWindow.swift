import AppKit
import SwiftUI

// MARK: - what each service needs to sign in

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
    /// For folder-based services: the thing that must be inside the chosen
    /// folder, both as a hint to the user and as a sanity check.
    let folderMarker: String?
    let needsURL: Bool
    let defaultKeychainService: String?
    /// Where a newcomer actually gets a key. Shown as a caption in paste mode;
    /// not knowing this is the commonest place to get stuck.
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
            .init(id: "generic", title: L.t("p.generic"), modes: [.paste, .file],
                  folderMarker: nil, needsURL: true, defaultKeychainService: nil)
        ]
    }

    static func find(_ id: String) -> ProviderKind? { all.first { $0.id == id } }
}

// MARK: - state

@MainActor
final class AccountsStore: ObservableObject {
    static let changed = Notification.Name("AIMeterConfigChanged")

    @Published var cfg: Config
    @Published var results: [String: String] = [:]
    @Published var busy: Set<String> = []

    init() { cfg = Config.load() }

    static func key(_ provider: String, _ name: String) -> String { provider + "\u{1}" + name }

    func accounts(_ provider: String) -> [AccountSpec] { cfg.accounts[provider] ?? [] }

    func persist() {
        cfg.save()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func setEnabled(_ provider: String, _ index: Int, _ on: Bool) {
        cfg.accounts[provider]?[index].enabled = on
        persist()
    }

    func remove(_ provider: String, _ index: Int) {
        guard var list = cfg.accounts[provider], list.indices.contains(index) else { return }
        let spec = list[index]
        // Only our own keychain items are ours to delete; another app's item
        // (Claude Code's, say) must be left alone.
        if let svc = spec.keychainService, svc.hasPrefix("AIMeter · ") { Credential.delete(service: svc) }
        list.remove(at: index)
        cfg.accounts[provider] = list
        persist()
    }

    /// Renaming has to carry our own keychain item across, since its service
    /// name embeds the account name.
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

    /// Where an account's credential comes from. Two entries with the same
    /// signature are the same account however they happen to be named -
    /// matching on the name alone let a re-detect silently duplicate every row
    /// as soon as anything had been renamed.
    static func source(_ a: AccountSpec) -> String {
        [a.keychainService, a.keyFile, a.keyJSONField, a.home, a.baseURL]
            .map { $0 ?? "" }.joined(separator: "\u{1}")
    }

    func hasSource(_ provider: String, _ spec: AccountSpec) -> Bool {
        accounts(provider).contains { Self.source($0) == Self.source(spec) }
    }

    /// Keeps names unique inside a provider without rejecting a genuinely new
    /// account that happens to collide.
    func uniqueName(_ provider: String, _ wanted: String) -> String {
        guard exists(provider, wanted) else { return wanted }
        var n = 2
        while exists(provider, "\(wanted) \(n)") { n += 1 }
        return "\(wanted) \(n)"
    }

    /// Runs one account through its real provider and reports what came back.
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
        return await buildProviders(one).first { $0.id == provider }?.fetchAll().first
    }

    nonisolated static func summarise(_ r: Reading?) -> String {
        guard let r else { return "✗ —" }
        var parts = r.gauges.map { g in
            g.percent.map { String(format: "%@ %.0f%%", g.label, $0) } ?? "\(g.label) \(g.text)"
        }
        if parts.isEmpty { parts = r.lines }
        // A working account and a broken one otherwise look the same: both are
        // just a sentence in the same colour.
        let mark = r.state == .error ? "✗" : (r.state == .off ? "—" : "✓")
        return ([mark] + parts).joined(separator: " ")
    }
}

// MARK: - list

struct AccountsView: View {
    @ObservedObject var store: AccountsStore
    @State private var adding = false
    @State private var toast = ""

    private var isEmpty: Bool { ProviderKind.all.allSatisfy { store.accounts($0.id).isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("w.title")).font(.title2.weight(.semibold))
            Text(L.t("w.intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isEmpty {
                VStack {
                    Spacer()
                    Text(L.t("w.none"))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(ProviderKind.all) { kind in
                            let list = store.accounts(kind.id)
                            if !list.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(kind.title).font(.headline)
                                    ForEach(Array(list.enumerated()), id: \.offset) { idx, spec in
                                        row(kind, idx, spec)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }

            Divider()
            sourcesShown

            Divider()
            MenuBarSection(store: store)

            HStack(spacing: 10) {
                Button(L.t("w.add")) { adding = true }
                Button(L.t("w.detect")) { detect() }
                Text(toast).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L.t("w.close")) { AccountsWindowController.shared.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 700)
        .sheet(isPresented: $adding) { AddAccountView(store: store) }
    }

    /// Which services the dropdown panel lists at all. Local AI has no account
    /// of its own, so without this it was the one source that could only be
    /// switched off by hand-editing the settings file.
    private var sourcesShown: some View {
        let all = ProviderKind.all.map { ($0.id, $0.title) } + [("local", L.t("p.local"))]
        return VStack(alignment: .leading, spacing: 6) {
            Text(L.t("w.sources")).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                     count: 4), alignment: .leading, spacing: 4) {
                ForEach(all, id: \.0) { id, title in
                    Toggle(title, isOn: Binding(
                        get: { store.cfg.isEnabled(id) },
                        set: { store.cfg.enabled[id] = $0; store.persist() }))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ kind: ProviderKind, _ idx: Int, _ spec: AccountSpec) -> some View {
        let k = AccountsStore.key(kind.id, spec.name)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { spec.enabled },
                                     set: { store.setEnabled(kind.id, idx, $0) })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(L.t("w.enabled"))

                NameField(initial: spec.name) { store.rename(kind.id, idx, to: $0) }

                Text(Credential.describe(spec))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

                Spacer(minLength: 8)

                if store.busy.contains(k) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L.t("w.test")) { store.test(kind.id, spec) }
                }
                Button(L.t("w.remove")) { confirmRemove(kind, idx, spec) }
            }
            if let result = store.results[k] {
                Text(result).font(.callout)
                    .foregroundStyle(result.hasPrefix("✗") ? Color.red : .primary)
                    .padding(.leading, 22).textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    /// Removing can destroy a key the user pasted and may hold nowhere else,
    /// and the button sits next to Test - so it asks first, and says plainly
    /// which of the two cases this is.
    private func confirmRemove(_ kind: ProviderKind, _ idx: Int, _ spec: AccountSpec) {
        let ownsKey = spec.keychainService?.hasPrefix("AIMeter · ") ?? false
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.t("w.remove.confirm", spec.name)
        alert.informativeText = ownsKey ? L.t("w.remove.key") : L.t("w.remove.plain")
        alert.addButton(withTitle: L.t("w.remove"))
        alert.addButton(withTitle: L.t("w.cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.remove(kind.id, idx) }
    }

    /// Re-runs discovery and adds anything not already listed.
    private func detect() {
        var added = 0
        for (provider, found) in Discovery.all() {
            for var spec in found where !store.hasSource(provider, spec) {
                spec.name = store.uniqueName(provider, spec.name)
                store.add(provider, spec)
                // Test straight away: a discovered file can hold a key that was
                // revoked months ago, and silently showing it as an account
                // would just move the confusion downstream.
                store.test(provider, spec)
                added += 1
            }
        }
        toast = added > 0 ? L.t("w.added", added) : L.t("w.nonew")
    }
}

/// Edits a name locally and reports it once, on Return or when focus leaves.
/// A plain binding would fire on every keystroke, and each keystroke costs a
/// config write, a full refetch, and - for a pasted key - a keychain rewrite.
private struct NameField: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .frame(width: 130, alignment: .leading)
            .focused($focused)
            .onAppear { text = initial }
            .onChange(of: initial) { _, new in if !focused { text = new } }
            .onSubmit { commit(text) }
            .onChange(of: focused) { _, nowFocused in if !nowFocused { commit(text) } }
    }
}

// MARK: - add sheet

struct AddAccountView: View {
    @ObservedObject var store: AccountsStore
    @Environment(\.dismiss) private var dismiss

    @State private var providerID = "openrouter"
    @State private var name = ""
    @State private var mode: AuthMode = .paste
    @State private var pasted = ""
    @State private var path = ""
    @State private var keychainService = ""
    @State private var baseURL = ""
    @State private var balancePath = ""
    @State private var problem = ""

    private var kind: ProviderKind { ProviderKind.find(providerID) ?? ProviderKind.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("w.add")).font(.title3.weight(.semibold))

            Form {
                Picker(L.t("w.service"), selection: $providerID) {
                    ForEach(ProviderKind.all) { Text($0.title).tag($0.id) }
                }
                .onChange(of: providerID) { _, _ in
                    mode = kind.modes.first ?? .paste
                    keychainService = kind.defaultKeychainService ?? ""
                    path = ""; problem = ""
                }

                TextField(L.t("w.name"), text: $name, prompt: Text(L.t("w.nameph")))

                if kind.modes.count > 1 {
                    Picker(L.t("w.howauth"), selection: $mode) {
                        ForEach(kind.modes) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                }

                switch mode {
                case .paste:
                    SecureField(L.t("w.key"), text: $pasted)
                    Text(L.t("w.keysaved")).font(.caption).foregroundStyle(.secondary)
                    if let page = kind.keyPage {
                        Text(L.t("w.getkey", page)).font(.caption).foregroundStyle(.secondary)
                    }
                case .file:
                    picker(L.t("w.keyfile"), directories: false)
                case .folder:
                    picker(L.t("w.folder"), directories: true)
                    if let marker = kind.folderMarker {
                        Text(L.t("w.folderhelp", marker)).font(.caption).foregroundStyle(.secondary)
                    }
                case .keychain:
                    TextField(L.t("w.keychainsvc"), text: $keychainService)
                    Text(L.t("w.claudehint")).font(.caption).foregroundStyle(.secondary)
                }

                if kind.needsURL {
                    TextField(L.t("w.baseurl"), text: $baseURL,
                              prompt: Text("https://api.example.com"))
                    TextField(L.t("w.balpath"), text: $balancePath,
                              prompt: Text("/v1/credits"))
                }
            }
            .formStyle(.grouped)

            if !problem.isEmpty {
                Text(problem).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button(L.t("w.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.t("w.save")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            mode = kind.modes.first ?? .paste
            keychainService = kind.defaultKeychainService ?? ""
        }
    }

    @ViewBuilder
    private func picker(_ label: String, directories: Bool) -> some View {
        HStack {
            Text(label)
            Text(path.isEmpty ? "—" : path)
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(L.t("w.choose")) { choose(directories: directories) }
        }
    }

    private func choose(directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { problem = L.t("w.needname"); return }
        guard !store.exists(providerID, trimmed) else { problem = L.t("w.dup"); return }

        var spec = AccountSpec(name: trimmed)
        switch mode {
        case .paste:
            guard !pasted.isEmpty else { problem = L.t("w.needcred"); return }
            let svc = Credential.service(provider: providerID, account: trimmed)
            guard Credential.store(pasted, service: svc) else {
                problem = L.t("k.denied"); return
            }
            spec.keychainService = svc
        case .file:
            guard !path.isEmpty else { problem = L.t("w.needcred"); return }
            spec.keyFile = path
        case .folder:
            guard !path.isEmpty else { problem = L.t("w.needcred"); return }
            if let marker = kind.folderMarker,
               !FileManager.default.fileExists(atPath: path + "/" + marker) {
                problem = L.t("w.folderhelp", marker); return
            }
            spec.home = path
        case .keychain:
            guard !keychainService.isEmpty else { problem = L.t("w.needcred"); return }
            spec.keychainService = keychainService
        }
        if kind.needsURL {
            guard !baseURL.isEmpty, !balancePath.isEmpty else { problem = L.t("w.needcred"); return }
            spec.baseURL = baseURL
            spec.balancePath = balancePath
        }

        store.add(providerID, spec)
        store.test(providerID, spec)
        dismiss()
    }
}

// MARK: - window

@MainActor
final class AccountsWindowController {
    static let shared = AccountsWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let store = AccountsStore()
        let host = NSHostingController(rootView: AccountsView(store: store))
        let w = NSWindow(contentViewController: host)
        w.title = L.t("w.title")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
