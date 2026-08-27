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

    private var options: [SourceOption] { SourceOption.all(store.cfg) }

    private var slots: [MenuLine?] {
        var l: [MenuLine?] = store.cfg.menuBar.lines.map { Optional($0) }
        while l.count < StatusStrip.maxLines { l.append(nil) }
        return Array(l.prefix(StatusStrip.maxLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("w.menubar")).font(.headline)
            Text(L.t("w.menubar.intro"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 6) {
                    ForEach(0..<StatusStrip.maxLines, id: \.self) { slot(at: $0) }
                }
                VStack(spacing: 6) {
                    Text(L.t("w.preview")).font(.caption).foregroundStyle(.secondary)
                    preview
                }
                .padding(.top, 2)
            }

            Picker("", selection: Binding(
                get: { store.cfg.menuBar.colourScheme },
                set: { store.cfg.menuBar.colourScheme = $0; store.persist(cosmetic: true) })) {
                    Text(L.t("m.barcolour.provider")).tag(BarColourScheme.provider)
                    Text(L.t("m.barcolour.window")).tag(BarColourScheme.window)
                    Text(L.t("m.barcolour.adaptive")).tag(BarColourScheme.adaptive)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            Button(L.t("w.menubar.optimize")) {
                // Adaptive is computed from these slots at draw time.  Do not
                // bake swatches into Config.colours: a later slot edit must not
                // quietly leave two visible services sharing an old colour.
                store.cfg.menuBar.colourScheme = .adaptive
                store.persist(cosmetic: true)
            }
            .help(L.t("w.menubar.optimize.help"))
        }
    }

    @ViewBuilder
    private func slot(at index: Int) -> some View {
        let current = slots[index]
        HStack(spacing: 6) {
            Picker("", selection: Binding(
                get: { SourceOption(line: current, label: "").id },
                set: { newID in
                    let picked = options.first { $0.id == newID }?.line
                    apply(picked, at: index)
                })) {
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: 260)

            Button {
                move(index, by: -1)
            } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0 || current == nil)
                .help(L.t("w.moveup"))

            Button {
                move(index, by: 1)
            } label: { Image(systemName: "chevron.down") }
                .disabled(index >= store.cfg.menuBar.lines.count - 1 || current == nil)
                .help(L.t("w.movedown"))
        }
    }

    private var preview: some View {
        let lines = store.cfg.menuBar.lines.map {
            resolveStripLine($0, ReadingsBox.shared.current, store.cfg)
        }
        let img = StatusStrip.image(lines: lines, scheme: store.cfg.menuBar.colourScheme)
        return Image(nsImage: img)
            .interpolation(.none)
            .resizable()
            .frame(width: StatusStrip.width * 4, height: StatusStrip.height * 4)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    }

    private func apply(_ picked: MenuLine?, at index: Int) {
        var lines = store.cfg.menuBar.lines
        if let picked {
            // Nothing is gained by the same source twice, and a duplicate row
            // looks like a bug rather than a choice.
            lines.removeAll { $0 == picked }
            if index < lines.count { lines[index] = picked } else { lines.append(picked) }
        } else if index < lines.count {
            lines.remove(at: index)
        }
        store.cfg.menuBar.lines = Array(lines.prefix(StatusStrip.maxLines))
        store.persist(cosmetic: true)
    }

    private func move(_ index: Int, by delta: Int) {
        var lines = store.cfg.menuBar.lines
        let to = index + delta
        guard lines.indices.contains(index), lines.indices.contains(to) else { return }
        lines.swapAt(index, to)
        store.cfg.menuBar.lines = lines
        store.persist(cosmetic: true)
    }
}
