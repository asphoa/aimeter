import Foundation

/// Runs one already-pinned executable directly. No shell is ever involved;
/// arguments are inert array elements and the child receives a fresh, narrow
/// environment and an EOF on stdin.
enum CommandRun {
    static let outputLimit = 1_048_576
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: home)
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe; process.standardError = errPipe

        do { try process.run() } catch {
            return Attempt(exitCode: nil, stdout: Data(), stderr: error.localizedDescription)
        }

        let out = CommandDrain(), err = CommandDrain()
        let drained = DispatchGroup()
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.readData(ofLength: 65_536)
                    if chunk.isEmpty { break }
                    box.append(chunk, limit: outputLimit)
                }
                drained.leave()
            }
        }

        let deadline = Date().addingTimeInterval(min(max(timeout, 0.1), 30))
        while process.isRunning, Date() < deadline { usleep(50_000) }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)
        let stderr = String(decoding: err.data, as: UTF8.self)
        return Attempt(exitCode: timedOut ? nil : process.terminationStatus,
                       stdout: out.data, stderr: stderr, timedOut: timedOut,
                       outputTruncated: out.truncated || err.truncated)
    }
}

private final class CommandDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private(set) var truncated = false

    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }

    func append(_ chunk: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        let room = max(0, limit - storage.count)
        if room > 0 { storage.append(chunk.prefix(room)) }
        if chunk.count > room { truncated = true }
    }
}
