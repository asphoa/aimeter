import Foundation

enum PanelFormat {
    static func resetText(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        if resetsAt <= now { return L.t("m.ended", Fmt.relative(resetsAt)) }
        return L.t("pn.reset.in", Fmt.span(resetsAt, now: now))
    }

    static func intervalText(_ seconds: Int) -> String {
        guard seconds > 0 else { return L.t("pn.manual") }
        return seconds < 60 ? L.t("m.seconds", seconds) : L.t("m.minutes", seconds / 60)
    }

    static func updatedLine(time: Date?, intervalSeconds: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let stamp = time.map(f.string) ?? "—"
        return L.t("pn.updated", stamp, intervalText(intervalSeconds))
    }
}

/// Pure content for the card panel. Every provider has the same model; compact
/// and expanded are presentation states rather than separate provider roles.
struct PanelModel: Equatable {
    struct Chip: Equatable {
        var kind: GaugeKind
        var label: String
        var percent: Double?
        var value: String
        var resetText: String?
        var resetsAt: Date?
    }

    struct Row: Equatable {
        var account: String?
        var label: String
        var percent: Double?
        var value: String
        var resetText: String?
        var resetsAt: Date?
        var expired: Bool = false
    }

    struct Hero: Equatable {
        var account: String?
        var kind: GaugeKind
        var percent: Double?
        var text: String
        var label: String
        var resetText: String?
        var resetsAt: Date?
    }

    struct SparkPoint: Equatable {
        var date: Date
        var value: Double
    }

    struct Card: Equatable {
        var id: String
        var title: String
        var state: ReadingState
        var ageText: String?
        var badge: String?
        var failureMessage: String?
        var notices: [String] = []
        var linkOnly: Bool
        var expanded: Bool
        var compact: [Row]
        var hero: Hero?
        var chips: [Chip]
        var sparkline: [SparkPoint]?
        var hasData: Bool
        var opacity: Double = 1.0
    }

    /// Compatibility projections for pure tests that predate the unified card
    /// model. Production panel code consumes `cards` only.
    struct Primary: Equatable {
        var providerId: String
        var title: String
        var hasData: Bool
        var state: ReadingState
        var ageText: String?
        var heroPercent: Double?
        var heroText: String
        var windowLabel: String
        var resetText: String?
        var resetsAt: Date?
        var failureMessage: String?
        var chips: [Chip]
    }

    struct SecondaryCard: Equatable {
        var id: String
        var title: String
        var state: ReadingState
        var badge: String?
        var rows: [Row]
        var failureMessage: String?
        var linkOnly: Bool = false
        var opacity: Double = 1.0
    }

    var cards: [Card]

    var primary: Primary {
        let card = cards.first ?? Self.emptyCard(primaryId: "claude")
        return Primary(providerId: card.id, title: card.title, hasData: card.hasData,
                       state: card.state, ageText: card.ageText ?? card.badge,
                       heroPercent: card.hero?.percent, heroText: card.hero?.text ?? "—",
                       windowLabel: card.hero?.label ?? "", resetText: card.hero?.resetText,
                       resetsAt: card.hero?.resetsAt, failureMessage: card.failureMessage,
                       chips: card.chips)
    }

    var secondaries: [SecondaryCard] {
        cards.dropFirst().map { card in
            SecondaryCard(id: card.id, title: card.title, state: card.state, badge: card.badge,
                          rows: card.compact, failureMessage: card.failureMessage,
                          linkOnly: card.linkOnly, opacity: card.opacity)
        }
    }

    static func empty(primaryId: String) -> PanelModel {
        PanelModel(cards: [emptyCard(primaryId: primaryId)])
    }

    private static func emptyCard(primaryId: String) -> Card {
        Card(id: primaryId, title: PanelModelBuilder.title(for: primaryId), state: .off,
             ageText: nil, badge: nil, failureMessage: nil, notices: [],
             linkOnly: false, expanded: true, compact: [], hero: nil, chips: [], sparkline: nil,
             hasData: false)
    }
}

enum PanelModelBuilder {
    static func title(for id: String) -> String {
        if let kind = ProviderKind.find(id) { return kind.title }
        switch id {
        case "local": return L.t("p.local")
        case "cursor": return L.t("p.cursor")
        default: return id
        }
    }

    static let fixedSecondaryOrder = ["codex", "openrouter", "deepseek", "agy", "local", "cursor"]

    static func build(readings: [String: [Reading]], cfg: Config,
                      coordinatorNotices: [String: [String]] = [:],
                      now: Date = Date()) -> PanelModel {
        let primaryId = cfg.menuBar.primary
        let expanded = Set(cfg.menuBar.expanded)
        let ids = orderedIDs(readings: readings, primaryId: primaryId)
        let cards = ids.compactMap { id -> PanelModel.Card? in
            let extra = coordinatorNotices[id] ?? []
            if id == primaryId {
                return buildCard(id: id, raw: readings[id] ?? [], expanded: expanded.contains(id),
                                 coordinatorNotices: extra, now: now, cfg: cfg)
            }
            guard let raw = readings[id], !raw.isEmpty else { return nil }
            return buildCard(id: id, raw: raw, expanded: expanded.contains(id),
                             coordinatorNotices: extra, now: now, cfg: cfg)
        }
        return PanelModel(cards: cards)
    }

    static func orderedIDs(readings: [String: [Reading]], primaryId: String) -> [String] {
        var out = [primaryId]
        for id in fixedSecondaryOrder where id != primaryId && readings[id]?.isEmpty == false {
            out.append(id)
        }
        let covered = Set(fixedSecondaryOrder + [primaryId])
        out.append(contentsOf: readings.keys.sorted().filter {
            !covered.contains($0) && readings[$0]?.isEmpty == false
        })
        return out
    }

