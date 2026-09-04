import Foundation

/// Shared reset-time phrasing for the card panel: a future `resetsAt` reads
/// "%@ until reset" (the bare magnitude, `Fmt.span`, so the template supplies
/// the only direction word); a past one - the window already ended - reads
/// "ended %@ ago" via the existing `m.ended`/`Fmt.relative`, matching
/// PanelRows' own expired-window phrasing.
enum PanelFormat {
    static func resetText(_ resetsAt: Date?, now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        if resetsAt <= now { return L.t("m.ended", Fmt.relative(resetsAt)) }
        return L.t("pn.reset.in", Fmt.span(resetsAt, now: now))
    }

    /// The header's own interval, using the panel's private wording only when
    /// the primary provider is not polled at all.
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

/// The panel's pure content model: everything `PanelView` draws, built once
/// per fetch from `[String: [Reading]]` + `Config` with no AppKit/SwiftUI
/// import in sight, so it is testable exactly like `RingIcon.RingModel`.
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
        var label: String
        var percent: Double?
        var value: String
        var resetText: String?
        var resetsAt: Date?
        var expired: Bool = false
    }

    struct Primary: Equatable {
        var providerId: String
        var title: String
        var hasData: Bool
        var state: ReadingState
        /// Right-aligned age/plan line: Claude's "reads usage without
        /// spending quota", or a snapshot provider's age string.
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
        /// Cursor: link-only, no meters at all - render the line, not a track.
        var linkOnly: Bool = false
        /// Local AI at `.off`: the whole card sits at 60% opacity.
        var opacity: Double = 1.0
    }

    var primary: Primary
    var secondaries: [SecondaryCard]

    static func empty(primaryId: String) -> PanelModel {
        PanelModel(primary: Primary(providerId: primaryId,
                                    title: PanelModelBuilder.title(for: primaryId),
                                    hasData: false, state: .off, ageText: nil,
                                    heroPercent: nil, heroText: "—", windowLabel: "",
                                    resetText: nil, resetsAt: nil, failureMessage: nil, chips: []),
                  secondaries: [])
    }
}

/// Builds `PanelModel` from live readings. Deliberately not `@MainActor`:
/// nothing here touches AppKit, and the test suite's `Runner.main` calls it
/// directly with no actor hop.
enum PanelModelBuilder {
    static func title(for id: String) -> String {
        if let kind = ProviderKind.find(id) { return kind.title }
        switch id {
        case "local": return L.t("p.local")
        case "cursor": return L.t("p.cursor")
        default: return id
        }
    }

    /// The fixed secondary order this release specifies: Codex, OpenRouter,
    /// then the compact grid (DeepSeek, Antigravity, Local AI, Cursor).
    static let fixedSecondaryOrder = ["codex", "openrouter", "deepseek", "agy", "local", "cursor"]

    static func build(readings: [String: [Reading]], cfg: Config, now: Date = Date()) -> PanelModel {
        let primaryId = cfg.menuBar.primary
        return PanelModel(primary: buildPrimary(id: primaryId, readings: readings, now: now),
                          secondaries: buildSecondaries(readings: readings, primaryId: primaryId, now: now))
    }

    private static func buildPrimary(id: String, readings: [String: [Reading]], now: Date) -> PanelModel.Primary {
        let title = title(for: id)
        guard let raw = readings[id], !raw.isEmpty else {
            return PanelModel.Primary(providerId: id, title: title, hasData: false, state: .off,
                                      ageText: nil, heroPercent: nil, heroText: "—", windowLabel: "",
                                      resetText: nil, resetsAt: nil, failureMessage: nil, chips: [])
        }
        let rows = Reading.asOfNow(raw)
        let state = rows.map(\.state).max() ?? .off
        if let failed = rows.first(where: { $0.state == .failure }) {
            return PanelModel.Primary(providerId: id, title: title, hasData: true, state: .failure,
                                      ageText: nil, heroPercent: nil, heroText: "—", windowLabel: "",
                                      resetText: nil, resetsAt: nil,
                                      failureMessage: failed.lines.first ?? L.t("e.connplain"),
                                      chips: [])
        }
        var gauges = rows.flatMap(\.gauges)
        var hero: Gauge? = nil
        if let idx = gauges.firstIndex(where: { $0.kind == .shortWindow }) {
            hero = gauges.remove(at: idx)
        }
        let ageText: String? = {
            if id == "claude" { return L.t("pn.free") }
            if let s = rows.first?.snapshotAt { return L.t("m.snapshot", Fmt.relative(s)) }
            return nil
        }()
        return PanelModel.Primary(
            providerId: id, title: title, hasData: true, state: state, ageText: ageText,
            heroPercent: hero?.percent, heroText: hero?.text ?? "—", windowLabel: hero?.label ?? "",
            resetText: PanelFormat.resetText(hero?.resetsAt, now: now), resetsAt: hero?.resetsAt,
            failureMessage: nil, chips: buildChips(gauges, now: now))
    }

