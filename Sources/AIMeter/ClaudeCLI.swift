import Foundation

/// Presses the button the user is told to press, on their behalf.
///
/// Claude Code's access token lasts a few hours; the refresh token behind it
/// lasts days. Only the CLI trades one for the other, and it does so when it
/// runs. A menu bar app that never launches the CLI therefore watches the
/// access token go stale while the sign-in behind it is perfectly healthy, and
/// the only cure is to run `claude` once — which this app's own row correctly
/// said, and which its "Check now" button then could not do. Every other row's
/// button performs a live check that can succeed; this one alone re-read a
/// keychain item nothing had changed, so pressing it repeatedly did nothing.
/// For a user who keeps a menu bar app precisely so as not to open a terminal,
/// that is a dead end dressed as a control.
///
/// What this does *not* do is refresh the token itself. The refresh token sits
/// in the same blob and the exchange is one POST, but that endpoint is
/// Anthropic's private one and answers only to the CLI's own client_id;
/// replaying it would be impersonating another application's authentication,
/// and the exchange rotates the refresh token, so this app would have to write
/// the replacement back into the CLI's keychain item while a real `claude`
/// might be doing the same. Losing that race logs the user out for real.
///
/// Instead it runs the genuine, vendor-shipped binary and lets that program do
/// its own refresh, then re-reads the keychain. This app is only pressing the
/// button. Same line this project drew for Antigravity, and a milder version of
/// it: non-interactive subcommands rather than a screen-scraped TUI.
///
/// ## What v1.0.10 got wrong, and how it was found out
///
/// The first version of this ran `claude auth status --json` on the theory that
/// starting the CLI at all is what refreshes the token. That theory was written
/// down as unconfirmed at the time - the one manual test that appeared to
/// support it had a real `claude` session running alongside it, which is a
/// confound, not a control. Measured properly on 2026-08-27 against a genuinely
/// expired access token, twice, once through this app's own `--once --manual`
/// path and once by hand outside the app:
///
///   - `claude auth status --json` returns in 0.45s, prints `"loggedIn": true`,
///     and leaves the expired token in the keychain exactly as it found it. It
///     is a local read. It never touches the network, so it never has occasion
///     to refresh anything.
///   - `claude -p "..."` immediately afterwards succeeds, and the token in the
///     keychain is refreshed.
///
/// So the button shipped non-functional and stayed that way, reporting "claude
/// ran, but the stored token is still expired" - which was true, and useless.
/// The refresh is driven by the CLI needing a working token for a live request,
/// not by the CLI starting. Only a command that makes one will do.
///
/// ## Why it costs something now, and how little
///
/// There is no `claude auth refresh`; `auth` has exactly login, logout and
/// status (checked against 2.1.246). So the second step has to be a real
/// request, and a real request is charged against the user's own window - a new
/// kind of side effect for a button called "Check now", and the reason the
/// row's own text now says so before it happens.
///
/// It is made as small as the CLI allows. Measured on 2026-08-27, plain
/// `claude -p "hi"` costs **57,250 cache-creation input tokens** ($0.229 at list
/// price): the default system prompt, the user's CLAUDE.md, every skill and
/// every MCP tool definition. With the arguments below it costs **264 input and
/// 83 output tokens on Haiku** ($0.00068) - about 190x less, and comparable to
/// the 1-output-token probe this provider already sends on every ordinary
/// refresh. That only happens on a manual click that finds a stale token.
///
/// Manual only. See ClaudeProvider for the gate; a timer must never launch
/// another program.
enum ClaudeCLI {

    /// Where the CLI is, since a GUI app inherits none of a login shell's PATH.
    ///
    /// Only these are accepted, and a configured path must be one of them: the
    /// settings file is plain text, so honouring an arbitrary path from it
    /// would let anything able to edit that file have this app run a binary of
    /// its choosing, as the user. The list is the installers' own destinations
    /// — the native installer's `~/.local/bin`, npm/Homebrew's two prefixes,
    /// and the legacy local install. A non-standard install should be
    /// symlinked into one of these.
    static let allowedBinaries = ["~/.local/bin/claude", "/usr/local/bin/claude",
                                  "/opt/homebrew/bin/claude", "~/.claude/local/claude"]

