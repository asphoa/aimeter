import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Append-only usage ledger. One JSON object per line, one file per UTC
/// month, written under `Config.dir + "/history"`.
///
/// Percentages, labels, times, error strings — never a token, header, or
/// secret. `line(for:gauge:at:)` is a pure function so its shape is testable
/// without touching disk; `record`/`append` do the actual (privileged) I/O.
enum History {
    /// Settings passed explicitly so `record` does not reload config each tick.
    struct RecordSettings: Sendable {
        var enabled: Bool
        var retentionMonths: Int

        init(_ history: HistoryConfig) {
            enabled = history.enabled
            retentionMonths = history.retentionMonths
        }
    }

    @discardableResult
    static func record(_ readings: [Reading], settings: RecordSettings,
                       at now: Date = Date(), dir: String = Config.dir) -> Bool {
        guard settings.enabled else { return true }
        let path = monthPath(dir, now)
        var lastObj = parseLine(lastLine(at: path))
        var lines: [String] = []
        for r in readings {
            if r.gauges.isEmpty {
                if r.state == .off { continue }
                let observed = r.snapshotAt ?? now
                if shouldSkip(last: lastObj, account: r.account ?? "", gaugeId: nil, observedAt: observed) {
                    continue
                }
                let line = line(for: r, gauge: nil, at: now)
                lines.append(line)
                lastObj = parseLine(line)
            } else {
                for g in r.gauges {
                    let observed = g.observedAt ?? r.snapshotAt ?? now
                    let gid = Parse.gaugeId(label: g.label, kind: g.kind)
                    if shouldSkip(last: lastObj, account: r.account ?? "", gaugeId: gid, observedAt: observed) {
                        continue
                    }
                    let line = line(for: r, gauge: g, at: now)
                    lines.append(line)
                    lastObj = parseLine(line)
                }
            }
        }
        guard !lines.isEmpty else { return true }
        return append(lines, at: now, dir: dir)
    }

    /// One ledger line for a reading (an error line, when `gauge` is nil) or
    /// for one of its gauges. Built with `JSONSerialization` rather than by
    /// hand so a label containing a quote or newline still comes out valid.
    static func line(for reading: Reading, gauge: Gauge?, at attemptedAt: Date) -> String {
        let account = reading.account ?? ""
        let observedAt = gauge?.observedAt ?? reading.snapshotAt ?? attemptedAt
        let source = gauge?.source ?? reading.source ?? ""
        let fresh = gauge.map { $0.observedAt != nil } ?? true
        var obj: [String: Any] = [
            "t": iso(attemptedAt),
            "provider": reading.id,
            "account": account,
            "observed_at": iso(observedAt),
            "source": source,
            "fresh": fresh,
            "state": reading.state.rawValue
        ]
        if let g = gauge {
            obj["gauge_id"] = Parse.gaugeId(label: g.label, kind: g.kind)
            obj["kind"] = g.kind.rawValue
            obj["percent"] = g.percent ?? NSNull()
            obj["text"] = g.text
            obj["resets_at"] = g.resetsAt.map(iso) ?? NSNull()
        } else if let err = reading.lines.first {
            obj["error"] = err
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Reads a monthly ledger file. A damaged trailing line (kill mid-write) is
    /// dropped and counted rather than failing the whole month.
    static func load(path: String) -> (lines: [String], damaged: Int) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return ([], 0)
        }
        var parts = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while parts.last == "" { parts.removeLast() }
        var damaged = 0
        if let last = parts.last, !isValidJSONLine(last) {
            parts.removeLast()
            damaged = 1
        }
        return (parts, damaged)
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func monthKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 1970, c.month ?? 1)
    }

    private static func monthPath(_ dir: String, _ now: Date) -> String {
        dir + "/history/\(monthKey(for: now)).jsonl"
    }

    /// Appends whole lines in one `write(2)` loop each, to a file opened with
    /// O_APPEND|O_CREAT — short writes and EINTR are retried; returns whether
    /// every byte landed. Directory 0700, file 0600.
    @discardableResult
    static func append(_ lines: [String], at now: Date, dir: String) -> Bool {
        let historyDir = dir + "/history"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: historyDir, withIntermediateDirectories: true,
                                 attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyDir)
        let path = monthPath(dir, now)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        fchmod(fd, 0o600)
        for l in lines {
            guard writeAll(fd: fd, Data((l + "\n").utf8)) else { return false }
        }
        return true
    }

    /// Deletes monthly ledger files older than `retentionMonths` and stale CSV/HTML
    /// exports. Callable on launch and on a daily schedule.
    static func applyRetention(dir: String = Config.dir, months: Int, now: Date = Date()) {
        let historyDir = dir + "/history"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: historyDir) else { return }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let cutoff = cal.date(byAdding: .month, value: -months, to: now) else { return }
        let cutoffStamp = { () -> String in
            let c = cal.dateComponents([.year, .month], from: cutoff)
            return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        }()
        for f in files {
            if f.hasSuffix(".jsonl") {
                let stamp = String(f.dropLast(".jsonl".count))
                guard stamp.count == 7, stamp < cutoffStamp else { continue }
                try? fm.removeItem(atPath: historyDir + "/" + f)
            } else if f == "history.csv" || f == "history.html" {
                try? fm.removeItem(atPath: historyDir + "/" + f)
            }
        }
    }

    private static func writeAll(fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = write(fd, base + offset, total - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                offset += n
            }
            return true
        }
    }

    private static func isValidJSONLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return obj["t"] as? String != nil
    }

    private static func parseLine(_ line: String?) -> [String: Any]? {
        guard let line, let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func lastLine(at path: String) -> String? {
        guard let tail = tailBytes(path, limit: 8192) else { return nil }
        let parts = tail.split(separator: "\n", omittingEmptySubsequences: true)
        return parts.last.map(String.init)
    }

    private static func shouldSkip(last: [String: Any]?, account: String,
                                   gaugeId: String?, observedAt: Date) -> Bool {
        guard let last else { return false }
        guard (last["account"] as? String ?? "") == account else { return false }
        let iso = ISO8601DateFormatter()
        guard let obsStr = last["observed_at"] as? String,
              let lastObs = iso.date(from: obsStr),
              abs(lastObs.timeIntervalSince(observedAt)) < 0.001 else { return false }
        if let gid = gaugeId {
            return (last["gauge_id"] as? String) == gid
        }
        return last["error"] != nil
    }
}

