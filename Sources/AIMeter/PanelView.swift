import AppKit
import SwiftUI

/// The live view-model `PanelView` observes. AppDelegate rebuilds `model` and
/// `sparkline` after every fetch (see `AppDelegate.refreshUI`); the `on...`
/// closures are wired once, in `AppDelegate.wirePanelActions`, so this type
/// itself has no notion of how its actions are actually carried out.
@MainActor
final class PanelState: ObservableObject {
    let nav = PanelNav()
    let store: SettingsStore
    @Published var model: PanelModel = .empty(primaryId: "claude")
    @Published var sparkline: [(Date, Double)] = []
    @Published var lastRefresh: Date?
    @Published var refreshIntervalSeconds: Int = 60
    @Published var language: Lang = .system
    @Published var loginEnabled: Bool = false
    @Published var animate: Bool = true
    @Published var draft: RecipeDraft?
    @Published var builtinDraft: AddDraft?

    init(store: SettingsStore? = nil) {
        self.store = store ?? SettingsStore()
        self.draft = nil
        self.builtinDraft = nil
    }

    var onRefreshAll: () -> Void = {}
    var onRefreshProvider: (String) -> Void = { _ in }
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}
    var onPickLanguage: (Lang) -> Void = { _ in }
    var onPickInterval: (Int) -> Void = { _ in }
    var onToggleLogin: () -> Void = {}
    var onOpenDebug: () -> Void = {}
    var onOpenAbout: () -> Void = {}
    var onCursorOpen: () -> Void = {}
    var onOpenReport: () -> Void = {}
    var onDismissalSuspended: (Bool) -> Void = { _ in }
    var onContentHeight: (CGFloat) -> Void = { _ in }
}

struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private var panelAppVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
}

private let intervalChoices = [30, 60, 300, 900, 0]
private func intervalLabel(_ secs: Int) -> String {
    secs == 0 ? L.t("m.onopen") : (secs < 60 ? L.t("m.seconds", secs) : L.t("m.minutes", secs / 60))
}