    static func binary(_ configured: String?) -> String? {
        let allowed = allowedBinaries.map(expand)
        if let configured, !configured.isEmpty {
            let wanted = expand(configured)
            guard allowed.contains(wanted),
                  FileManager.default.isExecutableFile(atPath: wanted) else { return nil }
            return wanted
        }
        return allowed.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The CLI's own keychain item. Nothing else may cause this app to launch
    /// the CLI: an account holding a pasted API key is not refreshed by running
    /// `claude`, so doing so would be a subprocess spawned for no possible
    /// benefit, and a surprise to whoever pressed the button.
    ///
    /// Deliberately not extended to `~/.claude/.credentials.json`, the file the
    /// CLI uses where there is no keychain: this app is macOS-only, where the
    /// keychain is what the CLI writes. Accepting the file here would have
    /// added a branch that reads as supported and can never run.
    static let credentialService = "Claude Code-credentials"

    static func ownsCLICredential(_ a: AccountSpec) -> Bool {
        a.keychainService == credentialService
    }

    /// Step one, and the reason the expensive step stays safe.
    ///
    /// Read-only by name and by measurement: with no credential present it
    /// prints `"loggedIn": false` and exits 1 without offering to log in, so
    /// the worst case is a report, never a browser window. It makes no model
    /// request, so nothing here is charged against the window it is reporting
    /// on, and it answers in under half a second.
    ///
    /// It refreshes nothing - that is the bug this file exists to record. It is
    /// kept anyway, as the gate in front of step two: this app must never spawn
    /// a *prompt* on a machine that turns out to be signed out, where the CLI's
    /// response to a missing credential is its own business and could reasonably
    /// be a browser window. Asking a free, local, proven-harmless question first
    /// is how the "worst case is a report" guarantee survives step two.
    static let statusArguments = ["auth", "status", "--json"]

    /// Step two: the one that actually refreshes the token, because it is the
    /// one that makes the CLI need a working token.
    ///
    /// Every argument is here to make the request smaller or to make sure a
    /// menu-bar click cannot turn into something a menu-bar click should not do.
    ///
    ///   - `-p .` - print mode, one turn, then exit. A full stop is the shortest
    ///     prompt that is still a prompt.
    ///   - `--tools ""` - **the safety-critical one.** Without it, clicking a
    ///     menu item would start a Claude session holding Bash and Edit in the
    ///     user's home directory. With it the subprocess can emit text and
    ///     nothing else. Pinned by test for that reason.
    ///   - `--safe-mode` - no hooks, plugins, MCP servers, custom agents or
    ///     CLAUDE.md. Auth, by the CLI's own documentation, still works
    ///     normally, which is the whole point. This is both the bulk of the cost
    ///     saving and a second reason the run cannot set the user's own
    ///     automation going behind a button labelled "Check now".
    ///   - `--system-prompt` - replaces the default one. Two effects: the
    ///     request stops carrying the user's machine and project context off to
    ///     the API, and the token count drops by two orders of magnitude.
    ///   - `--model haiku` - the alias, deliberately not `claudeProbeModel`.
    ///     That setting comes out of a plain-text file this project treats as
    ///     untrusted, and a pinned dated id rots; an alias cannot.
    ///   - `--effort low` - the reply is thrown away, so thinking tokens bought
    ///     nothing. Measured: 194 output tokens without it, 83 with.
    ///   - `--max-budget-usd 0.02` - a ceiling, ~30x the measured cost. If a
    ///     future CLI or a stuck loop makes this cost more than a rounding
    ///     error, it stops instead.
    ///   - `--no-session-persistence` - a button press must not leave a
    ///     transcript in the user's session history.
    ///   - `--output-format json` - so a failure can be read rather than
    ///     guessed at.
    ///
    /// These flags need a reasonably current CLI (verified against 2.1.246). An
    /// older one rejects an unknown option and exits non-zero, which is reported
    /// as itself, with its own message - see `promptFailure`. It is deliberately
    /// not retried with a smaller flag set: the only argument list old enough to
    /// be universally safe is bare `-p`, which costs 190x more, and quietly
    /// spending 57,000 tokens where the user was promised 300 is exactly the
    /// "produce something else under the same name" failure this project's
    /// pipeline conventions exist to forbid.
    static let refreshArguments = [
        "-p", ".",
        "--model", "haiku",
        "--safe-mode",
        "--tools", "",
        "--system-prompt", "Reply with the single character: .",
        "--effort", "low",
        "--max-budget-usd", "0.02",
        "--no-session-persistence",
        "--output-format", "json"
    ]

    /// The environment the subprocess gets - built rather than inherited,
    /// because the parent's environment can carry an `ANTHROPIC_API_KEY` and a
    /// `CLAUDE_CONFIG_DIR` exported by whatever shell launched this app, either
    /// of which would send the CLI to a different credential than the one the
    /// row is about.
    ///
    /// `USER` is not decoration. The CLI's keychain item is filed under the
    /// account name, and measured on 2026-08-25: started without `USER` the
    /// same binary reports `loggedIn: false` on a machine that is signed in,
    /// and refreshes nothing. Copying the "build it from nothing" habit
    /// verbatim would have produced a button that still did nothing, reporting
    /// the same stale message it did before - a silent no-op, the failure this
    /// whole change exists to remove.
    ///
    /// The two disable flags keep the run to what was asked for. `claude`
    /// checks for and installs its own updates on start; a menu click must not
    /// quietly pull down a new several-hundred-megabyte CLI build.
    static func environment(home: String, user: String, lang: String?) -> [String: String] {
        var env = [
            "HOME": home,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
            "USER": user,
            "LOGNAME": user,
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
        ]
        if let lang { env["LANG"] = lang }
        return env
    }

    /// What the run established, in the terms that decide what the user reads.
    /// Deliberately three cases and not a Bool: "the CLI could not be run",
    /// "the CLI says this machine is signed out" and "the CLI ran and the
    /// credential is still stale" call for three different things from the
    /// user, and collapsing them into one would put this row back where it
    /// started - a message that does not match what happened.
    enum Outcome: Equatable {
        /// Ran, and reported a signed-in account. This says the machine has a
        /// credential worth trying to refresh - nothing more. It was once read
        /// as "and therefore the token has just been refreshed", which is how
        /// the broken version passed its own review.
        case signedIn
        /// Ran cleanly, and reported no signed-in account on this machine.
        case signedOut
        /// Could not be run, timed out, or printed something unrecognisable.
        case failed(String)
    }

    /// Reads the outcome off the run rather than off the exit code alone: the
    /// CLI exits 1 both when it is signed out and when it fails, and those are
    /// not the same message.
    static func outcome(output: String, exitCode: Int32) -> Outcome {
        guard let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let d = obj as? [String: Any],
              let loggedIn = d["loggedIn"] as? Bool else {
            return .failed(exitCode == 0 ? L.t("c.refresh.unreadable") : "exit \(exitCode)")
        }
        return loggedIn ? .signedIn : .signedOut
    }

    /// What the prompt run complained about, or nil if it did not.
    ///
    /// Advisory, and only ever advisory. The verdict on whether the refresh
    /// worked is the keychain, read afterwards - see ClaudeProvider. Deciding
    /// from a subprocess's own report whether the thing it was run for happened
    /// is precisely the mistake that let the broken version ship: `auth status`
    /// said `"loggedIn": true` every time, and the token stayed expired every
    /// time. So this returns a string to put in front of the user when the run
    /// went wrong, not a judgement on the outcome.
    ///
    /// `error` is the CLI's own stderr, which is where an argument this build
    /// does not recognise gets explained. Reporting a bare "exit 1" for that
    /// would leave the user with no way to tell a rejected flag from a network
    /// failure.
    static func promptFailure(output: String, error: String, exitCode: Int32) -> String? {
        if let data = output.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let d = obj as? [String: Any], let failed = d["is_error"] as? Bool {
            guard failed else { return nil }
            let why = (d["api_error_status"] as? String) ?? (d["subtype"] as? String)
                ?? (d["result"] as? String)
            return brief(why ?? "error")
        }
        let complaint = brief(error)
        if !complaint.isEmpty { return complaint }
        return exitCode == 0 ? L.t("c.refresh.unreadable") : "exit \(exitCode)"
    }

    /// One redacted line, short enough to sit on a menu row.
    static func brief(_ s: String) -> String {
        let one = redact(s).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return one.count > 160 ? String(one.prefix(160)) + "…" : one
    }

    /// The status output names the account, its organisation and that
    /// organisation's id; the prompt output carries session identifiers. These
    /// files are written so a failure can be looked at instead of guessed at,
    /// and they are the files most likely to be pasted somewhere while
    /// debugging, so those come out before either touches disk.
    static func redact(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<redacted>", options: .regularExpression)
        for field in ["email", "orgId", "orgName", "organizationId", "accountUuid", "userId",
                      "session_id", "sessionId", "uuid", "parent_tool_use_id"] {
            out = out.replacingOccurrences(
                of: "(\"\(field)\"\\s*:\\s*)\"[^\"]*\"",
                with: "$1\"<redacted>\"", options: .regularExpression)
        }
        return out
    }

    /// Step one. Blocking; call off the main thread.
    static func status(binary path: String, home: String,
                       timeout: TimeInterval = 20) -> Outcome {
        switch execute(binary: path, arguments: statusArguments, home: home,
                       timeout: timeout, dumpTo: "claude-cli-last.json") {
        case .couldNotRun(let why): return .failed(why)
        case .ran(let run): return outcome(output: run.output, exitCode: run.code)
        }
    }

    /// Step two. Blocking; call off the main thread. Nil means it did not
    /// complain - not that the token was refreshed, which only the keychain can
    /// say.
    ///
    /// The longer ceiling is because this one waits on a model, not on a local
    /// file read. Measured at 2.5s end to end on 2026-08-27; 30 seconds is the
    /// point at which something has gone wrong rather than slowly.
    static func prompt(binary path: String, home: String,
                       timeout: TimeInterval = 30) -> String? {
        switch execute(binary: path, arguments: refreshArguments, home: home,
                       timeout: timeout, dumpTo: "claude-cli-last-refresh.json") {
        case .couldNotRun(let why): return why
        case .ran(let run):
            return promptFailure(output: run.output, error: run.error, exitCode: run.code)
        }
    }

    struct Completed {
        let output: String
        let error: String
        let code: Int32
    }

    /// Either the program ran and said something, or it never got to say
    /// anything at all. Kept apart because they are different messages: one
    /// quotes the CLI, the other quotes this app.
    enum Attempt {
        case ran(Completed)
        case couldNotRun(String)
    }

    /// Runs the binary and reports what it printed. Blocking; call off the main
    /// thread. `.failure` is reserved for "it did not get to say anything" -
    /// could not be started, or had to be killed.
    static func execute(binary path: String, arguments: [String], home: String,
                        timeout: TimeInterval, dumpTo file: String) -> Attempt {
        let sem = DispatchSemaphore(value: 0)
        var attempt: Attempt = .couldNotRun("launch failed")
        Task {
            let out = await ProcessRunner.run(
                binary: path, args: arguments,
                env: environment(home: home, user: NSUserName(),
                                 lang: ProcessInfo.processInfo.environment["LANG"]),
                cwd: home, stdinClosed: true,
                deadline: .seconds(max(1, timeout)))
            let text = String(decoding: out.stdout, as: UTF8.self)
            let err = String(decoding: out.stderr, as: UTF8.self)
            if out.timedOut {
                attempt = .couldNotRun(L.t("c.refresh.timeout"))
            } else {
                attempt = .ran(Completed(output: text, error: err, code: out.exitCode))
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout + 5)
        if case .ran(let run) = attempt {
            if (try? writePrivate(Data(redact(run.output).utf8), to: Config.dir + "/" + file)) == nil {
                Diagnostics.warn("claude CLI capture write failed: \(file)")
            }
        }
        return attempt
    }
}
