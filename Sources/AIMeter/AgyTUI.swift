import Foundation

/// Reads Antigravity's quota by driving the vendor's own client.
///
/// The numbers exist in exactly one place: the `/usage` panel of the agy TUI.
/// There is no endpoint a third party can ask — the credential the CLI stores
/// is not an OAuth access token the internal quota endpoint accepts (measured
/// 2026-08-23: HTTP 401), so producing one would mean impersonating the client.
///
/// This does the opposite: it launches the real client in a pseudo-terminal,
/// types `/usage`, and reads the panel it draws. Every request to Google is
/// made by the genuine client with its own credentials and headers. It is slow
/// (tens of seconds) and it is screen-scraping, so it runs only when a person
/// asks for it — never on a timer.
enum AgyTUI {

    struct Group {
        var name: String
        var weeklyUsed: Double?
        var fiveHourUsed: Double?
        var weeklyResets: Date?
    }

    struct Result {
        var account: String?
        var groups: [Group]
    }

    /// Where the CLI is, since a GUI app inherits none of a login shell's PATH.
    ///
    /// Only these locations are accepted, and a configured path must be one of
    /// them. The settings file is plain text: honouring an arbitrary path from
    /// it would mean anything able to edit that file could have this app run a
    /// binary of its choosing, as the user. A non-standard install should be
    /// symlinked into one of these instead.
    static let allowedBinaries = ["~/.local/bin/agy", "/usr/local/bin/agy", "/opt/homebrew/bin/agy"]