/// The floating card panel's content, top to bottom: header, primary card
/// (hero ring + chips + sparkline), the fixed-order secondary cards, footer.
/// Pure SwiftUI so the same view drives both the live panel (`PanelWindow`)
/// and the offscreen `--panel` renderer in main.swift.
struct PanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject private var nav: PanelNav
    var requestClose: () -> Void = {}
    /// True only for the offscreen `--panel` renderer. The live panel gets its
    /// translucent ground from the NSPanel's own `NSVisualEffectView`
    /// (`PanelWindow.swift`) and must stay clear here so that shows through;
    /// an offscreen render has no live desktop behind it for vibrancy to
    /// blend with, so it substitutes a plain opaque fill instead of the flat
    /// mid-grey a materialless capture would otherwise show.
    var opaqueBackground: Bool = false

    init(state: PanelState, requestClose: @escaping () -> Void = {},
         opaqueBackground: Bool = false) {
        self.state = state
        self._nav = ObservedObject(wrappedValue: state.nav)
        self.requestClose = requestClose
        self.opaqueBackground = opaqueBackground
    }

    private var animated: Bool {
        state.animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        Group {
            if let page = nav.stack.last { settingsPage(page) }
            else { usagePage }
        }
        .frame(width: 372)
        .frame(maxHeight: 720)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PanelHeightKey.self,
                                   value: panelPreferredHeight(for: nav.stack.last)
                                        ?? geometry.size.height)
        })
        .background(opaqueBackground ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .background(shortcuts)
        .onPreferenceChange(PanelHeightKey.self) { state.onContentHeight($0) }
        .onExitCommand(perform: handleEscape)
    }

    private var usagePage: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PrimaryCardView(primary: state.model.primary, sparkline: state.sparkline,
                                    animated: animated,
                                    onCheck: { state.onRefreshProvider(state.model.primary.providerId) })
                    ForEach(Array(state.model.secondaries.enumerated()), id: \.offset) { _, card in
                        SecondaryCardView(card: card,
                                          onCheck: { state.onRefreshProvider(card.id) },
                                          onCursorOpen: state.onCursorOpen)
                    }
                }
                .padding(12)
            }
            footer
        }
    }

    @ViewBuilder
    private func settingsPage(_ page: SettingsPage) -> some View {
        switch page {
        case .root:
            SettingsRootView(state: state, store: state.store)
        case .services:
            ServicesView(state: state, store: state.store)
        case .catalogue:
            CatalogueView(state: state, store: state.store)
        case .custom:
            CustomRecipeView(state: state, store: state.store)
        case .add(let kind):
            AddBuiltinView(providerID: kind, state: state, store: state.store)
        case .menuBar:
            MenuBarPageView(state: state, store: state.store)
        case .general:
            GeneralPageView(state: state, store: state.store)
        case .history:
            HistoryPageView(state: state, store: state.store)
        }
    }

    private func handleEscape() {
        switch escapeAction(stackDepth: nav.stack.count) {
        case .pop: nav.pop()
        case .close: requestClose()
        }
    }

    /// Zero-size, invisible buttons purely so ⌘R/⌘Q work while the panel is
    /// key - the panel has no NSMenu of its own to carry the key equivalents.
    private var shortcuts: some View {
        ZStack {
            Button("") { state.onRefreshAll() }.keyboardShortcut("r", modifiers: .command)
            Button("") { state.onQuit() }.keyboardShortcut("q", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    private var header: some View {
        HStack {
            Text("AIMeter")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
            Spacer()
            Text(PanelFormat.updatedLine(time: state.lastRefresh, intervalSeconds: state.refreshIntervalSeconds))
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Palette.text(0.62)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 2) {
                FooterIconButton(systemName: "arrow.clockwise", help: L.t("m.refresh")) { state.onRefreshAll() }
                FooterIconButton(systemName: "chart.xyaxis.line", help: L.t("m.history")) { state.onOpenHistory() }
                FooterIconButton(systemName: "gearshape", help: L.t("pn.settings")) { state.onOpenSettings() }
                FooterIconButton(systemName: "power", help: L.t("m.quit")) { state.onQuit() }
                Spacer()
                moreMenu
                    .help(L.t("pn.more"))
            }
            .padding(.horizontal, 8)
            Text("v\(panelAppVersion)")
                .font(.system(size: 9))
                .foregroundStyle(Color(nsColor: Palette.text(0.42)))
        }
        .padding(.bottom, 8)
    }

    /// Pops the same secondary items `AppDelegate.rebuildMenu` puts at the
    /// bottom of the NSMenu fallback - language, interval, start at login,
    /// debug folder, about - as a real menu (SwiftUI's `Menu` is backed by an
    /// actual `NSMenu` on macOS), so nothing from the old dropdown is lost.
    private var moreMenu: some View {
        Menu {
            Menu(L.t("m.language")) {
                ForEach(Lang.allCases, id: \.self) { lang in
                    Button {
                        state.onPickLanguage(lang)
                    } label: {
                        if state.language == lang { Label(lang.displayName, systemImage: "checkmark") }
                        else { Text(lang.displayName) }
                    }
                }
            }
            Menu(L.t("m.interval")) {
                ForEach(intervalChoices, id: \.self) { secs in
                    Button {
                        state.onPickInterval(secs)
                    } label: {
                        if state.refreshIntervalSeconds == secs { Label(intervalLabel(secs), systemImage: "checkmark") }
                        else { Text(intervalLabel(secs)) }
                    }
                }
            }
            Toggle(L.t("m.login"), isOn: Binding(
                get: { state.loginEnabled },
                set: { _ in state.onToggleLogin() }))
            Divider()
            Button(L.t("m.debug")) { state.onOpenDebug() }
            Button(L.t("m.about")) { state.onOpenAbout() }
        } label: {
            Text("…").font(.system(size: 13, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct FooterIconButton: View {
    var systemName: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Primary card

private struct PrimaryCardView: View {
    var primary: PanelModel.Primary
    var sparkline: [(Date, Double)]
    var animated: Bool
    var onCheck: () -> Void

    @State private var hovering = false
    @State private var flashing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: stateColour(primary.state))).frame(width: 8, height: 8)
                Text(primary.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let ageText = primary.ageText {
                    Text(ageText).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                }
            }

            if let msg = primary.failureMessage {
                Text(msg).font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
            } else if !primary.hasData {
                Text(L.t("m.loading")).font(.system(size: 12)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
            } else {
                HStack(alignment: .center, spacing: 14) {
                    RingGauge(percent: primary.heroPercent, animated: animated)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(heroNumber)
                                .font(.system(size: 34, weight: .bold)).monospacedDigit()
                            if primary.heroPercent != nil {
                                Text("%").font(.system(size: 14)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                            }
                        }
                        Text(windowLine).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    }
                    Spacer(minLength: 0)
                }
                if !primary.chips.isEmpty {
                    ChipsFlow(chips: primary.chips)
                }
                SparklineView(samples: sparkline, ink: Color(nsColor: Palette.colour(Palette.ink)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: Palette.colour(Palette.ink)).opacity(flashing ? 0.08 : 0))
        )
        .offset(y: hovering ? -1 : 0)
        .shadow(color: .black.opacity(hovering ? 0.20 : 0), radius: hovering ? 6 : 0, y: hovering ? 2 : 0)
        .onHover { hovering = $0 }
        .help(tooltip)
        .onTapGesture {
            onCheck()
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { flashing = false }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: flashing)
    }

    private var heroNumber: String {
        guard let pct = primary.heroPercent else { return primary.hasData ? "—" : "—" }
        return String(format: "%.0f", pct)
    }

    private var windowLine: String {
        let parts: [String?] = [primary.windowLabel.isEmpty ? nil : primary.windowLabel, primary.resetText]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private var tooltip: String {
        guard let at = primary.resetsAt else { return primary.windowLabel }
        return exactDateTime(at)
    }
}

/// One remaining gauge of the primary reading: a 12pt conic mini-ring, then
/// "label · **value** reset" as a single line - order is the caller's
/// (`PanelModel` already sorted longWindow, modelWindow, other). Rows of a
/// fixed three-per-line used to wrap a two-line chip mid-chip whenever a
/// long label didn't fit; a single line per chip laid out by `FlowLayout`
/// wraps whole chips instead, never breaking one across two lines.
private struct ChipsFlow: View {
    var chips: [PanelModel.Chip]

    var body: some View {
        FlowLayout(spacing: 12, lineSpacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                ChipView(chip: chip)
            }
        }
    }
}

/// A left-to-right, top-to-bottom wrap layout: place children until one
/// would not fit the available width, then start a new line. SwiftUI's
/// `Layout` protocol (macOS 13+, this app targets 14) is exactly this - no
/// GeometryReader-plus-offset trick needed, and each child is measured at
/// its own natural size rather than squeezed, which is what keeps a chip's
/// line from breaking internally.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if i > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if i > 0, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct ChipView: View {
    var chip: PanelModel.Chip

    var body: some View {
        HStack(spacing: 5) {
            MiniRing(percent: chip.percent)
            HStack(spacing: 3) {
                Text(chip.label).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                Text("·").font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                Text(chip.value).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                if let r = chip.resetText {
                    Text(r).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.42)))
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .help(chip.resetsAt.map(exactDateTime) ?? chip.label)
    }
}

private struct MiniRing: View {
    var percent: Double?

    private var colour: Color {
        guard let percent else { return Color(nsColor: Palette.text(0.42)) }
        switch RingIcon.colourBand(percent) {
        case .ink: return Color(nsColor: Palette.colour(Palette.ink))
        case .warn: return Color(nsColor: Palette.colour(Palette.warn))
        case .alarm: return Color(nsColor: Palette.colour(Palette.alarm))
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color(nsColor: Palette.colour(Palette.track)), lineWidth: 2)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent ?? 0)) / 100))
                .stroke(AngularGradient(colors: [colour.opacity(0.4), colour], center: .center),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
    }
}

