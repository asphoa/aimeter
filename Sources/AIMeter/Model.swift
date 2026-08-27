import Foundation

enum ReadingState: Int {
    case off = -1, ok = 0, warn = 1, nearLimit = 2, failure = 3
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
    /// Set by `Reading.asOf` when this gauge's own window ended after the
    /// snapshot was taken. Its `percent` is cleared at the same time, so
    /// nothing draws a bar for it; this flag is what tells the panel to draw an
    /// empty track and a dash rather than treat it as a money balance.
    var expired = false
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
    // Do not use a task group for this race.  Cancelling a child task does not
    // make a structured task group return: its scope still waits for every
    // child to finish.  A keychain prompt, or a transport which ignores
    // cancellation, would therefore turn a supposed timeout into an infinite
    // wait.  The detached operation may finish later, but the one-shot gate
    // makes it unable to alter the already returned reading.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var won = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !won else { return false }
            won = true
            return true
        }
    }
    let gate = Gate()
    return await withCheckedContinuation { continuation in
        let work = Task.detached(priority: .utility) {
            let result = await operation()
            if gate.claim() { continuation.resume(returning: result) }
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, gate.claim() else { return }
            work.cancel()
            continuation.resume(returning: onTimeout())
        }
    }
}

/// Reads a credential file's raw contents - a bare key, or a JSON blob still
/// unparsed, exactly as `Keychain.genericPassword` returns a keychain item's
/// raw contents. Left to the caller (`Credential.blob`/`read`/`expiry`) to
/// unwrap, so a keyFile-backed account is narrowed and field-matched the same
/// way a keychain-backed one is, rather than by a second, divergent copy of
/// that logic living here.
func readKey(file: String?) -> String? {
    guard let file else { return nil }
    // "env:NAME" reads an environment variable instead of a file, which is how
    // most vendors' own CLIs expect their key to be supplied.
    if file.hasPrefix("env:") {
        return ProcessInfo.processInfo.environment[String(file.dropFirst(4))]
    }
    guard let raw = try? String(contentsOfFile: expand(file), encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

extension Reading {
    /// This reading as it stands *now*, rather than as it stood when it was
    /// captured.
    ///
    /// A snapshot ages at a rate the reader cannot see, because the rate
    /// depends on the window each figure describes rather than on the snapshot.
    /// Fifteen hours off a weekly window is a rounding error; fifteen hours off
    /// a five-hour window is two or three complete cycles, and the number is
    /// then not stale but *wrong* - it describes a window that no longer
    /// exists. Measured on 2026-08-27 against ChatGPT's own panel: Codex's
    /// weekly figure agreed exactly (27%, resetting 2 September) off a snapshot
    /// taken the previous afternoon, while the five-hour figure from the same
    /// snapshot read 84% against a live 0%. Both came from one correctly parsed
    /// line; only one of them still meant anything, and the row's single
    /// "snapshot · 15h ago" label said nothing about which.
    ///
    /// The tell is in the data itself and needs no guessing: the vendor states
    /// each window's `resets_at`. Once that moment has passed, this app knows
    /// the cycle it measured has been replaced, and knows it cannot say by what.
    /// So the figure goes, and the label says the window ended. Suppressing it
    /// costs one number nobody could have used; keeping it is a specific,
    /// confident, wrong percentage - the failure this project treats as worse
    /// than producing less (see the pipeline conventions in CLAUDE.md).
    ///
    /// Only snapshot-backed readings are touched. A live reading's reset time
    /// arrives from the same response as its percentage, so a moment in the
    /// past there means clock skew, not a spent cycle - and blanking a number
    /// that was accurate a second ago would be a regression, not a fix. The
    /// grace period covers the same skew for snapshots.
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
        // Recomputed rather than kept: a dead window that read 84% left this
        // row amber, which is the same claim as the number, made in colour.
        // Anything the gauges alone did not justify - a vendor's own
        // "rate limit reached" flag, say - was set by something else and stays.
        let fromGauges = worstState(gauges)
        let floor = state > fromGauges ? state : .ok
        out.state = max(floor, worstState(out.gauges))
        return out
    }

    /// Every place that shows a reading goes through this, so a snapshot is
    /// aged where it is drawn rather than where it was fetched: a five-hour
    /// window can lapse between two refreshes, and the panel must not still be
    /// claiming a percentage for it when it does.
    static func asOfNow(_ list: [Reading]) -> [Reading] { list.map { $0.asOf() } }

    static func failed(_ id: String, _ title: String, _ account: String?, _ message: String) -> Reading {
        Reading(id: id, title: title, account: account, lines: [message], state: .failure)
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

    /// Returns nil rather than trapping: some of these strings come from the
    /// settings file, and a value that cannot be parsed must fail one reading,
    /// not crash the app on every refresh.
    static func get(_ url: String, bearer: String? = nil, timeout: TimeInterval = 20) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        return get(u, bearer: bearer, timeout: timeout)
    }

    static func get(_ url: URL, bearer: String? = nil, timeout: TimeInterval = 20) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        if let b = bearer { r.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        return r
    }
}

/// Read the last `limit` bytes of a file - session logs get large and we only
/// ever care about the most recent record.
///
/// Seeking to a byte offset lands in the middle of a character whenever the
/// text there is not ASCII, and `String(data:encoding:.utf8)` is strict: one
/// stray continuation byte at the front and it returns nil for the entire
/// window. The caller then has no tail at all and moves on to an older file, so
/// a single misaligned byte silently promoted a stale reading to the current
/// one - with no error anywhere, because nothing had failed.
///
/// This is not a rare alignment either, in logs full of CJK. Measured on this
/// machine on 2026-08-27 across the 116 Codex rollout files larger than the
/// window: 7 of them, 6%, decode to nil on their own tail, every one of them
/// "invalid start byte at position 0". One was written the same afternoon as
/// the reading the user reported as wrong.
///
/// So: skip the partial line the cut landed in - which is also, by
/// construction, a character boundary - and decode what is left, replacing
/// anything still malformed rather than discarding the file over it. A damaged
/// line fails to parse on its own and costs that one record; a nil tail costs
/// every record in the file, including the newest one in existence.
func tailBytes(_ path: String, limit: Int = 512 * 1024) -> String? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return nil }
    let start = size > UInt64(limit) ? size - UInt64(limit) : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd() else { return nil }
    var slice = data[data.startIndex...]
    // Only when the read began mid-file: a whole file starts on a boundary and
    // its first line is a real one, not the tail of somebody else's.
    if start > 0, let nl = slice.firstIndex(of: 0x0A) {
        slice = slice[slice.index(after: nl)...]
    }
    return String(decoding: slice, as: UTF8.self)
}

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Accepts a HOME from the settings file only if it is a directory this user
/// owns which already contains what it claims to.
///
/// Whitelisting the binary is undercut while the settings file can still steer
/// that binary with an attacker-populated HOME; requiring the directory and its
/// marker to exist already means a file handed over on its own cannot conjure
/// one.
func trustedHome(_ path: String, marker: String) -> String? {
    let home = expand(path)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: home, isDirectory: &isDir), isDir.boolValue,
          FileManager.default.fileExists(atPath: home + "/" + marker),
          let attrs = try? FileManager.default.attributesOfItem(atPath: home),
          (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
    return home
}

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
