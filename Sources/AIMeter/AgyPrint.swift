import Foundation

/// Reads Antigravity's quota through the CLI's own read-only print-mode
/// command: `agy -p "/usage" --output-format json`.
///
/// This is the main path as of v1.0.28, scheduled and manual alike -
/// `AgyTUI`'s pty screen-scrape is now the manual-only fallback. Measured
/// 2026-09-04, n=3: rc=0, ~4s, `status:"SUCCESS"`, spends no quota and
/// leaves no conversation behind (`conversation_id` empty, the conversations
/// directory count unchanged, `usage.total_tokens: 0`). The CLI documents
/// `/usage`, `/quota`, `/credits`, `/model`, `/effort` and `/skills` as
/// read-only in print mode - non-interactive answers with no agent turn
/// started - which is why this is safe to poll hourly where the TUI never
/// was.
///
/// `AgyTUI.binary`'s allowlist and `trustedHome` still gate which binary and
/// HOME this can ever be pointed at - see `AgyProvider`, which calls both
/// before either function here runs. This file only adds a different,
/// cheaper way of driving the same, already-trusted client.
enum AgyPrint {

    /// What one run produced, kept apart from whether it means success: the
    /// caller (`AgyProvider`) needs the exit code and stderr text to tell an
    /// ordinary hiccup from a permission refusal, which is a decision about
    /// *this app's* pause state, not something this file should decide on
    /// its own.
    typealias Attempt = CommandRun.Attempt

    struct SnapshotEnvelope: Codable {
        var account: String
        var home: String
        var observedAt: Date
        var stdout: Data
    }

    /// Runs the command and returns its raw stdout, or nil if it could not be
    /// started, timed out, or exited non-zero. For the exit code and stderr
    /// text as well, see `attempt`.
    static func run(binary: String, home: String, timeout: TimeInterval = 30,
                    locations: AgyFileLocations = .default, account: String = "Default") -> Data? {
        let result = attempt(binary: binary, home: home, timeout: timeout,
                             locations: locations, account: account)
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// Runs `agy -p "/usage" --output-format json` and reports what happened.
    /// Blocking; call off the main thread. Always writes a per-attempt
    /// diagnostic file; only a successful stdout updates the account snapshot.
    @discardableResult
    static func attempt(binary: String, home: String, timeout: TimeInterval = 30,
                        locations: AgyFileLocations = .default, account: String = "Default") -> Attempt {
        let result = CommandRun.attempt(
            binary: binary, args: ["-p", "/usage", "--output-format", "json"],
            home: home, timeout: timeout,
            environment: ["AGY_CLI_DISABLE_AUTO_UPDATE": "1"],
            refuseIfRunning: false)
        let attemptPath = locations.attemptPath(account)
        let diag = (try? JSONEncoder().encode(AttemptDiagnostic(
            account: account, home: home, observedAt: Date(),
            exitCode: result.exitCode, stderr: result.stderr, timedOut: result.timedOut))) ?? Data()
        if (try? writePrivate(diag, to: attemptPath)) == nil {
            Diagnostics.warn("agy print attempt write failed: \(attemptPath)")
        }
        if result.exitCode == 0, !AgyProvider.refused(result.stderr) {
            let envelope = SnapshotEnvelope(account: account, home: home,
                                            observedAt: Date(), stdout: result.stdout)
            if let data = try? JSONEncoder().encode(envelope) {
                if (try? writePrivate(data, to: locations.snapshotPath(account))) == nil {
                    Diagnostics.warn("agy print snapshot write failed: \(locations.snapshotPath(account))")
                }
            }
        }
        return result
    }

    private struct AttemptDiagnostic: Codable {
        var account: String
        var home: String
        var observedAt: Date
        var exitCode: Int32?
        var stderr: String
        var timedOut: Bool
    }

    static func loadSnapshot(at path: String, account: String, home: String) -> (data: Data, observedAt: Date)? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: raw) else { return nil }
        guard envelope.account == account,
              envelope.home == home else { return nil }
        return (envelope.stdout, envelope.observedAt)
    }

    // MARK: - parsing

    private struct Bucket: Decodable {
        var window: String?
        var remaining_fraction: Double?
        var reset_time: String?
    }
    private struct GroupJSON: Decodable {
        var name: String?
        var buckets: [Bucket]?
    }
    private struct CommandData: Decodable {
        var groups: [GroupJSON]?
    }
    private struct Command: Decodable {
        var data: CommandData?
    }
    private struct Response: Decodable {
        var status: String?
        var command: Command?
    }

    /// Only when `status == "SUCCESS"`; walks `command.data.groups[]`. A
    /// bucket missing `window`/`remaining_fraction` is skipped rather than
    /// guessed at, and a group left with neither used% set is dropped -
    /// same "never invent a number" rule the rest of this app follows.
    static func parse(_ data: Data) -> AgyTUI.Result? {
        guard let resp = try? JSONDecoder().decode(Response.self, from: data),
              resp.status == "SUCCESS",
              let groups = resp.command?.data?.groups, !groups.isEmpty else { return nil }

        var out: [AgyTUI.Group] = []
        for g in groups {
            guard let buckets = g.buckets, !buckets.isEmpty else { continue }
            var group = AgyTUI.Group(name: g.name ?? "")
            for b in buckets {
                guard let window = b.window, let remaining = b.remaining_fraction else { continue }
                let used = max(0, min(100, 100 - remaining * 100))
                let resetsAt = b.reset_time.flatMap(parseResetTime)
                switch window {
                case "weekly":
                    group.weeklyUsed = used
                    group.weeklyResets = resetsAt
                case "5h":
                    group.fiveHourUsed = used
                    group.fiveHourResets = resetsAt
                default:
                    break  // an unrecognised window kind - never guessed at
                }
            }
            if group.weeklyUsed != nil || group.fiveHourUsed != nil { out.append(group) }
        }
        return out.isEmpty ? nil : AgyTUI.Result(account: nil, groups: out)
    }

    /// `reset_time` is ISO8601, sometimes with fractional seconds
    /// (`ISO8601DateFormatter`'s default `formatOptions` accepts neither
    /// alone - it is one or the other).
    private static func parseResetTime(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}
