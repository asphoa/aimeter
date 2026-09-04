import Foundation
import SwiftUI

/// The primary card's trend line: the last 24h of the primary provider's
/// short (5-hour) window, read straight from the on-disk usage ledger
/// (`History.swift` writes it, one JSON object per line).
enum Sparkline {
    /// Parses already-read ledger lines into `(time, percent)` samples for one
    /// provider's `.shortWindow` gauge, keeping only the last 24h and
    /// downsampling to at most `maxPoints` while preserving chronological
    /// order. A line that fails to parse, names a different provider/kind, or
    /// carries no numeric percent (an expired-window line, or a malformed
    /// one) is skipped rather than failing the whole read - this is exactly
    /// the shape convention #3 in this project's pipeline rules asks for: a
    /// bad unit costs itself, never the ones around it.
    static func samples(from lines: [String], provider: String, now: Date = Date(),
                        maxPoints: Int = 96) -> [(Date, Double)] {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let iso = ISO8601DateFormatter()
        var points: [(Date, Double)] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["provider"] as? String) == provider,
                  (obj["kind"] as? String) == "shortWindow",
                  let tStr = obj["t"] as? String,
                  let t = iso.date(from: tStr),
                  t >= cutoff, t <= now,
                  let pct = obj["percent"] as? Double else { continue }
            points.append((t, pct))
        }
        points.sort { $0.0 < $1.0 }
        guard points.count > maxPoints, maxPoints > 1 else { return points }
        // Evenly spaced indices rather than every Nth line: the ledger is not
        // written at a fixed cadence (a manual check lands between timer
        // ticks), so a fixed stride would over-represent whichever stretch
        // happened to be checked most often.
        var out: [(Date, Double)] = []
        let step = Double(points.count - 1) / Double(maxPoints - 1)
        for i in 0..<maxPoints {
            let idx = min(points.count - 1, Int((Double(i) * step).rounded()))
            out.append(points[idx])
        }
        return out
    }
}

extension Sparkline {
    /// The file-reading counterpart to `samples(from:...)`, which stays a pure
    /// function of already-read lines for testability. Reads the current
    /// month's ledger plus the previous month's (a 24h window can cross a
    /// UTC month boundary in the last hours of a month) and downsamples.
    static func recentSamples(historyDir: String, provider: String, now: Date = Date()) -> [(Date, Double)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var lines: [String] = []
        for monthsAgo in [0, 1] {
            guard let d = cal.date(byAdding: .month, value: -monthsAgo, to: now) else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            let stamp = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            guard let text = try? String(contentsOfFile: historyDir + "/\(stamp).jsonl", encoding: .utf8)
            else { continue }
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
        }
        return samples(from: lines, provider: provider, now: now)
    }
}

/// Draws the samples: area fill, line, an endpoint dot, a dashed 70% guide,
/// and "24h"/"70%" corner labels. Fewer than two points draws only the muted
/// empty-state line - there is no shape a single point could honestly imply.
struct SparklineView: View {
    let samples: [(Date, Double)]
    var ink: Color

    private static let height: CGFloat = 44

    /// Maps each sample to a point in a `width`x`height` box: x by its
    /// position between the first and last sample's timestamp, y by its
    /// percent (0 at the bottom, 100 at the top). A free function rather than
    /// a closure/nested func inside the `GeometryReader` body below - a
    /// `return` inside either trips the `@ViewBuilder` transform on the
    /// enclosing closure.
    private static func plot(_ samples: [(Date, Double)], width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard let first = samples.first, let last = samples.last else { return [] }
        let minT = first.0.timeIntervalSinceReferenceDate
        let span = max(1, last.0.timeIntervalSinceReferenceDate - minT)
        return samples.map { s in
            let x = CGFloat((s.0.timeIntervalSinceReferenceDate - minT) / span) * width
            let y = height - CGFloat(max(0, min(100, s.1)) / 100) * height
            return CGPoint(x: x, y: y)
        }
    }

    var body: some View {
        Group {
            if samples.count < 2 {
                Text(L.t("pn.trend.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.height)
            } else {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let pts = Self.plot(samples, width: w, height: h)
                    let guideY = h - CGFloat(70.0 / 100) * h

                    ZStack(alignment: .topLeading) {
                        // dashed 70% guide
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: guideY))
                            p.addLine(to: CGPoint(x: w, y: guideY))
                        }
                        .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        // area fill
                        Path { p in
                            guard let first = pts.first, let last = pts.last else { return }
                            p.move(to: CGPoint(x: first.x, y: h))
                            for pt in pts { p.addLine(to: pt) }
                            p.addLine(to: CGPoint(x: last.x, y: h))
                            p.closeSubpath()
                        }
                        .fill(ink.opacity(0.10))

                        // line
                        Path { p in
                            guard let first = pts.first else { return }
                            p.move(to: first)
                            for pt in pts.dropFirst() { p.addLine(to: pt) }
                        }
                        .stroke(ink, lineWidth: 1.4)

                        // endpoint dot
                        if let last = pts.last {
                            Circle().fill(ink)
                                .frame(width: 4.4, height: 4.4)
                                .position(last)
                        }

                        Text("24h")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                        Text("70%")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                            .position(x: w - 14, y: max(6, guideY - 7))
                    }
                }
                .frame(height: Self.height)
            }
        }
    }
}