/// The primary card's 64pt hero ring. Sweeps from 0 on appear/refresh when
/// `animated`, using an ease-out curve of the same shape as `RingIcon.eased`
/// (fast start, gentle arrival) - the icon's own sweep is drawn frame-by-frame
/// through `RingAnimator` because it renders to a bitmap `NSImage`, but this
/// is SwiftUI, so `Animation.timingCurve` reproduces the same curve natively
/// instead of duplicating that per-frame machinery.
private struct RingGauge: View {
    var percent: Double?
    var animated: Bool
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color(nsColor: Palette.colour(Palette.track)), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, shown)) / 100))
                .stroke(colour, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 64, height: 64)
        .onAppear { apply() }
        .onChange(of: percent) { _, _ in apply() }
    }

    private var colour: Color {
        guard let percent else { return Color(nsColor: Palette.text(0.42)) }
        switch RingIcon.colourBand(percent) {
        case .ink: return Color(nsColor: Palette.colour(Palette.ink))
        case .warn: return Color(nsColor: Palette.colour(Palette.warn))
        case .alarm: return Color(nsColor: Palette.colour(Palette.alarm))
        }
    }

    private func apply() {
        let target = percent ?? 0
        guard animated else { shown = target; return }
        shown = 0
        withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: 0.5)) { shown = target }
    }
}

