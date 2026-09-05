import Foundation

enum ReadingState: Int {
    case off = -1, ok = 0, warn = 1, nearLimit = 2, failure = 3
}

/// What a gauge measures. The strip maps `.shortWindow` to a line's top half
/// and `.longWindow` to its bottom half.
enum GaugeKind: String, Codable, Sendable {
    case shortWindow, longWindow, other
    case modelWindow
}

/// One measurable quantity inside a provider.
struct Gauge: Sendable {
    var label: String
    var percent: Double?
    var text: String
    var resetsAt: Date?
    var kind: GaugeKind = .other
    var expired = false
    var observedAt: Date?
    var source: String?
}

struct Reading: Sendable {
    var id: String
    var title: String
    var account: String? = nil
    var gauges: [Gauge] = []
    var lines: [String] = []
    var state: ReadingState = .ok
    var snapshotAt: Date?
    var fetchedAt: Date = Date()
    var source: String? = nil

    static func merge(previous: Reading?, next: Reading) -> Reading {
        guard let previous, previous.id == next.id, previous.account == next.account else {
            return next
        }
        if next.state == .failure { return next }
        if !next.gauges.isEmpty {
            var merged = next
            merged.gauges = mergeGauges(previous: previous.gauges, next: next.gauges)
            merged.state = max(next.state, worstState(merged.gauges))
            return merged
        }
        guard next.state == .warn, !previous.gauges.isEmpty else { return next }
        var merged = next
        merged.gauges = previous.gauges
        merged.state = max(max(next.state, worstState(merged.gauges)), previous.state)
        return merged
    }

    private static func mergeGauges(previous: [Gauge], next: [Gauge]) -> [Gauge] {
        guard !previous.isEmpty else { return next }
        return next.map { gauge in
            if let old = previous.first(where: { $0.label == gauge.label && $0.kind == gauge.kind }) {
                var merged = gauge
                if merged.observedAt == nil { merged.observedAt = old.observedAt }
                if merged.source == nil { merged.source = old.source }
                return merged
            }
            return gauge
        }
    }
}

protocol Provider: AnyObject, Sendable {
    var id: String { get }
    var title: String { get }
    func fetchAll(manual: Bool) async -> [Reading]
}

extension Provider {
    func fetchAll() async -> [Reading] { await fetchAll(manual: false) }
}

private final class TimeoutGate: @unchecked Sendable {
    private let lock = NSLock()
    private var won = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !won else { return false }
        won = true
        return true
    }
}

func withTimeout<T: Sendable>(_ seconds: Double,
                            _ operation: @escaping @Sendable () async -> T,
                            onTimeout: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let gate = TimeoutGate()
        let work = Task {
            let result = await operation()
            guard !Task.isCancelled, gate.claim() else { return }
            continuation.resume(returning: result)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard gate.claim() else { return }
            work.cancel()
            continuation.resume(returning: onTimeout())
        }
    }
}

extension Reading {
    func asOf(_ now: Date = Date(), grace: TimeInterval = 60) -> Reading {
        guard snapshotAt != nil, state != .off else { return self }
        var out = self
        var any = false
        for i in out.gauges.indices {
            guard let ends = out.gauges[i].resetsAt,
                  ends.addingTimeInterval(grace) < now else { continue }
            out.gauges[i].expired = true
            out.gauges[i].percent = nil
            out.gauges[i].text = "—"
            any = true
        }
        guard any else { return self }
        out.lines.append(L.t("m.expired.hint"))
        let fromGauges = worstState(gauges)
        let floor = state > fromGauges ? state : .ok
        out.state = max(floor, worstState(out.gauges))
        return out
    }

    static func asOfNow(_ list: [Reading]) -> [Reading] { list.map { $0.asOf() } }

    static func failed(_ id: String, _ title: String, _ account: String?, _ message: String) -> Reading {
        Reading(id: id, title: title, account: account, lines: [message], state: .failure)
    }
    static func off(_ id: String, _ title: String, _ account: String?, _ message: String) -> Reading {
        Reading(id: id, title: title, account: account, lines: [message], state: .off)
    }
}

enum Fmt {
    static func span(_ date: Date, now: Date = Date()) -> String {
        let secs = date.timeIntervalSince(now)
        let a = abs(secs)
        if a < 45 { return L.t("t.now") }
        let f = DateComponentsFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.locale = L.locale
        f.calendar = cal
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        if a < 3600 { f.allowedUnits = [.minute] }
        else if a < 86400 { f.allowedUnits = [.hour, .minute] }
        else { f.allowedUnits = [.day, .hour] }
        return f.string(from: a) ?? "\(Int(a))s"
    }

    static func relative(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
        if abs(secs) < 45 { return L.t("t.now") }
        let sp = span(date)
        return secs < 0 ? L.t("t.ago", sp) : L.t("t.in", sp)
    }

    static func money(_ v: Double, _ currency: String) -> String {
        let sym: String
        switch currency.uppercased() {
        case "CNY": sym = "¥"
        case "USD": sym = "$"
        default: sym = currency + " "
        }
        return String(format: "%@%.2f", sym, v)
    }

    static func gb(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

enum RateLimit {
    private static var until: [String: Date] = [:]
    private static let lock = NSLock()

    static func key(host: String, account: String) -> String {
        host.lowercased() + "\u{1}" + account
    }

    static func mark(host: String, account: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        let k = key(host: host, account: account)
        if let existing = RateLimit.until[k] {
            RateLimit.until[k] = max(existing, until)
        } else {
            RateLimit.until[k] = until
        }
    }

    static func mark(id: String, until: Date) {
        mark(host: id, account: "*", until: until)
    }

    static func shouldSkip(host: String, account: String,
                           reason: RefreshReason = .timer,
                           now: Date = Date()) -> Bool {
        if reason == .manual { return false }
        lock.lock(); defer { lock.unlock() }
        let k = key(host: host, account: account)
        guard let until = RateLimit.until[k] else { return false }
        if now >= until {
            RateLimit.until[k] = nil
            return false
        }
        return true
    }

    static func shouldSkip(id: String, now: Date = Date()) -> Bool {
        shouldSkip(host: id, account: "*", reason: .timer, now: now)
    }

    static func retryAfter(header: String?, now: Date = Date()) -> TimeInterval {
        let defaultSeconds: TimeInterval = 300
        let cap: TimeInterval = 86_400
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return defaultSeconds
        }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 {
            return min(seconds, cap)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            return min(max(date.timeIntervalSince(now), 0), cap)
        }
        return defaultSeconds
    }

    static func resetForTests() {
        lock.lock(); defer { lock.unlock() }
        until = [:]
    }
}

func worstState(_ gauges: [Gauge]) -> ReadingState {
    var s = ReadingState.ok
    for g in gauges {
        guard let p = g.percent else { continue }
        if p >= 90 { s = max(s, .nearLimit) } else if p >= 70 { s = max(s, .warn) }
    }
    return s
}

extension ReadingState: Comparable {
    static func < (a: ReadingState, b: ReadingState) -> Bool { a.rawValue < b.rawValue }
}