    /// Chip order: unscoped weekly (`.longWindow`) first, then every
    /// per-model weekly entry (`.modelWindow`) sorted by label, then `.other`
    /// (extra usage, a money balance, anything untyped) last.
    private static func buildChips(_ gauges: [Gauge], now: Date) -> [PanelModel.Chip] {
        let long = gauges.filter { $0.kind == .longWindow }
        let models = gauges.filter { $0.kind == .modelWindow }.sorted { $0.label < $1.label }
        let other = gauges.filter { $0.kind == .other }
        return (long + models + other).map { g in
            PanelModel.Chip(kind: g.kind, label: g.label, percent: g.percent, value: g.text,
                            resetText: PanelFormat.resetText(g.resetsAt, now: now), resetsAt: g.resetsAt)
        }
    }

    private static func buildSecondaries(readings: [String: [Reading]], primaryId: String,
                                         now: Date) -> [PanelModel.SecondaryCard] {
        var out: [PanelModel.SecondaryCard] = []
        for id in fixedSecondaryOrder where id != primaryId {
            if let card = buildSecondaryCard(id: id, readings: readings, now: now) { out.append(card) }
        }
        let covered = Set(fixedSecondaryOrder + [primaryId])
        for id in readings.keys.sorted() where !covered.contains(id) {
            if let card = buildSecondaryCard(id: id, readings: readings, now: now) { out.append(card) }
        }
        return out
    }

    private static func buildSecondaryCard(id: String, readings: [String: [Reading]],
                                           now: Date) -> PanelModel.SecondaryCard? {
        guard let raw = readings[id], !raw.isEmpty else { return nil }
        let rows = Reading.asOfNow(raw)
        let title = title(for: id)
        let state = rows.map(\.state).max() ?? .off

        if let failed = rows.first(where: { $0.state == .failure }) {
            return PanelModel.SecondaryCard(id: id, title: title, state: .failure, badge: nil, rows: [],
                                            failureMessage: failed.lines.first ?? L.t("e.connplain"))
        }
        if id == "cursor" {
            return PanelModel.SecondaryCard(id: id, title: title, state: state, badge: nil, rows: [],
                                            failureMessage: rows.first?.lines.first, linkOnly: true)
        }

        var allRows: [PanelModel.Row] = []
        for r in rows {
            allRows.append(contentsOf: r.gauges.map { toRow($0, now: now) })
            allRows.append(contentsOf: r.lines.map { PanelModel.Row(label: "", percent: nil, value: $0, resetText: nil) })
        }
        let badge = rows.first?.snapshotAt.map { L.t("m.snapshot", Fmt.relative($0)) }
        let opacity: Double = (id == "local" && state == .off) ? 0.6 : 1.0
        return PanelModel.SecondaryCard(id: id, title: title, state: state, badge: badge,
                                        rows: allRows, failureMessage: nil, opacity: opacity)
    }

    private static func toRow(_ g: Gauge, now: Date) -> PanelModel.Row {
        PanelModel.Row(label: g.label, percent: g.percent, value: g.text,
                       resetText: PanelFormat.resetText(g.resetsAt, now: now), resetsAt: g.resetsAt,
                       expired: g.expired)
    }
}
