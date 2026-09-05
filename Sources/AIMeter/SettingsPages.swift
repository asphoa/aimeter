import AppKit
import SwiftUI

struct AddDraft: Equatable {
    var providerID: String
    var name = ""
    var mode: AuthMode
    var pasted = ""
    var path = ""
    var keychainService = ""
    var baseURL = ""
    var balancePath = ""

    init(providerID: String) {
        let kind = ProviderKind.find(providerID) ?? ProviderKind.all[0]
        self.providerID = providerID
        self.mode = kind.modes.first ?? .paste
        self.keychainService = kind.defaultKeychainService ?? ""
    }
}

enum SettingsSubtitle {
    static let serviceIDs = ["claude", "codex", "agy", "openrouter", "deepseek", "local", "cursor"]

    static func services(_ cfg: Config) -> String {
        let hidden = serviceIDs.filter { !cfg.isEnabled($0) }.count
        let status = hidden == 0 ? L.t("s.allon") : L.t("s.hidden.n", hidden)
        return L.t("s.services.sub", serviceIDs.count, status)
    }

    static func menuBar(_ cfg: Config) -> String {
        let style = cfg.menuBar.style == "ringNumeral" ? L.t("mb.style.numeral") : L.t("mb.style.ring")
        return L.t("s.menubar.sub", style, PanelModelBuilder.title(for: cfg.menuBar.primary))
    }

    static func general(_ cfg: Config) -> String {
        if cfg.refreshSeconds == 0 {
            return "\(cfg.language.displayName) · \(L.t("pn.manual"))"
        }
        return L.t("s.general.sub", cfg.language.displayName, settingsIntervalLabel(cfg.refreshSeconds))
    }

    static func history(_ cfg: Config) -> String {
        cfg.history.enabled
            ? L.t("s.history.sub.on", L.t("s.months", cfg.history.retentionMonths))
            : L.t("s.history.sub.off")
    }
}

private var settingsVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

private func settingsIntervalLabel(_ seconds: Int) -> String {
    if seconds == 0 { return L.t("m.manualonly") }
    return seconds < 60 ? L.t("m.seconds", seconds) : L.t("m.minutes", seconds / 60)
}

private struct SettingsPageFrame<Content: View>: View {
    @ObservedObject var state: PanelState
    let title: String
    let back: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PanelHeader(title: title, back: back)
                Divider()
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelChromeHeightKey.self, value: geometry.size.height)
            })
            ScrollView {
                content()
                    .frame(width: 348, alignment: .leading)
                    .padding(.vertical, 10)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PanelContentHeightKey.self, value: geometry.size.height)
                    })
            }
            .id(state.nav.stack.last.map { String(describing: $0) } ?? "settings")
            .scrollDisabled(contentHeight + chromeHeight <= state.screenLimit)
            VStack(spacing: 0) {
                Divider()
                Text("v\(settingsVersion)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .padding(.vertical, 7)
            }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: PanelChromeHeightKey.self, value: geometry.size.height)
            })
        }
        .onPreferenceChange(PanelContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(PanelChromeHeightKey.self) { chromeHeight = $0 }
    }
}

private struct SettingsLinkRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22)
                    .foregroundStyle(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.42)))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
        .buttonStyle(.plain)
    }
}

struct SettingsRootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("s.title"), back: { state.nav.pop() }) {
            VStack(spacing: 8) {
                SettingsLinkRow(icon: "square.grid.2x2", title: L.t("s.services"),
                                subtitle: SettingsSubtitle.services(store.cfg)) {
                    state.nav.push(.services)
                }
                SettingsLinkRow(icon: "menubar.rectangle", title: L.t("w.menubar"),
                                subtitle: SettingsSubtitle.menuBar(store.cfg)) {
                    state.nav.push(.menuBar)
                }
                SettingsLinkRow(icon: "slider.horizontal.3", title: L.t("s.general"),
                                subtitle: SettingsSubtitle.general(store.cfg)) {
                    state.nav.push(.general)
                }
                SettingsLinkRow(icon: "clock.arrow.circlepath", title: L.t("st.history"),
                                subtitle: SettingsSubtitle.history(store.cfg)) {
                    state.nav.push(.history)
                }
                SettingsLinkRow(icon: "info.circle", title: L.t("m.about"),
                                subtitle: L.t("s.about.sub", settingsVersion)) {
                    state.onOpenAbout()
                }
                Text(L.t("s.saved.hint"))
                    .font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4).padding(.top, 6)
            }
        }
    }
}

