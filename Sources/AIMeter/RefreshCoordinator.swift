import Foundation

enum RefreshReason: Sendable, Equatable {
    case timer, manual, reload, launch, languageChange
}

/// Per-provider/account refresh orchestration: coalesces manual requests,
/// rejects stale configuration generations, publishes each provider as soon as
/// it finishes, and enforces the manual-only interval invariant.
actor RefreshCoordinator {
    struct Status: Sendable {
        var refreshing: Set<String> = []
        var dropped: Int = 0
        var byProvider: [String: Bool] = [:]
    }

    struct PublishEvent: Sendable {
        var providerID: String
        var readings: [Reading]
        var generation: Int
        var dropped: Bool
        var notices: [String] = []
    }

    private struct Slot {
        var task: Task<Void, Never>?
        var queuedManual = false
        var generation: Int
    }

    private var slots: [String: Slot] = [:]
    private var configGeneration = 0
    private var status = Status()
    private var lastFetched: [String: Date] = [:]
    private var readings: [String: [Reading]] = [:]
    private var agyPause: [String: AgyAccountPauseState] = [:]
    private var droppedSincePublish: [String: Int] = [:]
    private var testBudgetSeconds: Double?
    private let agyConfigDir: String

    init(agyConfigDir: String = Config.dir) {
        self.agyConfigDir = agyConfigDir
        agyPause = AgyPauseStore.load(configDir: agyConfigDir)
    }

    /// Called when the shared config store bumps revision.
    func setGeneration(_ generation: Int) {
        configGeneration = generation
    }

    func statusSnapshot() -> Status { status }

    func readingsSnapshot() -> [String: [Reading]] { readings }

    func lastFetchedSnapshot() -> [String: Date] { lastFetched }

    func agyPauseSnapshot() -> [String: AgyAccountPauseState] { agyPause }

    func setTestBudget(_ seconds: Double?) { testBudgetSeconds = seconds }

    /// Main entry: schedule fetches for the given providers.
    func request(reason: RefreshReason,
                 providerIDs: [String]?,
                 providers: [Provider],
                 cfg: Config,
                 generation: Int,
                 publish: @escaping @Sendable (PublishEvent) -> Void) {
        let list = providerIDs.map { ids in providers.filter { ids.contains($0.id) } } ?? providers
        for provider in list {
            let accounts = accountNames(for: provider, cfg: cfg)
            if accounts.isEmpty {
                schedule(provider: provider, account: nil, reason: reason, cfg: cfg,
                         generation: generation, publish: publish)
            } else {
                for account in accounts {
                    schedule(provider: provider, account: account, reason: reason, cfg: cfg,
                             generation: generation, publish: publish)
                }
            }
        }
    }

    private func accountNames(for provider: Provider, cfg: Config) -> [String] {
        let specs = cfg.accounts[provider.id] ?? []
        let enabled = specs.filter(\.enabled).map(\.name)
        return enabled.isEmpty ? [] : enabled
    }

    private func slotKey(_ providerID: String, _ account: String?) -> String {
        providerID + "\u{1}" + (account ?? "*")
    }

    private func schedule(provider: Provider,
                          account: String?,
                          reason: RefreshReason,
                          cfg: Config,
                          generation: Int,
                          publish: @escaping @Sendable (PublishEvent) -> Void) {
        let key = slotKey(provider.id, account)
        let manualOnly = cfg.interval(provider.id) == 0
        if manualOnly, reason != .manual { return }

        if var slot = slots[key], let task = slot.task, !task.isCancelled {
            if reason == .manual {
                slot.queuedManual = true
                slots[key] = slot
            }
            return
        }

        let budget = testBudgetSeconds ?? (provider.id == "agy" ? 120.0 : 45.0)
        status.refreshing.insert(provider.id)
        status.byProvider[provider.id] = true

        let task = Task {
            await self.runSlot(provider: provider, account: account, reason: reason,
                               cfg: cfg, generation: generation, budget: budget,
                               publish: publish)
        }
        slots[key] = Slot(task: task, queuedManual: false, generation: generation)
    }

    private func runSlot(provider: Provider,
                         account: String?,
                         reason: RefreshReason,
                         cfg: Config,
                         generation: Int,
                         budget: Double,
                         publish: @escaping @Sendable (PublishEvent) -> Void) async {
        let key = slotKey(provider.id, account)
        defer {
            slots[key]?.task = nil
            status.refreshing.remove(provider.id)
            status.byProvider[provider.id] = slots.contains { $0.key.hasPrefix(provider.id + "\u{1}") && $0.value.task != nil }
            if slots[key]?.queuedManual == true {
                slots[key]?.queuedManual = false
                schedule(provider: provider, account: account, reason: .manual, cfg: cfg,
                         generation: configGeneration, publish: publish)
            }
        }

        let manual = reason == .manual
        let host = endpointHost(for: provider.id, cfg: cfg)
        let accountLabel = account ?? "*"
        var notices: [String] = []

        if manual {
            let rateLimited = RateLimit.shouldSkip(host: host, account: accountLabel,
                                                   reason: .timer, now: Date())
            let agyBackoff = provider.id == "agy" && account.map { agyBackoffActive($0) } == true
            if rateLimited || agyBackoff {
                notices.append(L.t("m.retrying.early"))
            }
        } else if RateLimit.shouldSkip(host: host, account: accountLabel, reason: reason) {
            return
        }

        if let agy = provider as? AgyProvider, let account {
            let pauseKey = AgyPauseStore.accountKey(account)
            let state = agyPause[pauseKey] ?? AgyAccountPauseState()
            agy.pauseState = state
            agy.onPauseTransition = { transition in
                Task { await self.applyAgyPauseTransition(account: account, transition: transition) }
            }
        }

        let result: [Reading] = await withTimeout(budget, {
            await provider.fetchAll(manual: manual)
        }, onTimeout: {
            [Reading.failed(provider.id, provider.title, account, L.t("m.timeout"))]
        })

        if let agy = provider as? AgyProvider, let account {
            let pauseKey = AgyPauseStore.accountKey(account)
            agyPause[pauseKey] = agy.pauseState
            AgyPauseStore.save(agyPause, configDir: agyConfigDir)
            agy.onPauseTransition = nil
        }

        guard !Task.isCancelled else { return }

        let slotGen = slots[key]?.generation ?? generation
        if slotGen != configGeneration {
            status.dropped += 1
            droppedSincePublish[provider.id, default: 0] += 1
            var dropNotices = notices
            dropNotices.append(L.t("m.dropped"))
            publish(PublishEvent(providerID: provider.id, readings: [],
                               generation: slotGen, dropped: true, notices: dropNotices))
            return
        }

        var filtered = result
        if let account { filtered = result.filter { $0.account == account } }
        if filtered.isEmpty, let account, manual {
            filtered = [.failed(provider.id, provider.title, account, L.t("e.connplain"))]
        }

        let merged = filtered.map { new in
            let prev = readings[provider.id]?.first { $0.account == new.account }
            return Reading.merge(previous: prev, next: new)
        }

        if var existing = readings[provider.id] {
            for reading in merged {
                if let index = existing.firstIndex(where: { $0.account == reading.account }) {
                    existing[index] = reading
                } else {
                    existing.append(reading)
                }
            }
            readings[provider.id] = existing
        } else {
            readings[provider.id] = merged
        }
        lastFetched[provider.id] = Date()
        droppedSincePublish[provider.id] = 0

        publish(PublishEvent(providerID: provider.id, readings: merged,
                           generation: slotGen, dropped: false, notices: notices))
    }

    private func agyBackoffActive(_ account: String, now: Date = Date()) -> Bool {
        let key = AgyPauseStore.accountKey(account)
        guard let until = agyPause[key]?.backoff?.until else { return false }
        return now < until
    }

    private func applyAgyPauseTransition(account: String, transition: AgyPauseTransition) {
        let key = AgyPauseStore.accountKey(account)
        var entry = agyPause[key] ?? AgyAccountPauseState()
        switch transition {
        case .paused:
            entry.paused = true
        case .backoff(let state):
            entry.backoff = state
        case .clear:
            entry.paused = false
            entry.backoff = nil
        }
        agyPause[key] = entry
        AgyPauseStore.save(agyPause, configDir: agyConfigDir)
    }

    private func endpointHost(for providerID: String, cfg: Config) -> String {
        if let recipe = cfg.recipes.first(where: { $0.id == providerID }),
           let base = recipe.fetch.baseURL,
           let host = URL(string: base)?.host {
            return host
        }
        switch providerID {
        case "claude": return "api.anthropic.com"
        case "openrouter": return "openrouter.ai"
        case "deepseek": return "api.deepseek.com"
        default: return providerID
        }
    }

    /// Test helper: inject fake readings without fetching.
    func setReadings(_ value: [String: [Reading]]) {
        readings = value
    }

    func resetForTests() {
        slots.values.forEach { $0.task?.cancel() }
        slots = [:]
        status = Status()
        readings = [:]
        lastFetched = [:]
        configGeneration = 0
        agyPause = [:]
        droppedSincePublish = [:]
        testBudgetSeconds = nil
    }
}
