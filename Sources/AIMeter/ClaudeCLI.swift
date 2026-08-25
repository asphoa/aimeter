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
/// Instead it runs the genuine, vendor-shipped binary with its own read-only
/// status subcommand and lets that program do whatever it already does on every
/// start, then re-reads the keychain. This app is only pressing the button.
/// Same line this project drew for Antigravity, and a milder version of it:
/// one non-interactive subcommand rather than a screen-scraped TUI.
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
    /// CLI uses where there is no keychain. This app is macOS-only, where the
    /// keychain is what the CLI writes; and measured while building this, a
    /// key-file account carries no expiry at all, because `Credential.blob`
    /// hands that path to `readKey`, which returns the extracted token rather
    /// than the blob it came from. Accepting the file here would have added a
    /// branch that reads as supported and can never run.
    static let credentialService = "Claude Code-credentials"

    static func ownsCLICredential(_ a: AccountSpec) -> Bool {
        a.keychainService == credentialService
    }

    /// Read-only by name and by measurement: with no credential present it
    /// prints `"loggedIn": false` and exits 1 without offering to log in, so
    /// the worst case is a report, never a browser window. It makes no model
    /// request, so nothing here is charged against the window it is reporting
    /// on - unlike the probe this provider otherwise sends.
    static let arguments = ["auth", "status", "--json"]

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
    /// Deliberately four cases and not a Bool: "the CLI could not be run",
    /// "the CLI says this machine is signed out" and "the CLI ran and the
    /// credential is still stale" call for three different things from the
    /// user, and collapsing them into one would put this row back where it
    /// started - a message that does not match what happened.
    enum Outcome: Equatable {
        /// Ran, and reported a signed-in account. Whatever it left in the
        /// keychain is now the current state; re-read it.
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

    /// The status output names the account, its organisation and that
    /// organisation's id. This file is written so a failure can be looked at
    /// instead of guessed at, and it is the file most likely to be pasted
    /// somewhere while debugging, so those come out before it touches disk.
    static func redact(_ s: String) -> String {
        var out = s.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<redacted>", options: .regularExpression)
        for field in ["email", "orgId", "orgName", "organizationId", "accountUuid", "userId"] {
            out = out.replacingOccurrences(
                of: "(\"\(field)\"\\s*:\\s*)\"[^\"]*\"",
                with: "$1\"<redacted>\"", options: .regularExpression)
        }
        return out
    }

    /// Runs it. Blocking; call off the main thread.
    static func run(binary path: String, home: String, timeout: TimeInterval = 20) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = environment(home: home, user: NSUserName(),
                                          lang: ProcessInfo.processInfo.environment["LANG"])
        // No terminal, and a stdin that is already at end of file: anything
        // that decided to ask a question gets an answer immediately instead of
        // waiting for one that is never coming.
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return .failed(error.localizedDescription) }

        // Drained on another thread so a subprocess that fills the pipe cannot
        // deadlock against a parent that is waiting for it to exit.
        let box = Drain()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            _ = drained.wait(timeout: .now() + 2)
            return .failed(L.t("c.refresh.timeout"))
        }
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)

        let text = String(decoding: box.data, as: UTF8.self)
        writePrivate(Data(redact(text).utf8), to: Config.dir + "/claude-cli-last.json")
        return outcome(output: text, exitCode: process.terminationStatus)
    }
}

/// Somewhere for the reading thread to put what it read.
private final class Drain: @unchecked Sendable {
    var data = Data()
}