/// Background ledger read/index for sparklines and exports. Expanded cards share
/// one bounded in-memory index of the last two UTC months.
actor HistoryService {
    static let shared = HistoryService()

    private var dir = Config.dir
    private var cacheStamp = ""
    private var cachedLines: [String] = []
    private var cachedDamaged = 0

    func setDir(_ dir: String) {
        self.dir = dir
        invalidate()
    }

    func invalidate() {
        cacheStamp = ""
        cachedLines = []
        cachedDamaged = 0
    }

    func loadLines(now: Date = Date()) -> (lines: [String], damaged: Int) {
        let stamp = monthPaths(now: now).joined(separator: "|")
        if stamp == cacheStamp { return (cachedLines, cachedDamaged) }
        var lines: [String] = []
        var damaged = 0
        for path in monthPaths(now: now) {
            let chunk = History.load(path: path)
            lines.append(contentsOf: chunk.lines)
            damaged += chunk.damaged
        }
        cacheStamp = stamp
        cachedLines = lines
        cachedDamaged = damaged
        return (lines, damaged)
    }

    func sparkline(provider: String, account: String, gaugeId: String,
                   refreshInterval: Int, now: Date = Date()) -> [Sparkline.Segment] {
        let (lines, _) = loadLines(now: now)
        return Sparkline.samples(from: lines, provider: provider, account: account,
                                 gaugeId: gaugeId, refreshInterval: refreshInterval, now: now)
    }

    @discardableResult
    func record(_ readings: [Reading], settings: History.RecordSettings,
                at now: Date = Date()) -> Bool {
        let ok = History.record(readings, settings: settings, at: now, dir: dir)
        if ok { invalidate() }
        return ok
    }

    private func monthPaths(now: Date) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return [0, 1].compactMap { monthsAgo -> String? in
            guard let d = cal.date(byAdding: .month, value: -monthsAgo, to: now) else { return nil }
            let key = History.monthKey(for: d)
            return dir + "/history/\(key).jsonl"
        }
    }
}
