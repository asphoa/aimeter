import Foundation

/// Runs one already-pinned executable directly. No shell is ever involved;
/// arguments are inert array elements and the child receives a fresh, narrow
/// environment and an EOF on stdin.
enum CommandRun {
    static let outputLimit = ProcessRunner.outputLimit
    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    /// Injected by tests to count process launches without running real binaries.
    static var testHook: ((String, [String], String, TimeInterval, [String: String]) -> Attempt)?

    private static let deniedEnvKeys: Set<String> = [
        "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONSTARTUP", "PERL5OPT", "RUBYOPT",
        "BASH_ENV", "ENV", "ZDOTDIR", "SHELL", "PATH", "HOME"
    ]

    struct Attempt: Sendable {
        var exitCode: Int32?
        var stdout: Data
        var stderr: String
        var timedOut = false
        var outputTruncated = false
    }

    static func isDeniedEnvKey(_ key: String) -> Bool {
        if deniedEnvKeys.contains(key) { return true }
        if key.hasPrefix("DYLD_") || key.hasPrefix("LD_") { return true }
        return false
    }

    static func validateEnvironment(_ additions: [String: String]) -> Bool {
        !additions.keys.contains(where: isDeniedEnvKey)
    }

    static func allowedBinary(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.components(separatedBy: "/").contains("..") else { return nil }
        let fixed = URL(fileURLWithPath: path).standardizedFileURL.path
        guard fixed != "/usr/bin/security" else { return nil }
        let ordinary = ["/usr/local/bin/", "/opt/homebrew/bin/", expand("~/.local/bin/")]
            .contains { fixed.hasPrefix($0) && fixed.count > $0.count }
        let system = fixed.hasPrefix("/usr/bin/") && fixed.count > "/usr/bin/".count
        let app = fixed.range(of: #"^/Applications/[^/]+\.app/Contents/.+"#,
                              options: .regularExpression) != nil
        return ordinary || system || app ? fixed : nil
    }

    static func validHome(_ path: String) -> String? {
        let fixed = URL(fileURLWithPath: expand(path)).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fixed, isDirectory: &isDir), isDir.boolValue,
              let attrs = try? FileManager.default.attributesOfItem(atPath: fixed),
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { return nil }
        return fixed
    }

    static func isRunning(binary: String) -> Bool {
        let name = (binary as NSString).lastPathComponent
        guard !name.isEmpty else { return false }
        let sem = DispatchSemaphore(value: 0)
        var running = false
        Task {
            let out = await ProcessRunner.run(binary: "/usr/bin/pgrep", args: ["-x", name],
                                              stdinClosed: true, deadline: .seconds(5))
            running = out.exitCode == 0
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 6)
        return running
    }

    static func attempt(binary: String, args: [String], home: String,
                        timeout: TimeInterval = 30,
                        environment additions: [String: String] = [:],
                        refuseIfRunning: Bool = true) -> Attempt {
        if let hook = testHook {
            return hook(binary, args, home, timeout, additions)
        }
        guard let binary = allowedBinary(binary), let home = validHome(home) else {
            return Attempt(exitCode: nil, stdout: Data(), stderr: "invalid command destination")
        }
        if !validateEnvironment(additions) {
            return Attempt(exitCode: nil, stdout: Data(), stderr: "denied environment variable")
        }
        if refuseIfRunning, isRunning(binary: binary) {
            return Attempt(exitCode: nil, stdout: Data(), stderr: "command already running")
        }
        let validEnvName = try? NSRegularExpression(pattern: #"^[A-Z][A-Z0-9_]*$"#)
        var env = ["HOME": home, "PATH": fixedPath,
                   "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8",
                   "TERM": ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"]
        for (key, value) in additions {
            let range = NSRange(key.startIndex..<key.endIndex, in: key)
            guard !isDeniedEnvKey(key),
                  validEnvName?.firstMatch(in: key, range: range) != nil else { continue }
            env[key] = value
        }

        let sem = DispatchSemaphore(value: 0)
        var result = Attempt(exitCode: nil, stdout: Data(), stderr: "launch failed")
        Task {
            let out = await ProcessRunner.run(binary: binary, args: args, env: env, cwd: home,
                                              stdinClosed: true,
                                              deadline: .seconds(max(0.1, min(timeout, 30))))
            let stderr = String(decoding: out.stderr, as: UTF8.self)
            result = Attempt(exitCode: out.timedOut ? nil : out.exitCode,
                           stdout: out.stdout, stderr: stderr,
                           timedOut: out.timedOut, outputTruncated: out.outputTruncated)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout + 5)
        return result
    }
}
