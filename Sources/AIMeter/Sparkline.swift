import Foundation
import SwiftUI

/// The primary card's trend line: the last 24h of one account's short-window
/// gauge, read from the on-disk usage ledger (`History.swift` writes it).
enum Sparkline {
    struct Point: Equatable {
        var date: Date
        var value: Double
    }

    /// One contiguous run of samples. Gaps wider than 2× the refresh interval,
    /// or a failure line between samples, start a new segment.
    struct Segment: Equatable {
        var points: [Point]
    }

  /// Parses ledger lines into segments for one provider/account/gauge on a
    /// fixed 24h axis ending at `now`. Lines for other accounts or gauges are
    /// ignored; a bad unit costs itself, never the ones around it.
    static func samples(from lines: [String], provider: String, account: String,
                        gaugeId: String, refreshInterval: Int,
                        now: Date = Date()) -> [Segment] {
        let cutoff = now.addingTimeInterval(-24 * 3600)
        let maxGap = TimeInterval(max(refreshInterval, 1) * 2)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        enum Event {
            case sample(Date, Double)
            case failure(Date)
        }
        var events: [Event] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (obj["provider"] as? String) == provider,
                  ((obj["account"] as? String) ?? "") == account,
                  let tStr = obj["t"] as? String,
                  let t = iso.date(from: tStr),
                  t >= cutoff, t <= now else { continue }

            if obj["repeat"] as? Bool == true { continue }

            if obj["error"] != nil, obj["gauge_id"] == nil {
                if (obj["state"] as? Int) == ReadingState.failure.rawValue {
                    events.append(.failure(t))
                }
                continue
            }

            let gid = (obj["gauge_id"] as? String) ?? legacyGaugeId(obj)
            guard gid == gaugeId else { continue }

            guard let pct = percent(from: obj) else { continue }
            events.append(.sample(t, pct))
        }

        events.sort {
            switch ($0, $1) {
            case (.failure(let a), .failure(let b)): return a < b
            case (.sample(let a, _), .sample(let b, _)): return a < b
            case (.failure(let a), .sample(let b, _)): return a < b
            case (.sample(let a, _), .failure(let b)): return a < b
            }
        }

        var segments: [Segment] = []
        var current: [Point] = []
        var lastSample: Date?
        var failureSinceLast = false

        for event in events {
            switch event {
            case .failure:
                failureSinceLast = true
            case .sample(let t, let pct):
                if let last = lastSample {
                    let gap = t.timeIntervalSince(last)
                    if failureSinceLast || gap > maxGap {
                        if current.count >= 2 { segments.append(Segment(points: current)) }
                        current = []
                        failureSinceLast = false
                    }
                }
                current.append(Point(date: t, value: pct))
                lastSample = t
            }
        }
        if current.count >= 2 { segments.append(Segment(points: current)) }
        return segments
    }

    static func flatten(_ segments: [Segment]) -> [Point] {
        segments.flatMap(\.points)
    }

    private static func percent(from obj: [String: Any]) -> Double? {
        switch Parse.number(obj["percent"]) {
        case .value(let n): return n
        case .missing, .invalid: return nil
        }
    }

    /// v1.0.34 and earlier wrote `gauge` + `kind` instead of `gauge_id`.
    private static func legacyGaugeId(_ obj: [String: Any]) -> String? {
        guard let label = obj["gauge"] as? String,
              let kindRaw = obj["kind"] as? String,
              let kind = GaugeKind(rawValue: kindRaw) else { return nil }
        return Parse.gaugeId(label: label, kind: kind)
    }
}

extension Sparkline {
    /// Loads the current and previous UTC months, then builds segments.
    static func recentSamples(historyDir: String, provider: String, account: String,
                              gaugeId: String, refreshInterval: Int,
                              now: Date = Date()) -> [Segment] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var lines: [String] = []
        for monthsAgo in [0, 1] {
            guard let d = cal.date(byAdding: .month, value: -monthsAgo, to: now) else { continue }
            let key = History.monthKey(for: d)
            let chunk = History.load(path: historyDir + "/\(key).jsonl")
            lines.append(contentsOf: chunk.lines)
        }
        return samples(from: lines, provider: provider, account: account, gaugeId: gaugeId,
                       refreshInterval: refreshInterval, now: now)
    }
}

/// Draws the samples: area fill, line, an endpoint dot, a dashed 70% guide,
/// and "24h"/"70%" corner labels. Fewer than two points draws only the muted
/// empty-state line - there is no shape a single point could honestly imply.
struct SparklineView: View {
    let segments: [Sparkline.Segment]
    var ink: Color
    var now: Date = Date()

    private static let height: CGFloat = 44

    init(samples: [(Date, Double)], ink: Color, now: Date = Date()) {
        self.segments = samples.isEmpty ? [] : [Sparkline.Segment(points: samples.map {
            Sparkline.Point(date: $0.0, value: $0.1)
        })]
        self.ink = ink
        self.now = now
    }

    init(segments: [Sparkline.Segment], ink: Color, now: Date = Date()) {
        self.segments = segments
        self.ink = ink
        self.now = now
    }

    private var pointCount: Int { segments.reduce(0) { $0 + $1.points.count } }

    /// Maps each sample to a point on a fixed 24h axis ending at `now`.
    private static func plot(_ segments: [Sparkline.Segment], width: CGFloat, height: CGFloat,
                             now: Date) -> [[CGPoint]] {
        let windowStart = now.addingTimeInterval(-24 * 3600)
        let span = 24 * 3600.0
        return segments.map { segment in
            segment.points.map { s in
                let x = CGFloat((s.date.timeIntervalSince1970 - windowStart.timeIntervalSince1970) / span) * width
                let y = height - CGFloat(max(0, min(100, s.value)) / 100) * height
                return CGPoint(x: x, y: y)
            }
        }
    }

    var body: some View {
        Group {
            if pointCount < 2 {
                Text(L.t("pn.trend.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.height)
            } else {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let segmentPts = Self.plot(segments, width: w, height: h, now: now)
                    let allPts = segmentPts.flatMap { $0 }
                    let guideY = h - CGFloat(70.0 / 100) * h

                    ZStack(alignment: .topLeading) {
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: guideY))
                            p.addLine(to: CGPoint(x: w, y: guideY))
                        }
                        .stroke(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        ForEach(Array(segmentPts.enumerated()), id: \.offset) { _, pts in
                            Path { p in
                                guard let first = pts.first, let last = pts.last else { return }
                                p.move(to: CGPoint(x: first.x, y: h))
                                for pt in pts { p.addLine(to: pt) }
                                p.addLine(to: CGPoint(x: last.x, y: h))
                                p.closeSubpath()
                            }
                            .fill(ink.opacity(0.10))

                            Path { p in
                                guard let first = pts.first else { return }
                                p.move(to: first)
                                for pt in pts.dropFirst() { p.addLine(to: pt) }
                            }
                            .stroke(ink, lineWidth: 1.4)
                        }

                        if let last = allPts.last {
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
