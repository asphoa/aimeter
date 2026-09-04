import Foundation

/// One parsed ledger line, gauge or error, kept generic enough to feed both
/// the CSV and the HTML chart without re-parsing.
struct HistoryRecord {
    var t: Date
    var provider: String
    var account: String
    var gauge: String?
    var kind: String?
    var percent: Double?
    var text: String?
    var resetsAt: Date?
    var error: String?
    var state: Int
}

/// Reads every `history/*.jsonl` file and writes a self-contained CSV and
/// HTML report. No external resources of any kind — the HTML is meant to be
/// copied anywhere and still work.
enum HistoryReport {
    /// Returns (csvPath, htmlPath).
    @discardableResult
    static func export(dir: String = Config.dir, providerTitle: (String) -> String = defaultTitle) -> (String, String) {
        let historyDir = dir + "/history"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: historyDir, withIntermediateDirectories: true,
                                 attributes: [.posixPermissions: 0o700])
        let files = ((try? fm.contentsOfDirectory(atPath: historyDir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted()

        var records: [HistoryRecord] = []
        var skipped = 0
        let iso = ISO8601DateFormatter()
        for f in files {
            guard let content = try? String(contentsOfFile: historyDir + "/" + f, encoding: .utf8) else { continue }
            for raw in content.split(separator: "\n") {
                guard let data = raw.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tStr = obj["t"] as? String, let t = iso.date(from: tStr),
                      let provider = obj["provider"] as? String,
                      let state = obj["state"] as? Int else {
                    skipped += 1
                    continue
                }
                let account = (obj["account"] as? String) ?? ""
                if let error = obj["error"] as? String {
                    records.append(HistoryRecord(t: t, provider: provider, account: account,
                                                  gauge: nil, kind: nil, percent: nil, text: nil,
                                                  resetsAt: nil, error: error, state: state))
                } else if let gauge = obj["gauge"] as? String {
                    let percent: Double? = {
                        if let n = obj["percent"] as? NSNumber { return n.doubleValue }
                        return nil
                    }()
                    let resetsAt: Date? = (obj["resets_at"] as? String).flatMap(iso.date)
                    records.append(HistoryRecord(t: t, provider: provider, account: account,
                                                  gauge: gauge, kind: obj["kind"] as? String,
                                                  percent: percent, text: obj["text"] as? String,
                                                  resetsAt: resetsAt, error: nil, state: state))
                } else {
                    skipped += 1
                }
            }
        }

        let csvPath = historyDir + "/history.csv"
        let htmlPath = historyDir + "/history.html"
        writeCSV(records, to: csvPath)
        writeHTML(records, skipped: skipped, to: htmlPath, providerTitle: providerTitle)
        return (csvPath, htmlPath)
    }

    private static func defaultTitle(_ id: String) -> String { ProviderKind.find(id)?.title ?? id }

    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func writeCSV(_ records: [HistoryRecord], to path: String) {
        let iso = ISO8601DateFormatter()
        var lines = ["t,provider,account,gauge,kind,percent,text,resets_at,error,state"]
        for r in records {
            let fields = [
                iso.string(from: r.t), r.provider, r.account,
                r.gauge ?? "", r.kind ?? "",
                r.percent.map { String($0) } ?? "",
                r.text ?? "", r.resetsAt.map(iso.string) ?? "",
                r.error ?? "", String(r.state)
            ].map(csvField)
            lines.append(fields.joined(separator: ","))
        }
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) ?? Data()
        writePrivate(data, to: path)
    }

    private static func writeHTML(_ records: [HistoryRecord], skipped: Int, to path: String,
                                   providerTitle: (String) -> String) {
        let iso = ISO8601DateFormatter()
        struct Key: Hashable { var provider: String; var account: String }
        var groups: [Key: [HistoryRecord]] = [:]
        for r in records where r.gauge != nil {
            groups[Key(provider: r.provider, account: r.account), default: []].append(r)
        }
        let errors = records.filter { $0.error != nil }.sorted { $0.t > $1.t }

        var body = ""
        body += "<h1>AIMeter usage history</h1>\n"
        body += "<p class=\"meta\">\(records.count) record(s) across \(groups.count) chart(s)"
        if skipped > 0 { body += " · \(skipped) unparseable line(s) skipped" }
        body += "</p>\n"

        for key in groups.keys.sorted(by: { $0.provider == $1.provider ? $0.account < $1.account : $0.provider < $1.provider }) {
            let recs = (groups[key] ?? []).sorted { $0.t < $1.t }
            let title = providerTitle(key.provider) + (key.account.isEmpty ? "" : " · \(key.account)")
            body += "<section class=\"chart\">\n<h2>\(escape(title))</h2>\n"
            body += svg(for: recs)
            body += legend(for: recs)
            body += table(for: recs, iso: iso)
            body += "</section>\n"
        }

        body += "<section class=\"errors\">\n<h2>Errors</h2>\n"
        if errors.isEmpty {
            body += "<p class=\"meta\">None recorded.</p>\n"
        } else {
            body += "<table><tr><th>Time</th><th>Provider</th><th>Message</th></tr>\n"
            for e in errors.prefix(200) {
                body += "<tr><td>\(escape(iso.string(from: e.t)))</td><td>\(escape(providerTitle(e.provider)))</td><td>\(escape(e.error ?? ""))</td></tr>\n"
            }
            body += "</table>\n"
        }
        body += "</section>\n"

        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <title>AIMeter usage history</title>
        <style>
        :root { color-scheme: light dark; --bg:#fff; --fg:#111; --grid:#ddd; --muted:#666; --line1:#2563eb; --line2:#dc2626; --line3:#059669; --line4:#d97706; --line5:#7c3aed; }
        @media (prefers-color-scheme: dark) { :root { --bg:#1b1b1e; --fg:#eee; --grid:#3a3a3f; --muted:#999; } }
        body { background:var(--bg); color:var(--fg); font:14px -apple-system,BlinkMacSystemFont,sans-serif; margin:0; padding:24px 32px 64px; }
        h1 { font-size:20px; margin:0 0 4px; }
        h2 { font-size:15px; margin:24px 0 8px; }
        .meta { color:var(--muted); font-size:12px; }
        section.chart { margin-top:16px; padding-top:8px; border-top:1px solid var(--grid); }
        svg { width:100%; height:220px; display:block; }
        .legend { display:flex; flex-wrap:wrap; gap:12px; font-size:12px; margin:6px 0 10px; }
        .legend span { display:inline-flex; align-items:center; gap:4px; }
        .swatch { width:10px; height:10px; border-radius:2px; display:inline-block; }
        table { border-collapse:collapse; width:100%; font-size:12px; margin-bottom:8px; }
        th, td { text-align:left; padding:3px 8px; border-bottom:1px solid var(--grid); }
        th { color:var(--muted); font-weight:600; }
        section.errors { margin-top:32px; }
        </style>
        </head><body>
        \(body)
        </body></html>
        """
        writePrivate((html).data(using: .utf8) ?? Data(), to: path)
    }

    private static let palette = ["#2563eb", "#dc2626", "#059669", "#d97706", "#7c3aed", "#0891b2"]

    private static func svg(for recs: [HistoryRecord]) -> String {
        guard let first = recs.first, let last = recs.last, last.t > first.t else {
            return "<svg viewBox=\"0 0 800 220\"><text x=\"10\" y=\"110\" fill=\"currentColor\">Not enough data yet</text></svg>\n"
        }
        let w = 800.0, h = 220.0, padL = 34.0, padB = 24.0, padT = 8.0, padR = 8.0
        let plotW = w - padL - padR, plotH = h - padT - padB
        let t0 = first.t.timeIntervalSince1970, t1 = last.t.timeIntervalSince1970
        let span = max(t1 - t0, 1)
        func x(_ t: Date) -> Double { padL + (t.timeIntervalSince1970 - t0) / span * plotW }
        func y(_ p: Double) -> Double { padT + (1 - p / 100) * plotH }

        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" xmlns=\"http://www.w3.org/2000/svg\">\n"
        // gridlines at 0/25/50/75/100%
        for pct in stride(from: 0, through: 100, by: 25) {
            let yy = y(Double(pct))
            svg += "<line x1=\"\(padL)\" y1=\"\(yy)\" x2=\"\(w - padR)\" y2=\"\(yy)\" stroke=\"var(--grid)\" stroke-width=\"1\"/>\n"
            svg += "<text x=\"2\" y=\"\(yy + 4)\" font-size=\"10\" fill=\"var(--muted)\">\(pct)%</text>\n"
        }
        // one tick per day
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        var day = cal.startOfDay(for: first.t)
        let df = DateFormatter(); df.dateFormat = "MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        while day <= last.t {
            let xx = x(day)
            svg += "<line x1=\"\(xx)\" y1=\"\(padT)\" x2=\"\(xx)\" y2=\"\(h - padB)\" stroke=\"var(--grid)\" stroke-width=\"0.5\"/>\n"
            svg += "<text x=\"\(xx)\" y=\"\(h - 6)\" font-size=\"9\" fill=\"var(--muted)\" text-anchor=\"middle\">\(df.string(from: day))</text>\n"
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        let labels = Array(Set(recs.compactMap(\.gauge))).sorted()
        var lastResets: [String: Date] = [:]
        for (i, label) in labels.enumerated() {
            let colour = palette[i % palette.count]
            let series = recs.filter { $0.gauge == label && $0.percent != nil }
            guard !series.isEmpty else { continue }
            var points: [String] = []
            for r in series {
                points.append("\(x(r.t)),\(y(r.percent!))")
                if let ra = r.resetsAt, lastResets[label] != ra {
                    lastResets[label] = ra
                    svg += "<circle cx=\"\(x(r.t))\" cy=\"\(y(r.percent!))\" r=\"2.5\" fill=\"\(colour)\"/>\n"
                }
            }
            svg += "<polyline points=\"\(points.joined(separator: " "))\" fill=\"none\" stroke=\"\(colour)\" stroke-width=\"1.6\"/>\n"
        }
        svg += "</svg>\n"
        return svg
    }

    private static func legend(for recs: [HistoryRecord]) -> String {
        let labels = Array(Set(recs.compactMap(\.gauge))).sorted()
        guard !labels.isEmpty else { return "" }
        var out = "<div class=\"legend\">\n"
        for (i, label) in labels.enumerated() {
            out += "<span><span class=\"swatch\" style=\"background:\(palette[i % palette.count])\"></span>\(escape(label))</span>\n"
        }
        out += "</div>\n"
        return out
    }

    private static func table(for recs: [HistoryRecord], iso: ISO8601DateFormatter) -> String {
        let cutoff = Date().addingTimeInterval(-86400)
        let recent = recs.filter { $0.t >= cutoff }.sorted { $0.t > $1.t }
        guard !recent.isEmpty else { return "" }
        var out = "<table><tr><th>Time</th><th>Gauge</th><th>Percent</th><th>Text</th></tr>\n"
        for r in recent.prefix(200) {
            out += "<tr><td>\(escape(iso.string(from: r.t)))</td><td>\(escape(r.gauge ?? ""))</td>"
            out += "<td>\(r.percent.map { String(format: "%.0f%%", $0) } ?? "—")</td>"
            out += "<td>\(escape(r.text ?? ""))</td></tr>\n"
        }
        out += "</table>\n"
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
