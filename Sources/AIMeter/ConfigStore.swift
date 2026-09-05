import Foundation

/// The single owner of the live `Config` snapshot. Every UI surface and the
/// refresh coordinator read the same revision; saves are field-level mutations
/// that roll back in memory when persistence fails.
@MainActor
final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()

    @Published private(set) var cfg: Config
    @Published private(set) var revision: Int = 0
    /// One-shot notice when integers were clamped to a valid range.
    @Published var rangeNotice: String?

    private var lastSaved: Config

    init(initial: Config? = nil, rangeNotice: String? = nil) {
        if let initial {
            cfg = initial
            lastSaved = initial
            self.rangeNotice = rangeNotice
        } else {
            let loaded = Config.load()
            cfg = loaded.config
            lastSaved = loaded.config
            self.rangeNotice = loaded.rangeNotice
        }
    }

    /// Applies a field-level change, validates, persists, then bumps `revision`.
    /// On failure the in-memory copy reverts to `lastSaved` and the error is
    /// re-thrown for the caller to surface.
    func mutate(_ change: (inout Config) -> Void) throws {
        var draft = cfg
        change(&draft)
        let (validated, notice) = Config.validated(draft)
        draft = validated
        try draft.save()
        cfg = draft
        lastSaved = draft
        revision += 1
        if let notice {
            rangeNotice = L.t("s.range.clamped", notice)
        }
        NotificationCenter.default.post(name: SettingsStore.changed, object: nil)
    }

    /// Cosmetic-only changes (colour overrides) post `restyled` instead.
    func mutateCosmetic(_ change: (inout Config) -> Void) throws {
        var draft = cfg
        change(&draft)
        let (validated, _) = Config.validated(draft)
        draft = validated
        try draft.save()
        cfg = draft
        lastSaved = draft
        revision += 1
        Palette.overrides = cfg.colours
        NotificationCenter.default.post(name: SettingsStore.restyled, object: nil)
    }

    /// Reload from disk after an external change (or startup).
    func reloadFromDisk() {
        let loaded = Config.load()
        cfg = loaded.config
        lastSaved = loaded.config
        revision += 1
        rangeNotice = loaded.rangeNotice
        Palette.overrides = cfg.colours
        L.current = cfg.language
    }

    func clearRangeNotice() { rangeNotice = nil }
}
