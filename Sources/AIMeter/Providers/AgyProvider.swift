import Foundation

/// Antigravity quota - one row per account HOME, so a pool of accounts shows
/// up as several rows.
///
/// v1.0.28: the main path is the CLI's own read-only print-mode command,
/// `agy -p "/usage" --output-format json` (see `AgyPrint`) - measured to cost
/// no quota and take ~4s, so it is safe on a timer, scheduled or manual
/// alike. The pty screen-scrape (`AgyTUI`) that used to be the only source is
/// now the manual-only fallback for when print mode fails or is switched
/// off. The direct HTTP call this file once made to Google's internal quota
/// endpoint is gone: it was dead code (`~/.gemini/antigravity-cli/
/// antigravity-oauth-token`, the file it read, does not exist - credentials
/// live in the keychain) that was never reachable with its config flag at
/// its default of off.

/// On-disk paths for print-mode pause markers and the last snapshot. Injectable
/// so tests can use a temp directory instead of `~/.config/aimeter/`.
struct AgyFileLocations: Sendable {
    let configDir: String

    func snapshotPath(_ account: String) -> String {
        configDir + "/agy-print-" + slug(account) + ".json"
    }

    func attemptPath(_ account: String) -> String {
        configDir + "/agy-print-attempt-" + slug(account) + ".json"
    }

    func backoffPath(_ account: String) -> String {
        configDir + "/agy-print-backoff-" + slug(account) + ".json"
    }

    func pauseMarkerPath(_ account: String) -> String {
        configDir + "/agy-print-paused-" + slug(account) + ".marker"
    }

    private func slug(_ account: String) -> String {
        String(account.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
    }

    static let `default` = AgyFileLocations(configDir: Config.dir)
}

struct AgyBackoffState: Codable {
    var failures: Int
    var until: Date
}

final class AgyProvider: Provider, @unchecked Sendable {
    let id = "agy"
    var title: String { L.t("p.agy") }
    private let cfg: Config
    private let files: AgyFileLocations
    /// Pause/backoff state owned by RefreshCoordinator; tests may set directly.
    var pauseState = AgyAccountPauseState()
    var onPauseTransition: ((AgyPauseTransition) -> Void)?

    init(cfg: Config, files: AgyFileLocations = .default) {
        self.cfg = cfg
        self.files = files
    }

    func fetchAll(manual: Bool) async -> [Reading] {
        guard manual || cfg.interval(id) > 0 else {
            return cachedOnly()
        }
        let accounts = cfg.accounts(id, fallback: Discovery.agy())
        if accounts.isEmpty { return [.off(id, title, nil, L.t("a.nostate"))] }
        var out: [Reading] = []
        for a in accounts { out.append(await fetch(a, manual: manual)) }
        return out
    }

    private func fetch(_ a: AccountSpec, manual: Bool) async -> Reading {
        let dir = expand(a.home ?? "~") + "/.gemini/antigravity-cli"
        let home = trustedHome(a.home ?? "~", marker: ".gemini/antigravity-cli")
        var paused = pauseState.paused

        let approvedBinary = AgyTUI.binary(cfg.agyBinary.isEmpty ? nil : cfg.agyBinary)
        let inBackoff = !manual && backoffActive()
        let printModeEligible = cfg.agyQuotaViaPrint && (manual || (!paused && !inBackoff))

        var skipForConcurrency = false
        if printModeEligible, !manual, let bin = approvedBinary {
            skipForConcurrency = CommandRun.isRunning(binary: bin)
        }

        var livePrint: Reading?
        var unsavedNotice = false
        if printModeEligible, !skipForConcurrency,
           let bin = approvedBinary, let home {
            if let reading = await printQuota(binary: bin, home: home, account: a.name) {
                clearPause()
                clearBackoff()
                paused = false
                if manual { return reading }
                livePrint = reading
            } else if let stderr = lastAttemptStderr(a.name), AgyProvider.refused(stderr) {
                if !markPaused() { unsavedNotice = true }
                paused = true
            } else {
                if !markBackoff() { unsavedNotice = true }
            }
        }

        var tuiReading: Reading?
        if manual, livePrint == nil, cfg.agyQuotaViaTUI, let home,
           let panel = await tuiQuota(home: home, account: a.name),
           panel.state != .failure {
            tuiReading = panel
        }

        let logReading = fromLog(dir: dir, account: a.name)
        let cachedPrint = cachedPrintSnapshot(account: a.name, home: home ?? expand(a.home ?? "~"))
        let printCandidate = livePrint ?? cachedPrint
        let fallback = tuiReading ?? logReading
        let printInterval = TimeInterval(cfg.interval(id))

        if paused, !manual {
            if let print = printCandidate,
               AgyProvider.printSnapshotIsFresh(print, printInterval: printInterval) {
                var out = print
                if let snap = print.snapshotAt {
                    out.lines.insert(L.t("a.paused.cached", Fmt.relative(snap)), at: 0)
                }
                if unsavedNotice { out.lines.append(L.t("a.state.unsaved")) }
                return out
            }
            var failed = Reading.failed(id, title, a.name, L.t("a.print.paused"))
            if unsavedNotice { failed.lines.append(L.t("a.state.unsaved")) }
            return failed
        }

        let merged = AgyProvider.mergePrintAndFallback(print: printCandidate, fallback: fallback,
                                                     printInterval: printInterval)
        if unsavedNotice {
            var out = merged
            out.lines.append(L.t("a.state.unsaved"))
            return out
        }
        return merged
    }

