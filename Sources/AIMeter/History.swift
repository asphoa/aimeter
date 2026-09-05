import Foundation

/// Append-only usage ledger. One JSON object per line, one file per UTC
/// month, written under `Config.dir + "/history"`.
///
/// Percentages, labels, times, error strings — never a token, header, or
/// secret. `line(for:gauge:at:)` is a pure function so its shape is testable
/// without touching disk; `record`/`append` do the actual (privileged) I/O.
enum History {
    /// A reading with no gauges from a provider whose state is `.off` (the
    /// Cursor link row is the motivating case) has nothing to chart and is
    /// not written — recording it would only ever produce empty lines with
    /// no percent, no error, and no informative gap either.
    static func record(_ readings: [Reading], at now: Date = Date(), dir: String = Config.dir) {
        guard Config.load().config.history.enabled else { return }
        var lines: [String] = []
        for r in readings {
            if r.gauges.isEmpty {
                if r.state == .off { continue }
                lines.append(line(for: r, gauge: nil, at: now))
            } else {
                for g in r.gauges {
                    lines.append(line(for: r, gauge: g, at: now))
                }
            }
        }
        guard !lines.isEmpty else { return }
        append(lines, at: now, dir: dir)
    }

    /// One ledger line for a reading (an error line, when `gauge` is nil) or
    /// for one of its gauges. Built with `JSONSerialization` rather than by
    /// hand so a label containing a quote or newline still comes out valid.
    static func line(for reading: Reading, gauge: Gauge?, at now: Date) -> String {
        var obj: [String: Any] = [
            "t": iso(now),
            "provider": reading.id,
            "account": reading.account ?? "",
            "state": reading.state.rawValue
        ]
        if let g = gauge {
            obj["gauge"] = g.label
            obj["kind"] = g.kind.rawValue
            obj["percent"] = g.percent ?? NSNull()
            obj["text"] = g.text
            obj["resets_at"] = g.resetsAt.map(iso) ?? NSNull()
            obj["snapshot_at"] = reading.snapshotAt.map(iso) ?? NSNull()
        } else {
            obj["error"] = reading.lines.first ?? ""
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
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

    /// Appends whole lines in one `write(2)` call each, to a file opened with
    /// O_APPEND|O_CREAT — so a kill mid-write leaves either the previous
    /// complete line or nothing new, never a half-line a reader could
    /// mistake for a record. Directory 0700, file 0600.
    private static func append(_ lines: [String], at now: Date, dir: String) {
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
        guard fd >= 0 else { return }
        defer { close(fd) }
        fchmod(fd, 0o600)
        for l in lines {
            var payload = Array((l + "\n").utf8)
            _ = payload.withUnsafeMutableBytes { buf -> Int in
                guard let base = buf.baseAddress else { return -1 }
                return write(fd, base, buf.count)
            }
        }
    }

    /// Deletes monthly ledger files older than `retentionMonths`. Called once
    /// at launch; harmless to call more often.
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
        for f in files where f.hasSuffix(".jsonl") {
            let stamp = String(f.dropLast(".jsonl".count))
            guard stamp.count == 7 else { continue }
            if stamp < cutoffStamp {
                try? fm.removeItem(atPath: historyDir + "/" + f)
            }
        }
    }
}
