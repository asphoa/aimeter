import Foundation

/// Per-account Antigravity print pause/backoff state owned by RefreshCoordinator.
struct AgyAccountPauseState: Codable, Sendable {
    var paused = false
    var backoff: AgyBackoffState?
}

enum AgyPauseTransition: Sendable {
    case paused
    case backoff(AgyBackoffState)
    case clear
}

/// Persists agy pause/backoff in one JSON file; migrates legacy marker/backoff files.
enum AgyPauseStore {
    private static let fileName = "agy-pause-state.json"

    static func path(in configDir: String = Config.dir) -> String {
        configDir + "/" + fileName
    }

    static func load(configDir: String = Config.dir) -> [String: AgyAccountPauseState] {
        migrateLegacyFiles(configDir: configDir)
        let path = self.path(in: configDir)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: AgyAccountPauseState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ states: [String: AgyAccountPauseState], configDir: String = Config.dir) {
        guard let data = try? JSONEncoder().encode(states) else { return }
        try? writePrivate(data, to: path(in: configDir))
    }

    static func accountKey(_ account: String) -> String { "agy\u{1}" + account }

    private static func migrateLegacyFiles(configDir: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: configDir) else { return }
        var states = loadWithoutMigration(configDir: configDir)
        var changed = false

        for name in names {
            if name.hasPrefix("agy-print-paused-"), name.hasSuffix(".marker") {
                let slug = String(name.dropFirst("agy-print-paused-".count).dropLast(".marker".count))
                let account = unslug(slug)
                let key = accountKey(account)
                var entry = states[key] ?? AgyAccountPauseState()
                entry.paused = true
                states[key] = entry
                try? fm.removeItem(atPath: configDir + "/" + name)
                changed = true
            } else if name.hasPrefix("agy-print-backoff-"), name.hasSuffix(".json") {
                let slug = String(name.dropFirst("agy-print-backoff-".count).dropLast(".json".count))
                let account = unslug(slug)
                let key = accountKey(account)
                let legacyPath = configDir + "/" + name
                if let data = try? Data(contentsOf: URL(fileURLWithPath: legacyPath)),
                   let backoff = try? JSONDecoder().decode(AgyBackoffState.self, from: data) {
                    var entry = states[key] ?? AgyAccountPauseState()
                    entry.backoff = backoff
                    states[key] = entry
                }
                try? fm.removeItem(atPath: legacyPath)
                changed = true
            }
        }
        if changed { save(states, configDir: configDir) }
    }

    private static func loadWithoutMigration(configDir: String) -> [String: AgyAccountPauseState] {
        let path = self.path(in: configDir)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: AgyAccountPauseState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func unslug(_ slug: String) -> String {
        slug.replacingOccurrences(of: "_", with: " ")
    }
}
