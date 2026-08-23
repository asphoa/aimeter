import Foundation

enum ReadingState: Int {
    case off = -1, ok = 0, warn = 1, error = 2
}

/// One measurable quantity inside a provider (a 5h window, a weekly window, a
/// money balance...). `percent` is "how much is used up", 0...100.
struct Gauge: Sendable {
    var label: String
    var percent: Double?
    var text: String
    var resetsAt: Date?
    /// What this gauge measures. Only the menu bar strip's "by window type"
    /// colour mode reads it; everything else can leave it at `.other`.
    var kind: GaugeKind = .other
}

struct Reading: Sendable {
    var id: String
    var title: String
    /// Account label, shown after the title when a provider has more than one.
    var account: String? = nil
    var gauges: [Gauge] = []
    var lines: [String] = []
    var state: ReadingState = .ok
    var snapshotAt: Date?     // set when the number is a cached snapshot, not live
    var fetchedAt: Date = Date()
}

protocol Provider: AnyObject, Sendable {
    var id: String { get }
    var title: String { get }
    /// One reading per account. Providers with a single account return one.
    ///
    /// `manual` is true only when a person asked for this refresh. A provider
    /// whose only accurate source is a request it should not make on a timer
    /// may make it here and nowhere else - binding the call to a human action
    /// by construction, rather than to a setting someone can forget.
    func fetchAll(manual: Bool) async -> [Reading]
}

extension Provider {
    func fetchAll() async -> [Reading] { await fetchAll(manual: false) }
}

/// Races an async read against a deadline so one stuck endpoint (or a keychain
/// dialog nobody clicks) cannot freeze the whole refresh.
func withTimeout(_ seconds: Double,
                 _ operation: @escaping @Sendable () async -> Reading,
                 onTimeout: @escaping @Sendable () -> Reading) async -> Reading {
    await withTaskGroup(of: Reading.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return onTimeout()
        }
        let first = await group.next() ?? onTimeout()
        group.cancelAll()
        return first
    }
}

/// Reads a credential from a file that is either a raw key or a JSON blob.
func readKey(file: String?, jsonField: String? = nil) -> String? {
    guard let file else { return nil }
    // "env:NAME" reads an environment variable instead of a file, which is how
    // most vendors' own CLIs expect their key to be supplied.
    if file.hasPrefix("env:") {
        return ProcessInfo.processInfo.environment[String(file.dropFirst(4))]
    }
    guard let raw = try? String(contentsOfFile: expand(file), encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else {
        return trimmed.isEmpty ? nil : trimmed
    }
    guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return nil }
    if let field = jsonField, let root = obj as? [String: Any], let node = root[field] {
        if let s = node as? String { return s }
        return findString(in: node, names: ["api_key", "key", "token", "secret"])
    }
    return findString(in: obj, names: ["api_key", "key", "token", "access_token", "accessToken"])
}

extension Reading {
    static func failed(_ id: String, _ title: String, _ account: String?, _ message: String) -> Reading {
        Reading(id: id, title: title, account: account, lines: [message], state: .error)
    }
    static func off(_ id: String, _ title: String, _ account: String?, _ message: String) -> Reading {
        Reading(id: id, title: title, account: account, lines: [message], state: .off)
    }
}

// MARK: - small shared helpers

enum Fmt {
    /// Localised "in 4h 51m" / "2 hr ago". DateComponentsFormatter does the
    /// language-specific unit names, so this stays correct in every language
    /// the table covers without a per-language special case.
    static func relative(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
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
        let span = f.string(from: a) ?? "\(Int(a))s"
        return secs < 0 ? L.t("t.ago", span) : L.t("t.in", span)
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

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func json(_ req: URLRequest) async throws -> (Any, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AIMeter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: L.t("e.nothttp")])
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        return (obj, http)
    }

    static func get(_ url: String, bearer: String? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.timeoutInterval = timeout
        if let b = bearer { r.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        return r
    }
}

/// Read the last `limit` bytes of a file - session logs get large and we only
/// ever care about the most recent record.
func tailBytes(_ path: String, limit: Int = 512 * 1024) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return nil }
    let start = size > UInt64(limit) ? size - UInt64(limit) : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd() else { return nil }
    return String(data: data, encoding: .utf8)
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Writes a file only this user can read, creating its directory the same way.
///
/// Everything this app writes describes which services an account has and where
/// its credentials live - the sort of thing that gets pasted into a chat window
/// while debugging. None of it should be readable by other local accounts.
func writePrivate(_ data: Data, to path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
    // Written to a temporary neighbour first: a crash mid-write must not leave
    // a half-parsed settings file behind.
    let tmp = path + ".tmp"
    guard (try? data.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
    _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path),
                                               withItemAt: URL(fileURLWithPath: tmp))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}
