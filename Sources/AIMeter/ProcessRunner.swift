import Foundation
import Darwin

/// One subprocess runner with a monotonic deadline, graceful then forced
/// termination, synchronous output draining, and a hard byte cap.
enum ProcessRunner {
    static let outputLimit = 1_048_576
    private static let graceNanos: UInt64 = 2_000_000_000

    struct Output: Sendable {
        var exitCode: Int32
        var stdout: Data
        var stderr: Data
        var timedOut = false
        var outputTruncated = false
        var killed = false
    }

    /// Optional pty interaction: master fd, accumulated output, clock, deadline.
    /// Return true when reading may stop early.
    typealias PTYInteract = (Int32, inout Data, ContinuousClock, ContinuousClock.Instant) -> Bool

    /// Injected by tests to count launches without running real binaries.
    static var testHook: ((String, [String], [String: String]?, String?, Duration, Bool) async -> Output)?

    static func run(binary: String,
                    args: [String] = [],
                    env: [String: String]? = nil,
                    cwd: String? = nil,
                    stdinClosed: Bool = true,
                    deadline: Duration = .seconds(30),
                    pty: Bool = false,
                    ptySize: winsize = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0),
                    ptyInteract: PTYInteract? = nil) async -> Output {
        if let hook = testHook {
            return await hook(binary, args, env, cwd, deadline, pty)
        }
        return await Task.detached(priority: .utility) {
            if pty {
                return runPTYSync(binary: binary, args: args, env: env, cwd: cwd,
                                  deadline: deadline, ptySize: ptySize, interact: ptyInteract)
            }
            return runSync(binary: binary, args: args, env: env, cwd: cwd,
                           stdinClosed: stdinClosed, deadline: deadline)
        }.value
    }

    private static func isolateProcessGroup(_ pid: pid_t) -> Bool {
        if setpgid(pid, pid) == 0 { return true }
        return errno == EACCES
    }

    private static func signalProcess(_ pid: pid_t, ownGroup: Bool, _ sig: Int32) {
        if ownGroup {
            kill(-pid, sig)
        } else {
            kill(pid, sig)
        }
    }

    private static func runSync(binary: String,
                                args: [String],
                                env: [String: String]?,
                                cwd: String?,
                                stdinClosed: Bool,
                                deadline: Duration) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        if stdinClosed { process.standardInput = FileHandle.nullDevice }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return Output(exitCode: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }

        let pid = process.processIdentifier
        let ownGroup = isolateProcessGroup(pid)

        var stdout = Data(), stderr = Data()
        var outTrunc = false, errTrunc = false
        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        fcntl(outFD, F_SETFL, fcntl(outFD, F_GETFL, 0) | O_NONBLOCK)
        fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL, 0) | O_NONBLOCK)

        let clock = ContinuousClock()
        let end = clock.now + deadline
        var timedOut = false
        var killed = false

        func drain(_ fd: Int32, into storage: inout Data, truncated: inout Bool) {
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n <= 0 { break }
                let room = max(0, outputLimit - storage.count)
                if room > 0 { storage.append(contentsOf: buf[0..<min(n, room)]) }
                if n > room { truncated = true }
            }
        }

        while process.isRunning {
            drain(outFD, into: &stdout, truncated: &outTrunc)
            drain(errFD, into: &stderr, truncated: &errTrunc)
            if clock.now >= end {
                timedOut = true
                signalProcess(pid, ownGroup: ownGroup, SIGTERM)
                let graceEnd = clock.now + .seconds(2)
                while process.isRunning, clock.now < graceEnd {
                    drain(outFD, into: &stdout, truncated: &outTrunc)
                    drain(errFD, into: &stderr, truncated: &errTrunc)
                    usleep(10_000)
                }
                if process.isRunning {
                    signalProcess(pid, ownGroup: ownGroup, SIGKILL)
                    killed = true
                }
                break
            }
            usleep(5_000)
        }

        drain(outFD, into: &stdout, truncated: &outTrunc)
        drain(errFD, into: &stderr, truncated: &errTrunc)
        process.waitUntilExit()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        return Output(exitCode: process.terminationStatus,
                      stdout: stdout, stderr: stderr,
                      timedOut: timedOut,
                      outputTruncated: outTrunc || errTrunc,
                      killed: killed)
    }

    private static func runPTYSync(binary: String,
                                   args: [String],
                                   env: [String: String]?,
                                   cwd: String?,
                                   deadline: Duration,
                                   ptySize: winsize,
                                   interact: PTYInteract?) -> Output {
        var master: Int32 = 0, slave: Int32 = 0
        var size = ptySize
        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            return Output(exitCode: -1, stdout: Data(), stderr: Data("openpty failed".utf8))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { process.environment = env }
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
        } catch {
            close(master); close(slave)
            return Output(exitCode: -1, stdout: Data(), stderr: Data(error.localizedDescription.utf8))
        }
        close(slave)

        let pid = process.processIdentifier
        let ownGroup = isolateProcessGroup(pid)

        var stdout = Data()
        var truncated = false
        let clock = ContinuousClock()
        let end = clock.now + deadline
        var timedOut = false
        var killed = false
        var done = false

        func pollRead() {
            var fds = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, 0)
            guard ready > 0, (fds.revents & Int16(POLLIN)) != 0 else { return }
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = Darwin.read(master, &buf, buf.count)
                if n <= 0 { break }
                let room = max(0, outputLimit - stdout.count)
                if room > 0 { stdout.append(contentsOf: buf[0..<min(n, room)]) }
                if n > room { truncated = true }
                if n < buf.count { break }
            }
        }

        while process.isRunning, !done {
            pollRead()
            if let interact, interact(master, &stdout, clock, end) { done = true }
            if clock.now >= end {
                timedOut = true
                signalProcess(pid, ownGroup: ownGroup, SIGTERM)
                let graceEnd = clock.now + .seconds(2)
                while process.isRunning, clock.now < graceEnd {
                    pollRead()
                    usleep(10_000)
                }
                if process.isRunning {
                    signalProcess(pid, ownGroup: ownGroup, SIGKILL)
                    killed = true
                }
                break
            }
            usleep(5_000)
        }

        pollRead()
        if process.isRunning, done {
            _ = "\u{03}".utf8.withContiguousStorageIfAvailable { Darwin.write(master, $0.baseAddress, $0.count) }
            process.terminate()
        }
        process.waitUntilExit()
        close(master)

        return Output(exitCode: process.terminationStatus,
                      stdout: stdout, stderr: Data(),
                      timedOut: timedOut,
                      outputTruncated: truncated,
                      killed: killed)
    }
}