struct ServicesView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore

    private var IDs: [String] {
        var ids = SettingsSubtitle.serviceIDs
        if !(store.cfg.accounts["generic"] ?? []).isEmpty { ids.append("generic") }
        ids.append(contentsOf: store.cfg.recipes.map(\.id).sorted())
        return ids
    }

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("s.services"), back: { state.nav.pop() }) {
            VStack(spacing: 9) {
                ForEach(store.cfg.loadWarnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                }
                if state.draft != nil {
                    HStack {
                        Text(L.t("rc.draft"))
                            .font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                        Spacer()
                        Button(L.t("s.resume")) { state.nav.push(.custom) }
                        Button(L.t("s.discard")) { state.draft = nil }
                    }.padding(8).background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
                if let draft = state.builtinDraft {
                    HStack {
                        Text(L.t("s.draft", PanelModelBuilder.title(for: draft.providerID)))
                            .font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                        Spacer()
                        Button(L.t("s.resume")) { state.nav.push(.add(kind: draft.providerID)) }
                        Button(L.t("s.discard")) { state.builtinDraft = nil }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
                ForEach(IDs, id: \.self) { id in
                    ServiceCardView(providerID: id, state: state, store: store)
                }
                HStack {
                    Spacer()
                    Button(L.t("s.add")) { state.nav.push(.catalogue) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct ServiceCardView: View {
    let providerID: String
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore
    @State private var expanded = false

    private var recipe: Recipe? { store.cfg.recipes.first { $0.id == providerID } }
    private var title: String {
        if providerID == "generic" { return L.t("rc.legacy.title") }
        return recipe?.name ?? PanelModelBuilder.title(for: providerID)
    }
    private var accounts: [AccountSpec] { store.accounts(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: recipe.flatMap { NSColor(hex: $0.colour) }
                            ?? Palette.serviceColour(providerID)))
                        .frame(width: 8, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(sourceSummary).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                            .lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                }
            }
            .buttonStyle(.plain)

            if expanded {
                Toggle(L.t("s.shown"), isOn: Binding(
                    get: { store.cfg.isEnabled(providerID) },
                    set: { store.cfg.enabled[providerID] = $0; store.persist() }))
                    .toggleStyle(.switch)

                Picker(L.t("w.checkevery"), selection: Binding(
                    get: { store.cfg.interval(providerID) },
                    set: { store.cfg.intervals[providerID] = $0; store.persist() })) {
                        ForEach([30, 60, 300, 900, 3600, 0], id: \.self) {
                            Text(settingsIntervalLabel($0)).tag($0)
                        }
                    }

                ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                    AccountSettingsRow(providerID: providerID, index: index, account: account,
                                       store: store)
                    if providerID == "generic" {
                        Button(L.t("rc.convert")) { _ = store.convertLegacy(index) }
                            .font(.system(size: 10))
                    }
                }

                if let kind = ProviderKind.find(providerID), providerID != "claude" {
                    Button(accounts.isEmpty ? L.t("s.add") : L.t("s.addaccount")) {
                        state.builtinDraft = AddDraft(providerID: kind.id)
                        state.nav.push(.add(kind: kind.id))
                    }
                }
                if recipe != nil {
                    Button(L.t("rc.remove.recipe"), role: .destructive) {
                        store.removeRecipe(providerID)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(nsColor: .separatorColor)))
    }

    private var sourceSummary: String {
        if providerID == "generic" { return L.t("rc.legacy.source") }
        if let recipe {
            return L.t("rc.source.\(recipe.credential.source)")
        }
        if providerID == "codex" { return L.t("s.src.codex") }
        if providerID == "agy" { return L.t("s.src.agy", L.t("s.hourly")) }
        if providerID == "local" { return L.t("s.src.local") }
        if providerID == "cursor" { return L.t("s.src.cursor") }
        if accounts.isEmpty { return L.t("w.none") }
        if accounts.count > 1 { return L.t("s.src.keys", accounts.count) }
        return credentialSource(providerID, accounts[0])
    }
}

private struct AccountSettingsRow: View {
    let providerID: String
    let index: Int
    let account: AccountSpec
    @ObservedObject var store: SettingsStore
    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Toggle("", isOn: Binding(get: { account.enabled },
                                          set: { store.setEnabled(providerID, index, $0) }))
                    .labelsHidden().toggleStyle(.checkbox)
                Text(account.name).font(.system(size: 11, weight: .medium))
                Spacer()
                if !confirmingRemove {
                    let key = SettingsStore.key(providerID, account.name)
                    if store.busy.contains(key) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L.t("w.test")) { store.test(providerID, account) }
                    }
                    Button(L.t("w.remove")) { confirmingRemove = true }
                }
            }
            Text(credentialSource(providerID, account))
                .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            if confirmingRemove {
                Text(L.t("s.remove.q")).font(.system(size: 10, weight: .semibold))
                Text(L.t("s.remove.hint"))
                    .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L.t("s.keep")) { confirmingRemove = false }
                    Button(L.t("w.remove"), role: .destructive) {
                        store.remove(providerID, index)
                        confirmingRemove = false
                    }
                }
            }
            if let result = store.results[SettingsStore.key(providerID, account.name)] {
                Text(result).font(.system(size: 10))
                    .foregroundStyle(result.hasPrefix("✗")
                        ? Color(nsColor: Palette.colour(Palette.alarm)) : .primary)
            }
        }
        .padding(.top, 4)
    }

}