    static func binary(_ configured: String?) -> String? {
        let allowed = allowedBinaries.map(expand)
        if let configured {
            let wanted = expand(configured)
            guard allowed.contains(wanted),
                  FileManager.default.isExecutableFile(atPath: wanted) else { return nil }
            return wanted
        }
        return allowed.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func read(binary path: String, home: String, timeout: TimeInterval = 90) -> Result? {
        var master: Int32 = 0, slave: Int32 = 0
        // The panel is only drawn if the terminal claims a usable size.
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        // Built from nothing rather than inherited: the parent environment can
        // carry API keys exported in whatever shell launched the app, and a
        // subprocess that only needs to draw a quota panel has no use for them.
        process.environment = [
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "TERM": "xterm-256color",
            "COLUMNS": "160",
            "LINES": "50",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        ]
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do { try process.run() } catch { close(master); close(slave); return nil }
        close(slave)

        var raw = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var asked = false
        var settledAt: Date?
        var grace: Date?

        var lastCheck = Date.distantPast
        while Date() < deadline {
            var set = fd_set()
            fdZero(&set)
            fdSet(master, &set)
            var tv = timeval(tv_sec: 0, tv_usec: 50_000)
            let ready = select(master + 1, &set, nil, nil, &tv)
            if ready > 0 {
                // Drain everything available before doing anything else. The
                // pty buffer is a few kilobytes and the TUI redraws constantly;
                // scanning the accumulated text on every pass was slow enough
                // that the buffer overran and output was silently lost - which
                // is what truncated the figures mid-character.
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = Darwin.read(master, &buf, buf.count)
                    if n <= 0 { break }
                    raw.append(contentsOf: buf[0..<n])
                    if n < buf.count { break }
                }
                if settledAt == nil, raw.count > 500 { settledAt = Date() }
            }

            if !asked, let settled = settledAt, Date().timeIntervalSince(settled) > 9 {
                let cmd = Array("/usage\r".utf8)
                _ = cmd.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
                asked = true
                continue
            }

            // The expensive part, at most once a second.
            guard asked, Date().timeIntervalSince(lastCheck) > 1 else { continue }
            lastCheck = Date()
            let text = strip(String(decoding: raw, as: UTF8.self))
            if percentCount(text) >= 4, grace == nil { grace = Date() }
            if let g = grace, Date().timeIntervalSince(g) > 1.2 { break }
        }

        _ = "\u{03}".utf8.withContiguousStorageIfAvailable { Darwin.write(master, $0.baseAddress, $0.count) }
        process.terminate()
        close(master)

        let text = strip(String(decoding: raw, as: UTF8.self))
        // Kept so a parsing failure can be looked at rather than guessed at -
        // but this is a capture of the client's own screen, so the account
        // address comes out before it touches the disk. It is the file most
        // likely to be pasted somewhere while debugging.
        let redacted = text.replacingOccurrences(
            of: #"(Account:\s*)\S+"#, with: "$1<redacted>", options: .regularExpression)
        writePrivate(Data(redacted.utf8), to: Config.dir + "/agy-tui-last.txt")
        return parse(text)
    }

    /// How many "] 99.76%" figures the panel has drawn so far.
    private static func percentCount(_ s: String) -> Int {
        var count = 0
        var search = s.startIndex..<s.endIndex
        while let r = s.range(of: #"\]\s*\d{1,3}(\.\d+)?%"#, options: .regularExpression, range: search) {
            count += 1
            search = r.upperBound..<s.endIndex
        }
        return count
    }

    /// Removes the escape sequences a TUI uses to position and colour text.
    ///
    /// The patterns use the regex engine's own \x1B rather than Swift's
    /// \u{1B}: these are raw strings, where \u{1B} is five literal characters
    /// and matches nothing — which is exactly how this failed the first time.
    static func strip(_ s: String) -> String {
        var out = s
        for pattern in [#"\x1B\[[0-9;?<>=]*[ -/]*[@-~]"#,   // CSI
                        #"\x1B\][^\x07]*(\x07|\x1B\\)"#,   // OSC
                        #"\x1B[()#][0-9A-Za-z]"#,
                        #"\x1B[=><]"#,
                        #"\x1B"#] {
            out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return out
    }

    static func parse(_ text: String) -> Result? {
        // A terminal uses CR, LF and CRLF interchangeably as it repositions the
        // cursor. Splitting on LF alone glued a heading to the line beneath it,
        // which is why the group headings never matched.
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.contains(where: { $0.contains("Limit Remaining") }) else { return nil }

        var account: String?
        var groups: [Group] = []
        var current: Group?
        var pending: String?      // which limit the next percentage belongs to

        func flush() {
            if let c = current, c.weeklyUsed != nil || c.fiveHourUsed != nil { groups.append(c) }
        }

        for line in lines {
            // .whitespaces does NOT include carriage return, and a pty emits
            // CRLF - trimming with it left every line ending in \r, so suffix
            // matches silently failed.
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if account == nil, let r = t.range(of: "Account: ") {
                account = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                continue
            }
            // Group headings are the only all-caps lines ending in MODELS.
            if t.hasSuffix("MODELS"), t == t.uppercased(), t.count < 60 {
                flush()
                current = Group(name: t.replacingOccurrences(of: " MODELS", with: ""))
                pending = nil
                continue
            }
            if t.contains("Weekly Limit Remaining") { pending = "weekly"; continue }
            if t.contains("Five Hour Limit Remaining") { pending = "fivehour"; continue }

            if let which = pending,
               let m = t.range(of: #"(\d{1,3}(\.\d+)?)%"#, options: .regularExpression) {
                let remaining = Double(t[m].dropLast()) ?? 0
                // The panel reports what is left; everything else here counts
                // what has been used.
                let used = max(0, min(100, 100 - remaining))
                if which == "weekly" { current?.weeklyUsed = used } else { current?.fiveHourUsed = used }
                pending = nil
                continue
            }
            if t.contains("Refreshes in"), current?.weeklyResets == nil {
                current?.weeklyResets = parseRefresh(t)
            }
        }
        flush()
        return groups.isEmpty ? nil : Result(account: account, groups: groups)
    }

    /// "Refreshes in 146h 43m" -> a date.
    private static func parseRefresh(_ s: String) -> Date? {
        var seconds: TimeInterval = 0
        var found = false
        for (pattern, unit) in [(#"(\d+)d"#, 86400.0), (#"(\d+)h"#, 3600.0), (#"(\d+)m"#, 60.0)] {
            guard let r = s.range(of: pattern, options: .regularExpression),
                  let n = Double(s[r].dropLast()) else { continue }
            seconds += n * unit
            found = true
        }
        return found ? Date().addingTimeInterval(seconds) : nil
    }
}

// fd_set has no usable API from Swift; these are the two operations needed.
private func fdZero(_ set: inout fd_set) {
    withUnsafeMutableBytes(of: &set) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let index = Int(fd) / 32
    let bit = Int32(1) << (Int32(fd) % 32)
    withUnsafeMutableBytes(of: &set) { raw in
        let words = raw.bindMemory(to: Int32.self)
        words[index] |= bit
    }
}