    /// Drives `agy -p "/usage" --output-format json` and turns a successful
    /// answer into a reading. nil covers every failure shape at once -
    /// process error, timeout, non-zero exit, an unparsed or non-SUCCESS
    /// response, or a 403/PERMISSION_DENIED refusal - the caller decides
    /// what a failure means (pause, fall back, retry); this only decides
    /// whether the run answered.
    private func printQuota(binary: String, home: String, account: String) async -> Reading? {
        let attempt: AgyPrint.Attempt = await Task.detached(priority: .utility) {
            AgyPrint.attempt(binary: binary, home: home, locations: self.files, account: account)
        }.value

        guard attempt.exitCode == 0 else { return nil }
        guard !AgyProvider.refused(attempt.stderr) else { return nil }
        guard let result = AgyPrint.parse(attempt.stdout) else { return nil }

        var r = reading(from: result, account: result.account ?? account)
        guard !r.gauges.isEmpty else { return nil }
        let now = Date()
        r.snapshotAt = now
        r.source = "print"
        for i in r.gauges.indices {
            r.gauges[i].observedAt = now
            r.gauges[i].source = "print"
        }
        r.state = worstState(r.gauges)
        return r
    }

    /// Builds a reading from parsed print-mode groups.
    private func reading(from result: AgyTUI.Result, account: String) -> Reading {
        var r = Reading(id: id, title: title, account: account)
        for group in result.groups {
            let isGemini = AgyProvider.isGeminiGroup(group.name)
            let key = isGemini ? "g.gemini" : "g.claudegpt"
            if let used = group.fiveHourUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.5h.short")), percent: used,
                                      text: String(format: "%.0f%%", used),
                                      resetsAt: group.fiveHourResets,
                                      kind: isGemini ? .shortWindow : .other))
            }
            if let used = group.weeklyUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.week.short")), percent: used,
                                      text: String(format: "%.0f%%", used),
                                      resetsAt: group.weeklyResets,
                                      kind: isGemini ? .longWindow : .other))
            }
        }
        return r
    }

    /// Reads the last on-disk print-mode snapshot written by `AgyPrint.attempt`.
    func cachedPrintSnapshot(account: String, home: String) -> Reading? {
        let path = files.snapshotPath(account)
        guard let loaded = AgyPrint.loadSnapshot(at: path, account: account, home: home),
              let result = AgyPrint.parse(loaded.data), !result.groups.isEmpty else { return nil }
        var r = reading(from: result, account: result.account ?? account)
        guard !r.gauges.isEmpty else { return nil }
        r.snapshotAt = loaded.observedAt
        r.source = "print"
        for i in r.gauges.indices {
            r.gauges[i].observedAt = loaded.observedAt
            r.gauges[i].source = "print"
        }
        r.state = worstState(r.gauges)
        return r
    }

    /// Whether a print snapshot still counts as authoritative for display.
    static func printSnapshotIsFresh(_ print: Reading?, printInterval: TimeInterval,
                                     grace: TimeInterval = 600, now: Date = Date()) -> Bool {
        guard let print, !print.gauges.isEmpty, let snap = print.snapshotAt else { return false }
        return now.timeIntervalSince(snap) <= printInterval + grace
    }

    /// Picks print-mode gauges over log/TUI fallbacks when the print snapshot is
    /// still within `printInterval` plus a ten-minute grace. Log/TUI readings
    /// never replace a fresher print snapshot.
    static func mergePrintAndFallback(print: Reading?, fallback: Reading,
                                      printInterval: TimeInterval,
                                      grace: TimeInterval = 600,
                                      now: Date = Date()) -> Reading {
        if let print, printSnapshotIsFresh(print, printInterval: printInterval,
                                           grace: grace, now: now) {
            return print
        }
        if let print, !print.gauges.isEmpty, let snap = print.snapshotAt {
            if !fallback.gauges.isEmpty {
                var out = fallback
                out.lines.insert(L.t("a.fromlog", Fmt.relative(snap)), at: 0)
                return out
            }
            return print
        }
        if !fallback.gauges.isEmpty { return fallback }
        return fallback
    }

    /// A permission refusal shows up in the run's own stderr as
    /// "PERMISSION_DENIED" or an HTTP 403.
    ///
    /// Deliberately **not** scanned for in the CLI's log file, unlike
    /// `fromLog`'s equivalent check on a line already filtered to be about
    /// quota retrieval. Measured live 2026-09-04, first real run of this
    /// feature: an early version of this function grepped the log's last
    /// 64KB for a bare "403", and it fired on a completely successful
    /// request - the false positive was
    /// `keyringAuth: loaded token, expiry=2026-09-04 14:53:58.764034`,
    /// whose fractional-seconds field `764034` contains the digits `403` by
    /// coincidence. A rolling multi-KB log is dense with timestamps, ports,
    /// byte counts and PIDs; a three-digit substring match against it is not
    /// a signal. `attempt.stderr` is small, scoped to exactly this one
    /// invocation, and `\b403\b` still guards even that against a stray
    /// three-digit run inside a longer number. Not `private` (unlike the
    /// rest of this file's internals): kept plainly testable, the same
    /// reasoning `AgyPrint.parse` and `AgyTUI.parse` already follow, because
    /// this exact function is the one this project's own testing culture
    /// exists to pin down after a bug is found live.
    static func refused(_ stderrText: String) -> Bool {
        if stderrText.contains("PERMISSION_DENIED") { return true }
        return stderrText.range(of: #"\b403\b"#, options: .regularExpression) != nil
    }

    private static func isGeminiGroup(_ name: String) -> Bool { name.uppercased().contains("GEMINI") }

    // MARK: - pause state (owned by RefreshCoordinator; transitions reported upward)

    @discardableResult
    private func markPaused() -> Bool {
        pauseState.paused = true
        onPauseTransition?(.paused)
        return onPauseTransition != nil
    }

    private func clearPause() {
        guard pauseState.paused else { return }
        pauseState.paused = false
        if pauseState.backoff == nil { onPauseTransition?(.clear) }
    }

    private func lastAttemptStderr(_ account: String) -> String? {
        let path = files.attemptPath(account)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let diag = try? JSONDecoder().decode(AgyAttemptDiag.self, from: data) else { return nil }
        return diag.stderr
    }

    private struct AgyAttemptDiag: Codable { var stderr: String }

    private func backoffActive(now: Date = Date()) -> Bool {
        guard let until = pauseState.backoff?.until else { return false }
        return now < until
    }

    @discardableResult
    private func markBackoff(now: Date = Date()) -> Bool {
        var failures = 1
        if let old = pauseState.backoff, old.until > now {
            failures = old.failures + 1
        }
        let minutes = min(60, 5 * Int(pow(2.0, Double(failures - 1))))
        let state = AgyBackoffState(failures: failures, until: now.addingTimeInterval(Double(minutes * 60)))
        pauseState.backoff = state
        onPauseTransition?(.backoff(state))
        return onPauseTransition != nil
    }

    private func clearBackoff() {
        guard pauseState.backoff != nil else { return }
        pauseState.backoff = nil
        if !pauseState.paused { onPauseTransition?(.clear) }
    }

    // MARK: - manual-only fallback: the pty screen-scrape

    /// Drives the vendor's own client to read the one place these numbers
    /// exist when print mode is off or has failed. See AgyTUI for why this
    /// rather than an HTTP request.
    private func tuiQuota(home: String, account: String) async -> Reading? {
        guard let bin = AgyTUI.binary(cfg.agyBinary.isEmpty ? nil : cfg.agyBinary) else {
            return .failed(id, title, account, L.t("a.tui.nobin"))
        }
        let result: AgyTUI.Result? = await Task.detached(priority: .utility) {
            AgyTUI.read(binary: bin, home: home)
        }.value
        guard let result else {
            return .failed(id, title, account, L.t("a.tui.fail"))
        }

        var r = reading(from: result, account: result.account ?? account)
        guard !r.gauges.isEmpty else { return .failed(id, title, account, L.t("a.tui.fail")) }
        // Nothing refreshes this on its own, so it must carry its age: an hour
        // later it is still the last thing anyone measured, not the current one.
        r.snapshotAt = Date()
        r.source = "tui"
        r.state = worstState(r.gauges)
        return r
    }

    private func fromLog(dir: String, account: String) -> Reading {
        guard let path = newestLog(dir) else {
            return .off(id, title, account, L.t("a.nolog"))
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
           size > Net.maxResponseBytes {
            return Reading(id: id, title: title, account: account,
                           lines: [L.t("n.toolarge")], state: .warn)
        }
        guard let text = tailBytes(path, limit: 256 * 1024) else {
            return .off(id, title, account, L.t("a.nolog"))
        }

        var refusalLine: String?
        var parsedUsed: Double?
        for line in text.split(separator: "\n").reversed() {
            let s = String(line)
            guard s.contains("retrieveUserQuotaSummary") || s.contains("quota_manager") else { continue }
            if AgyProvider.logRefused(s) {
                refusalLine = s
                break
            }
            if s.lowercased().contains("failed") {
                var r = Reading(id: id, title: title, account: account)
                r.snapshotAt = Self.logTimestamp(s) ?? fileDate(path)
                r.source = "log"
                r.state = .warn
                r.lines = [L.t("a.failed")]
                return r
            }
            if let used = AgyProvider.parseQuotaLogLine(s) {
                parsedUsed = used
                break
            }
        }

        if let refusalLine {
            _ = refusalLine
            var r = Reading(id: id, title: title, account: account)
            r.snapshotAt = fileDate(path)
            r.source = "log"
            r.state = .failure
            r.lines = [L.t("a.403"), L.t("a.403b")]
            return r
        }

        guard let used = parsedUsed else {
            return .off(id, title, account, L.t("a.norecord"))
        }

        var r = Reading(id: id, title: title, account: account)
        r.snapshotAt = fileDate(path)
        r.source = "log"
        r.gauges.append(Gauge(label: L.t("g.quota"), percent: used,
                              text: String(format: "%.0f%%", used), resetsAt: nil))
        r.state = worstState(r.gauges)
        return r
    }

    /// A permission refusal in a quota log line: `PERMISSION_DENIED` or an
    /// HTTP 403 in a status field — not a bare three-digit substring.
    static func logRefused(_ line: String) -> Bool {
        if line.contains("PERMISSION_DENIED") { return true }
        if line.range(of: #"\bstatus[^0-9]*403\b"#, options: .regularExpression) != nil { return true }
        return line.range(of: #"\bHTTP\s+403\b"#, options: .regularExpression) != nil
    }

    /// Parses a quota log line that names a direction (`left`/`remaining` vs
    /// `used`) and carries a timestamp. Returns used percent, not remaining.
    static func parseQuotaLogLine(_ line: String) -> Double? {
        guard logTimestamp(line) != nil else { return nil }
        let lower = line.lowercased()
        let isRemaining = lower.range(of: #"\b(left|remaining)\b"#, options: .regularExpression) != nil
        let isUsed = lower.range(of: #"\bused\b"#, options: .regularExpression) != nil
        guard isRemaining || isUsed else { return nil }
        guard let raw = firstPercent(in: line) else { return nil }
        return isRemaining ? max(0, min(100, 100 - raw)) : raw
    }

    private static func logTimestamp(_ line: String) -> Date? {
        if let r = line.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?"#, options: .regularExpression) {
            var s = String(line[r])
            if !s.hasSuffix("Z") { s += "Z" }
            return ISO8601DateFormatter.withFractional.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
        }
        if let r = line.range(of: #"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
            var s = String(line[r]).replacingOccurrences(of: " ", with: "T")
            if !s.hasSuffix("Z") { s += "Z" }
            return ISO8601DateFormatter.withFractional.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    private static func firstPercent(in line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3}(\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        return Double(line[r].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private func fileDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date()
    }

    private func newestLog(_ dir: String) -> String? {
        let fm = FileManager.default
        let symlink = dir + "/cli.log"
        if fm.fileExists(atPath: symlink) { return symlink }
        let logs = dir + "/log"
        return ((try? fm.contentsOfDirectory(atPath: logs)) ?? [])
            .filter { $0.hasSuffix(".log") }.sorted(by: >).first.map { logs + "/" + $0 }
    }

    /// Local/cache-only path for manual-only scheduling (interval 0).
    private func cachedOnly() -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.agy())
        if accounts.isEmpty { return [.off(id, title, nil, L.t("a.nostate"))] }
        return accounts.map { account in
            let dir = expand(account.home ?? "~") + "/.gemini/antigravity-cli"
            let home = trustedHome(account.home ?? "~", marker: ".gemini/antigravity-cli")
            let cached = cachedPrintSnapshot(account: account.name, home: home ?? expand(account.home ?? "~"))
            let log = fromLog(dir: dir, account: account.name)
            return AgyProvider.mergePrintAndFallback(print: cached, fallback: log,
                                                     printInterval: TimeInterval(cfg.interval(id)))
        }
    }
}