private func credentialSource(_ providerID: String, _ account: AccountSpec) -> String {
    if providerID == "claude", account.keychainService != nil { return L.t("s.src.claude") }
    if providerID == "codex" { return L.t("s.src.codex") }
    if providerID == "agy" { return L.t("s.src.agy", L.t("s.hourly")) }
    if let file = account.keyFile {
        if file.hasPrefix("env:") { return L.t("s.src.env", "$" + String(file.dropFirst(4))) }
        return L.t("s.src.keyfile", (file as NSString).lastPathComponent)
    }
    if account.keychainService != nil { return L.t("w.keysaved") }
    return L.t("s.saved")
}

struct CatalogueView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore

    private var kinds: [ProviderKind] { ProviderKind.all.filter { $0.id != "generic" } }

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("s.add.title"), back: { state.nav.pop() }) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L.t("s.builtin")).font(.system(size: 11, weight: .semibold))
                ForEach(kinds) { kind in
                    catalogueRow(kind)
                }
                simpleCatalogueRow("local", source: L.t("s.src.local"))
                simpleCatalogueRow("cursor", source: L.t("s.src.cursor"))
                Divider().padding(.vertical, 3)
                Text(L.t("rc.templates")).font(.system(size: 11, weight: .semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    templateCard(L.t("rc.template.http"), icon: "network", method: "http")
                    templateCard(L.t("rc.template.cli"), icon: "terminal", method: "cli")
                    templateCard(L.t("rc.template.file"), icon: "doc.text", method: "file")
                    templateCard(L.t("rc.template.custom"), icon: "slider.horizontal.3", method: "http")
                }
            }
        }
    }

    private func catalogueRow(_ kind: ProviderKind) -> some View {
        let count = store.accounts(kind.id).count
        let oneOnly = kind.id == "claude"
        return HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: Palette.serviceColour(kind.id))).frame(width: 8, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
                Text(count > 0 ? (oneOnly ? L.t("s.oneonly") : L.t("s.added")) : sourceHint(kind.id))
                    .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
            Spacer()
            if count == 0 || !oneOnly {
                Button(count == 0 ? L.t("s.add") : L.t("s.addanother")) {
                    state.builtinDraft = AddDraft(providerID: kind.id)
                    state.nav.push(.add(kind: kind.id))
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func sourceHint(_ id: String) -> String {
        switch id {
        case "claude": return L.t("s.src.claude")
        case "codex": return L.t("s.src.codex")
        case "agy": return L.t("s.src.agy", L.t("s.hourly"))
        default: return L.t("w.keysaved")
        }
    }

    private func simpleCatalogueRow(_ id: String, source: String) -> some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: Palette.serviceColour(id))).frame(width: 8, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(PanelModelBuilder.title(for: id)).font(.system(size: 12, weight: .medium))
                Text(source).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
            Spacer()
            if store.cfg.isEnabled(id) {
                Text(L.t("s.added")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            } else {
                Button(L.t("s.add")) {
                    store.cfg.enabled[id] = true
                    store.persist()
                }
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func templateCard(_ title: String, icon: String, method: String) -> some View {
        Button {
            var draft = RecipeDraft(); draft.method = method
            if method == "cli" { draft.credentialSource = "none"; draft.gaugePath = "$.usage" }
            if method == "file" { draft.credentialSource = "none"; draft.gaugePath = "$.rate_limits" }
            state.draft = draft; state.nav.push(.custom)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 10, weight: .medium))
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlBackgroundColor)))
        }.buttonStyle(.plain)
    }
}