// MARK: - Secondary cards

private struct SecondaryCardView: View {
    var card: PanelModel.SecondaryCard
    var onCheck: () -> Void
    var onCursorOpen: () -> Void

    @State private var hovering = false
    @State private var flashing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: stateColour(card.state))).frame(width: 7, height: 7)
                Text(card.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let badge = card.badge {
                    Text(badge).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                }
            }
            if let msg = card.failureMessage, card.state == .failure {
                Text(msg).font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Palette.colour(Palette.alarm)))
            } else if card.linkOnly {
                HStack {
                    Text(card.failureMessage ?? L.t("x.cursor.link"))
                        .font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    Spacer()
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Palette.text(0.62)))
                }
                .onTapGesture { onCursorOpen() }
            } else {
                ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
                    RowView(row: row)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(card.opacity)
        .background(CardBackground(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: Palette.colour(Palette.ink)).opacity(flashing ? 0.08 : 0)))
        .offset(y: hovering ? -1 : 0)
        .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: hovering ? 5 : 0, y: hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .help(card.rows.compactMap(\.resetsAt).first.map(exactDateTime) ?? card.title)
        .onTapGesture {
            guard !card.linkOnly else { return }
            onCheck()
            flashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { flashing = false }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: flashing)
    }
}

private struct RowView: View {
    var row: PanelModel.Row

    var body: some View {
        if row.label.isEmpty && row.percent == nil {
            // An informational line (DeepSeek's peak/off-peak note, Local AI's
            // memory line, ...): text only, no meter.
            Text(row.value).font(.system(size: 10)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
        } else {
            HStack(spacing: 6) {
                Text(row.label).font(.system(size: 11)).foregroundStyle(Color(nsColor: Palette.text(0.62)))
                    .lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                if let pct = row.percent {
                    Meter(percent: pct)
                    Text(String(format: "%.0f%%", pct)).font(.system(size: 11)).monospacedDigit()
                } else {
                    Spacer(minLength: 0)
                    Text(row.value).font(.system(size: 11)).monospacedDigit()
                }
                if let r = row.resetText {
                    Text(r).font(.system(size: 9)).foregroundStyle(Color(nsColor: Palette.text(0.42))).lineLimit(1)
                }
            }
        }
    }
}

/// A secondary card's row meter (Codex, OpenRouter, ...). Deliberately ink
/// below 70% rather than the traffic-light green `panelGaugeStyle`'s
/// untyped `.other` path used to fill it with - the same colour rule
/// `RingIcon.colourBand` and the primary card's `MiniRing`/`RingGauge`
/// already use, via the amber/red bands only at 70%/90% and up. A card full
/// of green bars read as "everything is great" when most of them were
/// simply nowhere near their limit, which is not the same claim.
private struct Meter: View {
    var percent: Double

    private var fill: NSColor {
        switch RingIcon.colourBand(percent) {
        case .ink: return Palette.colour(Palette.ink)
        case .warn: return Palette.colour(Palette.warn)
        case .alarm: return Palette.colour(Palette.alarm)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let filled = max(percent > 0 ? 2 : 0, min(w, w * CGFloat(percent) / 100))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: Palette.colour(Palette.track)))
                Capsule().fill(Color(nsColor: fill)).frame(width: filled)
            }
        }
        .frame(height: 5)
        .frame(minWidth: 50, maxWidth: 90)
    }
}

private struct CardBackground: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private func exactDateTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = L.locale
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: d)
}
