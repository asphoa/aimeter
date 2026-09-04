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

    /// Runs the command and returns its raw stdout, or nil if it could not be
    /// started, timed out, or exited non-zero. For the exit code and stderr
    /// text as well, see `attempt`.
    static func run(binary: String, home: String, timeout: TimeInterval = 30) -> Data? {
        let result = attempt(binary: binary, home: home, timeout: timeout)
        return result.exitCode == 0 ? result.stdout : nil
    }

    /// Runs `agy -p "/usage" --output-format json` and reports what happened.
    /// Blocking; call off the main thread.
    static func attempt(binary: String, home: String, timeout: TimeInterval = 30) -> Attempt {
        let result = CommandRun.attempt(
            binary: binary, args: ["-p", "/usage", "--output-format", "json"],
            home: home, timeout: timeout,
            environment: ["AGY_CLI_DISABLE_AUTO_UPDATE": "1"],
            refuseIfRunning: false)
        // Nothing secret in this response - unlike the TUI capture, the
        // print-mode JSON carries no account address or email at all (see
        // the fixture in tools/tests) - so it can be dumped as-is for
        // debugging without redaction.
        writePrivate(result.stdout, to: Config.dir + "/agy-print-last.json")
        return result
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