    private static func buildCard(id: String, raw: [Reading], expanded: Bool,
                                  coordinatorNotices: [String],
                                  now: Date, cfg: Config) -> PanelModel.Card {
        let fallbackTitle = title(for: id)
        guard !raw.isEmpty else {
            return PanelModel.Card(id: id, title: fallbackTitle, state: .off, ageText: nil,
                                   badge: nil, failureMessage: nil, notices: [],
                                   linkOnly: false, expanded: expanded, compact: [], hero: nil,
                                   chips: [], sparkline: nil, hasData: false)
        }

        let readings = raw.map { $0.asOf(now) }
        let multiAccount = Set(readings.compactMap(\.account)).count > 1
        let title = readings.first?.title ?? fallbackTitle
        let state = readings.map(\.state).max() ?? .off
        let gauges = readings.flatMap { reading in
            reading.gauges.map { (reading.account, $0) }
        }
        let heroAccount = primaryAccount(in: readings, cfg: cfg)
        let heroGauge = heroGaugeEntry(in: gauges, account: heroAccount)
        let heroFlatIndex = heroGauge.flatMap { chosen in gauges.firstIndex(where: { $0.0 == chosen.0 && $0.1.label == chosen.1.label }) }
        let observed = heroGauge?.1.observedAt
            ?? gauges.compactMap(\.1.observedAt).min()
            ?? readings.compactMap(\.snapshotAt).min()
        let badge = observed.map { L.t("m.snapshot", Fmt.relative($0)) }
        let ageText = id == "claude" ? L.t("pn.free") : badge
        let opacity: Double = (id == "local" && state == .off) ? 0.6 : 1.0
        var notices: [String] = []
        for reading in readings {
            for line in reading.lines {
                if let account = reading.account, multiAccount {
                    notices.append("\(account): \(line)")
                } else {
                    notices.append(line)
                }
            }
        }
        notices.append(contentsOf: coordinatorNotices)

        if id == "cursor" {
            return PanelModel.Card(id: id, title: title, state: state, ageText: nil, badge: nil,
                                   failureMessage: readings.first?.lines.first, notices: notices,
                                   linkOnly: true, expanded: false, compact: [], hero: nil,
                                   chips: [], sparkline: nil, hasData: true, opacity: opacity)
        }

        let compact = gauges.map { account, gauge in
            toRow(gauge, account: multiAccount ? account : nil, now: now)
        }
        let failures = readings.filter { $0.state == .failure }
        let failureMessage = failures.count == readings.count
            ? (failures.first?.lines.first ?? L.t("e.connplain"))
            : nil

        let hero: PanelModel.Hero? = heroGauge.map { account, gauge in
            PanelModel.Hero(account: multiAccount ? account : nil,
                            kind: gauge.kind, percent: gauge.percent, text: gauge.text,
                            label: gauge.label,
                            resetText: PanelFormat.resetText(gauge.resetsAt, now: now),
                            resetsAt: gauge.resetsAt)
        }
        let remaining = gauges.enumerated().compactMap { index, pair in
            index == heroFlatIndex ? nil : pair.1
        }
        return PanelModel.Card(id: id, title: title, state: state, ageText: ageText, badge: badge,
                               failureMessage: failureMessage, notices: notices, linkOnly: false,
                               expanded: expanded, compact: compact, hero: hero,
                               chips: buildChips(remaining, multiAccount: multiAccount, now: now),
                               sparkline: nil, hasData: !gauges.isEmpty || !notices.isEmpty,
                               opacity: opacity)
    }

    private static func primaryAccount(in readings: [Reading], cfg: Config) -> String? {
        readings.first(where: { $0.account != nil && $0.state != .failure })?.account
            ?? readings.first?.account
    }

    private static func heroGaugeEntry(in gauges: [(String?, Gauge)],
                                       account: String?) -> (String?, Gauge)? {
        guard !gauges.isEmpty else { return nil }
        let pool = account.map { wanted in gauges.filter { $0.0 == wanted } } ?? gauges
        let index = heroGaugeIndex(in: pool.map(\.1))
        guard let index else { return pool.first }
        return pool[index]
    }

    private static func heroGaugeIndex(in gauges: [Gauge]) -> Int? {
        for kind in [GaugeKind.shortWindow, .longWindow, .modelWindow, .other] {
            if let index = gauges.firstIndex(where: { $0.kind == kind && $0.percent != nil }) {
                return index
            }
        }
        return gauges.isEmpty ? nil : 0
    }

    private static func buildChips(_ gauges: [Gauge], multiAccount: Bool, now: Date) -> [PanelModel.Chip] {
        let short = gauges.filter { $0.kind == .shortWindow }
        let long = gauges.filter { $0.kind == .longWindow }
        let models = gauges.filter { $0.kind == .modelWindow }.sorted { $0.label < $1.label }
        let other = gauges.filter { $0.kind == .other }
        return (short + long + models + other).map { gauge in
            PanelModel.Chip(kind: gauge.kind, label: gauge.label, percent: gauge.percent,
                            value: gauge.text,
                            resetText: PanelFormat.resetText(gauge.resetsAt, now: now),
                            resetsAt: gauge.resetsAt)
        }
    }

    private static func toRow(_ gauge: Gauge, account: String?, now: Date) -> PanelModel.Row {
        let label = [account, gauge.label].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        return PanelModel.Row(account: account, label: label, percent: gauge.percent, value: gauge.text,
                       resetText: PanelFormat.resetText(gauge.resetsAt, now: now),
                       resetsAt: gauge.resetsAt, expired: gauge.expired)
    }
}
