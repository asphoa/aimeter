import AppKit
import SwiftUI

/// One choosable thing that can occupy a slot in the menu bar strip.
struct SourceOption: Identifiable, Hashable {
    var line: MenuLine?
    var label: String
    var id: String {
        guard let l = line else { return "" }
        return "\(l.provider)|\(l.account)|\(l.gauge)"
    }

    /// Everything the user could put on the strip, in plain words, built from
    /// the accounts they actually have rather than from a hardcoded list.
    static func all(_ cfg: Config) -> [SourceOption] {
        var out: [SourceOption] = [SourceOption(line: nil, label: L.t("w.empty"))]
        for kind in ProviderKind.all {
            let accounts = (cfg.accounts[kind.id] ?? []).filter(\.enabled)
            guard !accounts.isEmpty else { continue }
            if kind.id == "openrouter" {
                // Each key is its own budget, so the useful choices are "the
                // worst of them" or one named key - not the account list.
                out.append(SourceOption(line: MenuLine(provider: kind.id),
                                        label: "\(kind.title) — \(L.t("w.worstkey"))"))
                for a in accounts {
                    out.append(SourceOption(line: MenuLine(provider: kind.id, gauge: a.name),
                                            label: "\(kind.title) — \(a.name)"))
                }
                continue
            }
            if accounts.count > 1 {
                out.append(SourceOption(line: MenuLine(provider: kind.id),
                                        label: "\(kind.title) — \(L.t("w.worstkey"))"))
            }
            for a in accounts {
                out.append(SourceOption(line: MenuLine(provider: kind.id, account: a.name),
                                        label: accounts.count > 1 ? "\(kind.title) — \(a.name)"
                                                                  : kind.title))
            }
        }
        out.append(SourceOption(line: MenuLine(provider: "local"), label: L.t("p.local")))
        return out
    }
}

/// The "Menu bar" half of the Accounts window: five ordered slots and a live
/// preview of what they produce. The preview is the point - without it, picking
/// sources is guesswork for anyone who does not already know what the strip
/// looks like.
struct MenuBarSection: View {
    @ObservedObject var store: AccountsStore

    /// Providers that actually have windows to ring — the primary picker
    /// offers only these, not every enabled service.
    private var primaryOptions: [(id: String, title: String)] {
        [("claude", L.t("p.claude")), ("codex", L.t("p.codex"))]
            .filter { (store.cfg.accounts[$0.id] ?? []).contains { $0.enabled } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("w.menubar")).font(.headline)
            Text(L.t("w.menubar.intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(L.t("mb.primary"), selection: Binding(
                        get: { store.cfg.menuBar.primary },
                        set: { store.cfg.menuBar.primary = $0; store.persist(cosmetic: true) })) {
                            ForEach(primaryOptions, id: \.id) { Text($0.title).tag($0.id) }
                        }
                        .frame(width: 260)

                    Picker("", selection: Binding(
                        get: { store.cfg.menuBar.style == "bars" ? "ring" : store.cfg.menuBar.style },
                        set: { store.cfg.menuBar.style = $0; store.persist(cosmetic: true) })) {
                            Text(L.t("mb.style.ring")).tag("ring")
                            Text(L.t("mb.style.numeral")).tag("ringNumeral")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)

                    Toggle(L.t("mb.alertdot"), isOn: Binding(
                        get: { store.cfg.menuBar.alertDot },
                        set: { store.cfg.menuBar.alertDot = $0; store.persist(cosmetic: true) }))
                    Toggle(L.t("mb.animate"), isOn: Binding(
                        get: { store.cfg.menuBar.animate },
                        set: { store.cfg.menuBar.animate = $0; store.persist(cosmetic: true) }))
                }
                VStack(spacing: 6) {
                    Text(L.t("mb.preview")).font(.caption).foregroundStyle(.secondary)
                    preview
                }
                .padding(.top, 2)
            }
        }
    }

    /// Renders the actual `RingIcon.image`, on a menu-bar-coloured strip, so
    /// the picker/toggles above update it live — the same live-readings box
    /// the old strip preview used.
    private var preview: some View {
        let model = RingIcon.model(readings: ReadingsBox.shared.current,
                                   primary: store.cfg.menuBar.primary,
                                   style: store.cfg.menuBar.style)
        var shown = model
        if !store.cfg.menuBar.alertDot { shown.alertDot = false }
        let img = RingIcon.image(for: shown)
        return Image(nsImage: img)
            .interpolation(.high)
            .resizable()
            .frame(width: img.size.width * 4, height: img.size.height * 4)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }
}