struct CustomRecipeView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore
    @State private var problem = ""
    @State private var testing = false
    @State private var approvalBaseline: RecipeDraft?

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("rc.custom.title"), back: { state.nav.pop() }) {
            if let draft = binding {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        Text(L.t("rc.identity")).font(.system(size: 11, weight: .semibold))
                        TextField(L.t("rc.id"), text: draft.id, prompt: Text("typhoon"))
                        TextField(L.t("w.name"), text: draft.name, prompt: Text("Typhoon"))
                        HStack {
                            TextField(L.t("rc.colour"), text: draft.colour)
                            TextField(L.t("rc.symbol"), text: draft.symbol)
                        }
                    }
                    Divider()
                    Group {
                        Text(L.t("rc.credential")).font(.system(size: 11, weight: .semibold))
                        Picker(L.t("rc.credential"), selection: draft.credentialSource) {
                            Text(L.t("rc.source.keychain")).tag("keychain")
                            Text(L.t("rc.source.keyFile")).tag("keyFile")
                            Text(L.t("rc.source.env")).tag("env")
                            Text(L.t("rc.source.appKeychain")).tag("appKeychain")
                            Text(L.t("rc.source.none")).tag("none")
                        }
                        credentialFields(draft)
                    }
                    Divider()
                    Group {
                        Text(L.t("rc.fetch")).font(.system(size: 11, weight: .semibold))
                        Picker(L.t("rc.method"), selection: draft.method) {
                            Text("HTTP").tag("http"); Text(L.t("rc.command")).tag("cli")
                            Text(L.t("rc.file")).tag("file"); Text(L.t("rc.none")).tag("none")
                        }.pickerStyle(.segmented)
                        fetchFields(draft)
                    }
                    Divider()
                    Group {
                        Text(L.t("rc.mapping")).font(.system(size: 11, weight: .semibold))
                        TextField(L.t("rc.gauge.label"), text: draft.gaugeLabel)
                        Picker(L.t("rc.map.mode"), selection: draft.mapMode) {
                            Text(L.t("rc.map.value")).tag("value")
                            Text(L.t("rc.map.usedlimit")).tag("usedLimit")
                            Text(L.t("rc.map.remaininglimit")).tag("remainingLimit")
                            Text(L.t("rc.map.remaining")).tag("remaining")
                        }
                        mapFields(draft)
                        HStack {
                            Picker(L.t("rc.unit"), selection: draft.unit) {
                                ForEach(["percent", "fraction", "usd", "cny", "thb", "tokens", "bytes", "text"], id: \.self) { Text($0).tag($0) }
                            }
                            Picker(L.t("rc.window"), selection: draft.window) {
                                Text("5h").tag("5h"); Text(L.t("rc.weekly")).tag("weekly")
                                Text(L.t("rc.model")).tag("model"); Text(L.t("rc.other")).tag("other")
                            }
                        }
                        TextField(L.t("rc.resets"), text: draft.resetsAt, prompt: Text("$.renews_at"))
                        HStack {
                            TextField(L.t("rc.line.path"), text: draft.linePath, prompt: Text("$.plan"))
                            TextField(L.t("rc.line.prefix"), text: draft.linePrefix, prompt: Text("Plan: "))
                        }
                    }
                    if !problem.isEmpty {
                        Text(problem).font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
                    }
                    if let baseline = approvalBaseline,
                       (draft.wrappedValue.method == "http" || draft.wrappedValue.method == "cli"),
                       draft.wrappedValue.needsReapproval(comparedTo: baseline) {
                        Text(L.t("rc.reapprove.hint")).font(.system(size: 9))
                            .foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    }
                    if draft.wrappedValue.method == "http" && draft.wrappedValue.verb != "GET" {
                        Text(L.t("rc.mutating")).font(.system(size: 9))
                            .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
                    }
                    if testing { ProgressView().controlSize(.small) }
                    if let result = draft.wrappedValue.tested {
                        TestResultView(result: result) { key in state.draft?.resetsAt = "$.\(key)" }
                    }
                    HStack {
                        Button(L.t("s.discard")) { state.draft = nil; state.nav.pop() }
                        Spacer()
                        Button(L.t("w.test")) { test(draft.wrappedValue) }.disabled(testing)
                        Button(L.t("w.save")) { save(draft.wrappedValue) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }.onAppear {
            if state.draft == nil { state.draft = RecipeDraft() }
            if approvalBaseline == nil { approvalBaseline = state.draft }
        }
    }

    private var binding: Binding<RecipeDraft>? {
        guard state.draft != nil else { return nil }
        return Binding(get: { state.draft! }, set: { state.draft = $0 })
    }

    @ViewBuilder private func credentialFields(_ draft: Binding<RecipeDraft>) -> some View {
        switch draft.wrappedValue.credentialSource {
        case "keychain":
            SecureField(L.t("rc.paste.key"), text: draft.credential)
            Text(L.t("rc.saved.keychain")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
        case "keyFile": pathPicker(L.t("rc.choose.keyfile"), path: draft.credentialPath, directory: false)
        case "env": TextField(L.t("rc.env.name"), text: draft.credentialName, prompt: Text("TYPHOON_API_KEY"))
        case "appKeychain":
            TextField(L.t("rc.app.item"), text: draft.appKeychainService)
            TextField(L.t("rc.json.field"), text: draft.jsonField)
        default: Text(L.t("rc.no.credential")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
        }
    }

    @ViewBuilder private func fetchFields(_ draft: Binding<RecipeDraft>) -> some View {
        switch draft.wrappedValue.method {
        case "http":
            TextField(L.t("rc.host"), text: draft.baseURL, prompt: Text("https://api.example.com"))
            HStack {
                Picker(L.t("rc.verb"), selection: draft.verb) { Text("GET").tag("GET"); Text("POST").tag("POST") }
                TextField(L.t("rc.path"), text: draft.path, prompt: Text("/v1/credits"))
            }
            Picker(L.t("rc.auth"), selection: draft.auth) {
                Text("Bearer").tag("bearer"); Text(L.t("rc.header")).tag("header")
                Text(L.t("rc.query")).tag("query"); Text(L.t("rc.none")).tag("none")
            }
            if draft.wrappedValue.auth == "header" || draft.wrappedValue.auth == "query" {
                TextField(L.t("rc.auth.name"), text: draft.authName)
            }
            if draft.wrappedValue.verb == "POST" {
                TextField(L.t("rc.body"), text: draft.bodyJSON, prompt: Text("{}"))
            }
        case "cli":
            pathPicker(L.t("rc.choose.command"), path: draft.binary, directory: false)
            TextField(L.t("rc.args"), text: draft.args)
            TextField("ENV (KEY=value per line)", text: draft.environmentLines)
        case "file":
            pathPicker(L.t("rc.choose.folder"), path: draft.folder, directory: true)
            TextField(L.t("rc.glob"), text: draft.glob)
        default: Text(L.t("rc.no.request")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
        }
    }

    @ViewBuilder private func mapFields(_ draft: Binding<RecipeDraft>) -> some View {
        switch draft.wrappedValue.mapMode {
        case "usedLimit":
            TextField(L.t("rc.used.path"), text: draft.usedPath)
            TextField(L.t("rc.limit.path"), text: draft.limitPath)
        case "remainingLimit":
            TextField(L.t("rc.remaining.path"), text: draft.remainingPath)
            TextField(L.t("rc.limit.path"), text: draft.limitPath)
        case "remaining": TextField(L.t("rc.remaining.path"), text: draft.remainingPath)
        default: TextField(L.t("rc.value.path"), text: draft.gaugePath)
        }
    }

    private func pathPicker(_ label: String, path: Binding<String>, directory: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label).font(.system(size: 10))
                Text(path.wrappedValue.isEmpty ? "—" : (path.wrappedValue as NSString).lastPathComponent)
                    .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
            Spacer(); Button(L.t("w.choose")) {
                state.onDismissalSuspended(true); defer { state.onDismissalSuspended(false) }
                let panel = NSOpenPanel(); panel.canChooseFiles = !directory
                panel.canChooseDirectories = directory; panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    private func validation(_ draft: RecipeDraft) -> (Recipe, RecipePin.Pin, AccountSpec)? {
        let recipe = draft.recipe()
        guard !recipe.name.trimmingCharacters(in: .whitespaces).isEmpty else { problem = L.t("w.needname"); return nil }
        guard Recipe.validID(recipe.id), !Recipe.reservedIDs.contains(recipe.id) else { problem = L.t("rc.invalid.id"); return nil }
        guard !store.cfg.recipes.contains(where: { $0.id == recipe.id }) else { problem = L.t("w.dup"); return nil }
        let spec = account(draft, recipe: recipe)
        if let message = Credential.validateRecipeCredential(recipe, account: spec) {
            problem = message; return nil
        }
        guard let pin = RecipePin.proposed(recipe, account: spec) else { problem = L.t("rc.invalid.destination"); return nil }
        if recipe.fetch.method == "file", !RecipeFetch.fileGlobIsSafe(recipe.fetch.glob ?? "") {
            problem = L.t("rc.invalid.glob"); return nil
        }
        return (recipe, pin, spec)
    }

    private func account(_ draft: RecipeDraft, recipe: Recipe, service: String? = nil) -> AccountSpec {
        var account = AccountSpec(name: draft.name)
        switch draft.credentialSource {
        case "keychain": account.keychainService = service ?? RecipePin.service(recipe.id) + " · credential"
        case "keyFile": account.keyFile = draft.credentialPath; account.keyJSONField = draft.jsonField.isEmpty ? nil : draft.jsonField
        default: break
        }
        if recipe.fetch.homeFromAccount { account.home = expand("~") }
        return account
    }

    private func test(_ draft: RecipeDraft) {
        guard let (recipe, pin, spec) = validation(draft) else { return }
        problem = ""; testing = true
        let temporary = "AIMeter · recipe-test · \(UUID().uuidString)"
        let useTemporary = draft.credentialSource == "keychain"
        if useTemporary, !draft.credential.isEmpty { _ = Credential.store(draft.credential, service: temporary) }
        let testSpec = useTemporary ? account(draft, recipe: recipe, service: temporary) : spec
        Task { @MainActor in
            defer { if useTemporary { Credential.delete(service: temporary) }; testing = false }
            switch await RecipeFetch.test(recipe, account: testSpec, pin: pin) {
            case .success(let result): state.draft?.tested = result; problem = ""
            case .failure(let fail): problem = fail.message
            }
        }
    }

    private func save(_ draft: RecipeDraft) {
        guard let (recipe, _, spec) = validation(draft) else { return }
        state.onDismissalSuspended(true); defer { state.onDismissalSuspended(false) }
        guard RecipePin.write(recipe, account: spec) else { problem = L.t("k.denied"); return }
        if draft.credentialSource == "keychain", !draft.credential.isEmpty,
           let service = spec.keychainService,
           !Credential.store(draft.credential, service: service) {
            RecipePin.delete(recipe.id); problem = L.t("k.denied"); return
        }
        store.addRecipe(recipe, account: spec)
        store.test(recipe.id, spec)
        state.draft = nil; state.nav.stack = [.root, .services]
    }
}

struct TestResultView: View {
    let result: RecipeTestResult
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Circle().fill(Color(nsColor: stateColour(result.reading.state))).frame(width: 8, height: 8)
                Text(result.meta.request).font(.system(size: 10, weight: .medium)).lineLimit(2)
            }
            Text(L.t("rc.meta", result.meta.status.map(String.init) ?? "—", result.meta.bytes,
                     Int(result.meta.elapsed * 1000), result.meta.contentType ?? "—"))
                .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            ForEach(Array(result.reading.gauges.enumerated()), id: \.offset) { _, gauge in
                Text("\(gauge.label): \(gauge.text)").font(.system(size: 10))
            }
            if !result.suggestions.isEmpty {
                Text(L.t("rc.suggestions")).font(.system(size: 9, weight: .semibold))
                FlowLayout(spacing: 5, lineSpacing: 4) {
                    ForEach(result.suggestions, id: \.self) { key in
                        Button(key) { onSuggestion(key) }.font(.system(size: 9))
                    }
                }
            }
            Text(result.rawPreview).font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled).lineLimit(8)
        }.padding(8).background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct AddBuiltinView: View {
    let providerID: String
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore
    @State private var problem = ""

    private var kind: ProviderKind { ProviderKind.find(providerID) ?? ProviderKind.all[0] }

    var body: some View {
        SettingsPageFrame(state: state, title: kind.title, back: { state.nav.pop() }) {
            if let draft = draftBinding {
                VStack(alignment: .leading, spacing: 11) {
                    TextField(L.t("w.name"), text: draft.name, prompt: Text(L.t("w.nameph")))
                    if kind.modes.count > 1 {
                        Picker(L.t("w.howauth"), selection: draft.mode) {
                            ForEach(kind.modes) { Text($0.label).tag($0) }
                        }.pickerStyle(.radioGroup)
                    }
                    authFields(draft)
                    if kind.needsURL {
                        TextField(L.t("w.baseurl"), text: draft.baseURL,
                                  prompt: Text("https://api.example.com"))
                        TextField(L.t("w.balpath"), text: draft.balancePath,
                                  prompt: Text("/v1/credits"))
                    }
                    if !problem.isEmpty {
                        Text(problem).font(.system(size: 10))
                            .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
                    }
                    HStack {
                        Button(L.t("s.discard")) { state.builtinDraft = nil; state.nav.pop() }
                        Spacer()
                        Button(L.t("w.save")) { save() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear {
            if state.builtinDraft?.providerID != providerID { state.builtinDraft = AddDraft(providerID: providerID) }
        }
    }

    private var draftBinding: Binding<AddDraft>? {
        guard state.builtinDraft != nil else { return nil }
        return Binding(get: { state.builtinDraft! }, set: { state.builtinDraft = $0 })
    }

    @ViewBuilder
    private func authFields(_ draft: Binding<AddDraft>) -> some View {
        switch draft.wrappedValue.mode {
        case .paste:
            SecureField(L.t("w.key"), text: draft.pasted)
            Text(L.t("w.keysaved")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            if let page = kind.keyPage {
                Text(L.t("w.getkey", page)).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
        case .file:
            picker(L.t("w.keyfile"), path: draft.path, directories: false)
        case .folder:
            picker(L.t("w.folder"), path: draft.path, directories: true)
            if let marker = kind.folderMarker {
                Text(L.t("w.folderhelp", marker)).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
        case .keychain:
            Text(L.t("s.src.claude")).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            Text(L.t("s.claude.cli")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
        }
    }

    private func picker(_ label: String, path: Binding<String>, directories: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11))
                Text(path.wrappedValue.isEmpty ? "—" : (path.wrappedValue as NSString).lastPathComponent)
                    .font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            }
            Spacer()
            Button(L.t("w.choose")) {
                state.onDismissalSuspended(true)
                defer { state.onDismissalSuspended(false) }
                let panel = NSOpenPanel()
                panel.canChooseFiles = !directories
                panel.canChooseDirectories = directories
                panel.allowsMultipleSelection = false
                panel.showsHiddenFiles = true
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }

    private func save() {
        guard let draft = state.builtinDraft else { return }
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { problem = L.t("w.needname"); return }
        guard !store.exists(providerID, name) else { problem = L.t("w.dup"); return }
        var account = AccountSpec(name: name)
        switch draft.mode {
        case .paste:
            guard !draft.pasted.isEmpty else { problem = L.t("w.needcred"); return }
            let service = Credential.service(provider: providerID, account: name)
            let approved = kind.needsURL ? draft.baseURL.trimmingCharacters(in: .whitespaces) : nil
            state.onDismissalSuspended(true)
            defer { state.onDismissalSuspended(false) }
            guard Credential.store(draft.pasted, service: service, base: approved) else {
                problem = L.t("k.denied"); return
            }
            account.keychainService = service
        case .file:
            guard !draft.path.isEmpty else { problem = L.t("w.needcred"); return }
            account.keyFile = draft.path
        case .folder:
            guard !draft.path.isEmpty else { problem = L.t("w.needcred"); return }
            if let marker = kind.folderMarker,
               !FileManager.default.fileExists(atPath: draft.path + "/" + marker) {
                problem = L.t("w.folderhelp", marker); return
            }
            account.home = draft.path
        case .keychain:
            guard !draft.keychainService.isEmpty else { problem = L.t("w.needcred"); return }
            account.keychainService = draft.keychainService
        }
        if kind.needsURL {
            guard !draft.baseURL.isEmpty, !draft.balancePath.isEmpty else {
                problem = L.t("w.needcred"); return
            }
            guard draft.baseURL.lowercased().hasPrefix("https://") else {
                problem = L.t("e.httpsonly"); return
            }
            account.baseURL = draft.baseURL
            account.balancePath = draft.balancePath
        }
        store.add(providerID, account)
        state.builtinDraft = nil
        state.nav.pop()
    }
}

struct MenuBarPageView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore

    private var primaryOptions: [(String, String)] {
        let builtins = [("claude", L.t("p.claude")), ("codex", L.t("p.codex"))]
            .filter { store.accounts($0.0).contains { $0.enabled } }
        let recipes = store.cfg.recipes.filter { recipe in
            recipe.map.gauges.contains { $0.window == "5h" || $0.window == "weekly" }
                && store.accounts(recipe.id).contains { $0.enabled }
        }.map { ($0.id, $0.name) }
        return builtins + recipes
    }

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("w.menubar"), back: { state.nav.pop() }) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L.t("mb.primary"), selection: Binding(
                    get: { store.cfg.menuBar.primary },
                    set: { store.cfg.menuBar.primary = $0; store.persist(cosmetic: true) })) {
                        ForEach(primaryOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                Picker(L.t("s.style"), selection: Binding(
                    get: { store.cfg.menuBar.style == "bars" ? "ring" : store.cfg.menuBar.style },
                    set: { store.cfg.menuBar.style = $0; store.persist(cosmetic: true) })) {
                        Text(L.t("mb.style.ring")).tag("ring")
                        Text(L.t("mb.style.numeral")).tag("ringNumeral")
                    }.pickerStyle(.segmented)
                Toggle(L.t("mb.alertdot"), isOn: Binding(
                    get: { store.cfg.menuBar.alertDot },
                    set: { store.cfg.menuBar.alertDot = $0; store.persist(cosmetic: true) }))
                Toggle(L.t("mb.animate"), isOn: Binding(
                    get: { store.cfg.menuBar.animate },
                    set: { store.cfg.menuBar.animate = $0; store.persist(cosmetic: true) }))
                Text(L.t("s.animate.rm")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                previewGrid
                Text(L.t("s.preview.hint")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var previewGrid: some View {
        let live = RingIcon.model(readings: ReadingsBox.shared.current,
                                  primary: store.cfg.menuBar.primary,
                                  style: store.cfg.menuBar.style)
        var model = live.outer == nil && live.inner == nil
            ? RingIcon.RingModel(outer: 53, inner: 11,
                                 alertDot: store.cfg.menuBar.alertDot,
                                 numeral: store.cfg.menuBar.style == "ringNumeral" ? "53%" : nil)
            : live
        if !store.cfg.menuBar.alertDot { model.alertDot = false }
        let image = RingIcon.image(for: model)
        let cells: [(String, NSColor)] = [
            (L.t("s.preview.light"), .white), (L.t("s.preview.dark"), .black),
            (L.t("s.preview.blue"), NSColor(srgbRed: 0.12, green: 0.42, blue: 0.86, alpha: 1)),
            (L.t("s.preview.sel"), NSColor(srgbRed: 0.04, green: 0.36, blue: 0.82, alpha: 1))
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 3) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: image.size.width * 2.2, height: image.size.height * 2.2)
                    Text(cell.0).font(.system(size: 8))
                        .foregroundStyle(cell.1 == .black ? Color.white : Color.black)
                }
                .frame(maxWidth: .infinity).padding(7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: cell.1)))
            }
        }
    }
}

struct GeneralPageView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("s.general"), back: { state.nav.pop() }) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(L.t("m.language"), selection: Binding(
                    get: { store.cfg.language },
                    set: { store.cfg.language = $0; state.onPickLanguage($0) })) {
                        ForEach(Lang.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                Picker(L.t("m.interval"), selection: Binding(
                    get: { store.cfg.refreshSeconds },
                    set: { store.cfg.refreshSeconds = $0; state.onPickInterval($0) })) {
                        ForEach([30, 60, 300, 900, 0], id: \.self) {
                            Text(settingsIntervalLabel($0)).tag($0)
                        }
                    }
                Text(L.t("s.interval.default")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                Toggle(L.t("m.login"), isOn: Binding(
                    get: { state.loginEnabled }, set: { _ in state.onToggleLogin() }))
                Divider()
                Text(L.t("s.debug.sub")).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                Button(L.t("s.open")) { state.onOpenDebug() }
                Button(L.t("s.detect.again")) { detect() }
            }
        }
    }

    private func detect() {
        for (provider, found) in Discovery.all() {
            for var spec in found where !store.hasSource(provider, spec) {
                spec.name = store.uniqueName(provider, spec.name)
                store.add(provider, spec)
            }
        }
    }
}

struct HistoryPageView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: SettingsStore
    @State private var exportProblem = ""

    var body: some View {
        SettingsPageFrame(state: state, title: L.t("pn.history"), back: { state.nav.pop() }) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L.t("s.record"), isOn: Binding(
                    get: { store.cfg.history.enabled },
                    set: { store.cfg.history.enabled = $0; store.persist() }))
                Text(L.t("s.record.sub")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                Picker(L.t("s.keep.for"), selection: Binding(
                    get: { store.cfg.history.retentionMonths },
                    set: { store.cfg.history.retentionMonths = $0; store.persist() })) {
                        ForEach([1, 3, 6, 12, 24], id: \.self) { Text(L.t("s.months", $0)).tag($0) }
                    }
                Divider()
                Text(L.t("s.report")).font(.system(size: 12, weight: .semibold))
                Text(L.t("s.report.sub")).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L.t("s.report.open")) { state.onOpenReport() }
                    Button(L.t("s.export")) { export() }
                }
                if !exportProblem.isEmpty {
                    Text(exportProblem).font(.system(size: 9))
                        .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
                }
                Divider()
                Text(L.t("s.thismonth")).font(.system(size: 12, weight: .semibold))
                Text(monthSummary).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                Button(L.t("s.finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Config.dir + "/history")])
                }
            }
        }
    }

    private var monthSummary: String {
        let stamp = History.monthKey(for: Date())
        let path = Config.dir + "/history/" + stamp + ".jsonl"
        let lines = (try? String(contentsOfFile: path, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        return L.t("s.thismonth.sub", stamp, lines)
    }

    private func export() {
        state.onDismissalSuspended(true)
        defer { state.onDismissalSuspended(false) }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let destination = picker.url else { return }
        let (csv, html) = HistoryReport.export()
        do {
            for source in [csv, html] {
                let target = destination.appendingPathComponent((source as NSString).lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)
            }
            exportProblem = ""
        } catch {
            exportProblem = error.localizedDescription
        }
    }
}
