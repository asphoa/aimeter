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
final class AgyProvider: Provider, @unchecked Sendable {
    let id = "agy"
    var title: String { L.t("p.agy") }
    private let cfg: Config

    init(cfg: Config) { self.cfg = cfg }

    func fetchAll(manual: Bool) async -> [Reading] {
        let accounts = cfg.accounts(id, fallback: Discovery.agy())
        if accounts.isEmpty { return [.off(id, title, nil, L.t("a.nostate"))] }
        var out: [Reading] = []
        for a in accounts { out.append(await fetch(a, manual: manual)) }
        return out
    }

    private func fetch(_ a: AccountSpec, manual: Bool) async -> Reading {
        let dir = expand(a.home ?? "~") + "/.gemini/antigravity-cli"
        let marker = AgyProvider.pauseMarkerPath(a.name)
        var paused = FileManager.default.fileExists(atPath: marker)

        // print-mode is attempted on a timer as well as by hand - the whole
        // point of it costing nothing is that it no longer needs to be
        // manual-only. A paused account is skipped by the timer (that is
        // what "paused" means) but never by a manual click: "Check now" is
        // exactly the escape hatch a pause exists to wait for.
        let skipForConcurrency = !manual && AgyProvider.agyAlreadyRunning()
        if cfg.agyQuotaViaPrint, manual || !paused, !skipForConcurrency,
           let bin = AgyTUI.binary(cfg.agyBinary.isEmpty ? nil : cfg.agyBinary),
           let home = trustedHome(a.home ?? "~", marker: ".gemini/antigravity-cli") {
            if let reading = await printQuota(binary: bin, home: home, account: a.name) {
                AgyProvider.clearPause(a.name)
                return reading
            }
            // Any of rc≠0, status != "SUCCESS", or a 403/PERMISSION_DENIED
            // in this run's own stderr counts as a refusal or a failure,
            // and either way this project's rule is that a failure must be
            // visible rather than quietly retried forever - so future
            // scheduled checks stop asking until a person presses "Check
            // now" again. See `refused` for why this checks only stderr,
            // not the CLI's log file.
            AgyProvider.markPaused(a.name)
            paused = true
        }

        if paused, !manual { return .failed(id, title, a.name, L.t("a.print.paused")) }

        if manual, cfg.agyQuotaViaTUI,
           let home = trustedHome(a.home ?? "~", marker: ".gemini/antigravity-cli"),
           let panel = await tuiQuota(home: home, account: a.name) {
            return panel
        }
        return fromLog(dir: dir, account: a.name)
    }

    /// Drives `agy -p "/usage" --output-format json` and turns a successful
    /// answer into a reading. nil covers every failure shape at once -
    /// process error, timeout, non-zero exit, an unparsed or non-SUCCESS
    /// response, or a 403/PERMISSION_DENIED refusal - the caller decides
    /// what a failure means (pause, fall back, retry); this only decides
    /// whether the run answered.
    private func printQuota(binary: String, home: String, account: String) async -> Reading? {
        let attempt: AgyPrint.Attempt = await Task.detached(priority: .utility) {
            AgyPrint.attempt(binary: binary, home: home)
        }.value

        guard attempt.exitCode == 0 else { return nil }
        guard !AgyProvider.refused(attempt.stderr) else { return nil }
        guard let result = AgyPrint.parse(attempt.stdout) else { return nil }

        var r = Reading(id: id, title: title, account: result.account ?? account)
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
        guard !r.gauges.isEmpty else { return nil }
        // Fetched fresh this refresh, but not re-checked until the next one
        // - the same reasoning as tuiQuota's snapshotAt, so a window that
        // rolls over between two hourly checks is withdrawn by Reading.asOf
        // rather than shown stale.
        r.snapshotAt = Date()
        r.state = worstState(r.gauges)
        return r
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

    // MARK: - pause state
    //
    // A small marker file rather than in-memory state: this provider is
    // rebuilt from a fresh Config value on every launch and every settings
    // change (see AppDelegate), so anything held only in memory would forget
    // a pause the moment either happened. The file carries no data worth
    // reading - its existence is the whole signal - so it is written empty.

    private static func pauseMarkerPath(_ account: String) -> String {
        let slug = String(account.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "_"
        })
        return Config.dir + "/agy-print-paused-" + slug + ".marker"
    }

    private static func markPaused(_ account: String) {
        writePrivate(Data(), to: pauseMarkerPath(account))
    }

    private static func clearPause(_ account: String) {
        try? FileManager.default.removeItem(atPath: pauseMarkerPath(account))
    }

    /// Concurrency between two agy processes sharing a HOME is untested -
    /// print mode may bind the same local port the TUI does. A scheduled
    /// refresh backs off rather than find out; a person pressing "Check now"
    /// is deciding that risk for themselves, same as AgyTUI already lets
    /// them.
    private static func agyAlreadyRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "agy"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
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

        var r = Reading(id: id, title: title, account: result.account ?? account)
        for group in result.groups {
            let isGemini = AgyProvider.isGeminiGroup(group.name)
            let key = isGemini ? "g.gemini" : "g.claudegpt"
            if let used = group.fiveHourUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.5h.short")), percent: used,
                                      text: String(format: "%.0f%%", used), resetsAt: nil,
                                      kind: isGemini ? .shortWindow : .other))
            }
            if let used = group.weeklyUsed {
                r.gauges.append(Gauge(label: L.t(key, L.t("g.week.short")), percent: used,
                                      text: String(format: "%.0f%%", used),
                                      resetsAt: group.weeklyResets,
                                      kind: isGemini ? .longWindow : .other))
            }
        }
        guard !r.gauges.isEmpty else { return .failed(id, title, account, L.t("a.tui.fail")) }
        // Nothing refreshes this on its own, so it must carry its age: an hour
        // later it is still the last thing anyone measured, not the current one.
        r.snapshotAt = Date()
        r.state = worstState(r.gauges)
        return r
    }

    private func fromLog(dir: String, account: String) -> Reading {
        guard let path = newestLog(dir), let text = tailBytes(path, limit: 256 * 1024) else {
            return .off(id, title, account, L.t("a.nolog"))
        }
        var lastLine: String?
        for line in text.split(separator: "\n").reversed()
        where line.contains("retrieveUserQuotaSummary") || line.contains("quota_manager") {
            lastLine = String(line); break
        }
        guard let line = lastLine else { return .off(id, title, account, L.t("a.norecord")) }

        var r = Reading(id: id, title: title, account: account)
        r.snapshotAt = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date ?? Date()

        if line.contains("PERMISSION_DENIED") || line.contains("403") {
            r.state = .failure
            r.lines = [L.t("a.403"), L.t("a.403b")]
        } else if line.lowercased().contains("failed") {
            r.state = .warn
            r.lines = [L.t("a.failed")]
        } else if let pct = firstPercent(line) {
            r.gauges.append(Gauge(label: L.t("g.quota"), percent: pct,
                                  text: String(format: "%.0f%%", pct), resetsAt: nil))
            r.state = worstState(r.gauges)
        } else {
            r.lines = [L.t("a.silent"), L.t("a.silent2")]
        }
        return r
    }

    private func newestLog(_ dir: String) -> String? {
        let fm = FileManager.default
        let symlink = dir + "/cli.log"
        if fm.fileExists(atPath: symlink) { return symlink }
        let logs = dir + "/log"
        return ((try? fm.contentsOfDirectory(atPath: logs)) ?? [])
            .filter { $0.hasSuffix(".log") }.sorted(by: >).first.map { logs + "/" + $0 }
    }

    private func firstPercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"(\d{1,3}(\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        return Double(line[r].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }
}
