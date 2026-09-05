import AppKit
import Foundation

func testKeychainModificationDateIsReadableAndAbsentWhenTheItemIs() {
    T.isNil("no item, no modification date",
            Keychain.modified(service: "AIMeter · tests · \(UUID().uuidString)"))

    let svc = "AIMeter · tests · \(UUID().uuidString)"
    defer { Credential.delete(service: svc) }
    T.check("test item stored", Credential.store("first", service: svc))
    // The claim being pinned: this returns a date having decrypted nothing, so
    // it costs no authorisation and can be asked on every refresh. Measured
    // separately on 2026-08-30 with an ad-hoc probe that was in neither the
    // item's ACL nor its partition list - it answered, with no panel.
    T.notNil("an existing item has a modification date", Keychain.modified(service: svc))
}

func testCredentialCacheFollowsTheItemRatherThanTheProcess() {
    // ClaudeProvider used to drop this cache by hand on every refresh whose
    // token looked expired, because a rotation by the CLI had to be noticed
    // somehow. That is now the cache's own job, and this is the assertion that
    // made removing the hand-written drop safe: a rewritten item is picked up
    // on the next read, with nobody having called `invalidate`.
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }

    T.check("first value stored", Credential.store("token-one", service: svc))
    guard case .success(let first) = Credential.read(acct) else {
        return T.check("first read succeeds", false)
    }
    T.eq("first read returns what was stored", first, "token-one")

    guard case .success(let again) = Credential.read(acct) else {
        return T.check("second read succeeds", false)
    }
    T.eq("an unchanged item reads the same", again, "token-one")

    // The keychain records modification dates to the second, so a rewrite
    // inside the same second would be indistinguishable from no rewrite at all
    // - which is a real (and harmless) limit of this mechanism, not a flaw in
    // the test: it costs one extra refresh interval, once, in the second a
    // token happens to rotate.
    Thread.sleep(forTimeInterval: 1.2)
    T.check("second value stored", Credential.store("token-two", service: svc))

    guard case .success(let rotated) = Credential.read(acct) else {
        return T.check("post-rotation read succeeds", false)
    }
    T.eq("a rewritten item is picked up without invalidate()", rotated, "token-two")
}

func testCredentialReportsABlankTokenAsASignOutNotAsAMissingOne() {
    // The pure predicate, on the shapes it has to tell apart.
    T.check("a blank subscription token is recognised",
            Credential.holdsBlankToken(json: claudeBlob(access: ""), field: nil))
    T.check("a real subscription token is not",
            !Credential.holdsBlankToken(json: claudeBlob(), field: nil))
    T.check("a blob with no token field at all is not",
            !Credential.holdsBlankToken(json: ["claudeAiOauth": ["subscriptionType": "max"]],
                                        field: nil))
    T.check("an MCP entry's blank token does not count as the subscription's",
            !Credential.holdsBlankToken(json: ["claudeAiOauth": ["accessToken": "ok"],
                                               "mcpOAuth": ["x": ["accessToken": ""]]],
                                        field: nil))
    T.check("keyJSONField narrows before the check, like everywhere else",
            Credential.holdsBlankToken(json: ["deepseek": ["api_key": ""], "other": ["api_key": "k"]],
                                       field: "deepseek"))

    // Through the real read path, on an item this app owns, so no panel.
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }
    func json(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }
    T.check("blank blob stored", Credential.store(json(claudeBlob(access: "")), service: svc))
    switch Credential.read(acct) {
    case .success(let s):
        T.check("a blank token is not handed out as a credential (got \(s))", false)
    case .failure(let e):
        T.check("the failure is marked blank", e.blank)
        T.eq("and worded as a blank credential, not a read failure",
             e.message, L.t("e.blanktoken"))
        T.check("and is not a denial", !e.denied)
    }

    // The item's own modification date moves on rewrite, so the cache lets
    // the sign-in back through without anyone calling invalidate().
    Thread.sleep(forTimeInterval: 1.2)
    T.check("real blob stored", Credential.store(json(claudeBlob()), service: svc))
    guard case .success(let token) = Credential.read(acct) else {
        return T.check("signing back in is picked up on the next read", false)
    }
    T.eq("signing back in is picked up on the next read", token, "sk-ant-oat-REAL")
}

func testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt() {
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    // A space and a brace exercise both the newline-stripping path and the
    // "looks like JSON" branch a caller further up the stack takes on the
    // returned string - this call itself does no JSON parsing.
    let dummy = "not a real token {with a space}"

    let add = Process()
    add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    add.arguments = ["add-generic-password", "-a", "aimeter-tests", "-s", svc,
                     "-w", dummy, "-U"]
    add.standardOutput = Pipe()
    add.standardError = Pipe()
    guard (try? add.run()) != nil else {
        T.skip("testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt",
               "could not run /usr/bin/security")
        return
    }
    add.waitUntilExit()
    guard add.terminationStatus == 0 else {
        T.skip("testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt",
               "security add-generic-password failed (exit \(add.terminationStatus))")
        return
    }
    defer {
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", svc]
        del.standardOutput = Pipe()
        del.standardError = Pipe()
        try? del.run()
        del.waitUntilExit()
    }

    switch Keychain.securityToolPassword(service: svc) {
    case .success(let s):
        T.eq("reads back exactly what was stored, no trailing newline", s, dummy)
    case .failure(let e):
        T.check("security-tool read of an apple-tool:-partitioned item succeeds (\(e.message))", false)
    }

    let missingSvc = "AIMeter · tests · \(UUID().uuidString)"
    switch Keychain.securityToolPassword(service: missingSvc) {
    case .success: T.check("a never-created service should not be found", false)
    case .failure(let e):
        T.eq("a missing item is reported as k.missing",
             e.message, L.t("k.missing", missingSvc))
    }
}

func testCheckNowForgetsARefusalButKeepsTheToken() {
    let svc = "AIMeter · tests · \(UUID().uuidString)"
    let acct = AccountSpec(name: "t", keychainService: svc)
    defer { Credential.delete(service: svc) }
    T.check("token stored", Credential.store("token-one", service: svc))
    guard let stamp = Keychain.modified(service: svc) else {
        return T.check("the item has a modification stamp", false)
    }

    // Plant the refusal a timer tick would have left behind.
    TokenCache.shared.clear(svc)
    TokenCache.shared.refuse(svc, stamp: stamp)
    switch Credential.read(acct) {
    case .success: T.check("a remembered refusal is honoured without a read", false)
    case .failure(let e):
        T.check("a remembered refusal is honoured without a read", e.denied)
        T.eq("in the words that promise the button will fix it", e.message, L.t("k.denied"))
    }

    // The button's door.
    Credential.forgetRefusal(acct)
    T.check("the refusal is forgotten", !TokenCache.shared.refused(svc, stamp: stamp))
    guard case .success(let got) = Credential.read(acct) else {
        return T.check("after forgetting, the item is read again", false)
    }
    T.eq("after forgetting, the item is read again", got, "token-one")

    // Forgetting a refusal must not throw away a token that was never refused:
    // a manual check on a healthy row would otherwise cost a fresh read, and
    // on the CLI's item a fresh read is a fresh panel.
    Credential.forgetRefusal(acct)
    T.eq("a cached token survives forgetRefusal",
         TokenCache.shared.value(svc, stamp: stamp), "token-one")
}

func testClaudeCLIActuallyRunsTheBinaryOnThisMachine() {
    guard let bin = ClaudeCLI.binary(nil) else {
        T.skip("testClaudeCLIActuallyRunsTheBinaryOnThisMachine", "claude CLI not installed")
        return
    }
    let home = trustedHome("~", marker: ".claude") ?? NSHomeDirectory()
    let outcome = ClaudeCLI.status(binary: bin, home: home)
    // Either answer means the subprocess started, spoke, and was understood.
    // What must not happen is `.failed`, which here would mean the environment
    // or the parsing is wrong — the 2026-08-25 USER bug, caught this way.
    switch outcome {
    case .signedIn, .signedOut:
        T.check("the real CLI ran and its report was understood", true)
    case .failed(let why):
        T.check("the real CLI ran and its report was understood (got: \(why))", false)
    }
    let dump = Config.dir + "/claude-cli-last.json"
    T.check("and the run left a dump to look at",
            FileManager.default.fileExists(atPath: dump))
    // The dump is the file most likely to be pasted somewhere while debugging.
    let text = (try? String(contentsOfFile: dump, encoding: .utf8)) ?? ""
    let emailRe = try! NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+"#)
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    T.check("dump has zero unredacted email-shaped substrings",
            emailRe.firstMatch(in: text, range: range) == nil)
    T.check("dump contains redaction marker", text.contains("<redacted>"))
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class LocalHTTPRedirectServer: @unchecked Sendable {
    private let fd: Int32
    private let box = LocalHTTPRedirectServerBox()
    private var thread: Thread?

    var port: UInt16 { box.port }

    init?(handler: @escaping (String, [String: String]) -> (status: Int, headers: [String: String], body: String)) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }
        fd = sock
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0, listen(sock, 4) == 0 else { close(sock); return nil }
        var bound = addr
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                _ = getsockname(sock, addrPtr, &len)
            }
        }
        box.port = UInt16(bound.sin_port).byteSwapped
        box.handler = handler
        box.fd = sock
        let t = Thread {
            while !self.box.stop {
                var clientAddr = sockaddr()
                var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
                let client = accept(sock, &clientAddr, &clientLen)
                guard client >= 0 else { continue }
                defer { close(client) }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = recv(client, &buf, buf.count, 0)
                guard n > 0 else { continue }
                let req = String(decoding: buf.prefix(n), as: UTF8.self)
                let lines = req.split(separator: "\n", omittingEmptySubsequences: false)
                guard let first = lines.first else { continue }
                let parts = first.split(separator: " ")
                guard parts.count >= 2 else { continue }
                let path = String(parts[1])
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { break }
                    guard let colon = trimmed.firstIndex(of: ":") else { continue }
                    let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                    let value = String(trimmed[trimmed.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
                let response = self.box.handler?(path, headers)
                    ?? (status: 404, headers: [String: String](), body: "missing")
                let statusText = response.status == 200 ? "OK" : "Found"
                var out = "HTTP/1.1 \(response.status) \(statusText)\r\n"
                for (k, v) in response.headers { out += "\(k): \(v)\r\n" }
                out += "Content-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n"
                out += response.body
                _ = out.withCString { send(client, $0, strlen($0), 0) }
            }
            close(sock)
        }
        thread = t
        t.start()
    }

    func stop() {
        box.stop = true
        shutdown(fd, SHUT_RDWR)
        close(fd)
        thread?.cancel()
    }
}

private final class LocalHTTPRedirectServerBox: @unchecked Sendable {
    var stop = false
    var port: UInt16 = 0
    var fd: Int32 = -1
    var handler: ((String, [String: String]) -> (status: Int, headers: [String: String], body: String))?
}

func testNetFollowsSameOriginRedirectViaLocalServer() {
    var nextAuth: String?
    guard let server = LocalHTTPRedirectServer(handler: { path, headers in
        switch path {
        case "/start":
            // Relative Location: the client resolves it against the request
            // URL, so the hop keeps the ephemeral port. Rebuilding an absolute
            // URL from the Host header silently dropped the port, which made
            // this a cross-origin hop and the delegate refused it - the test
            // then looked like "localhost HTTP is blocked".
            return (status: 302, headers: ["Location": "/next"], body: "")
        case "/next":
            nextAuth = headers["authorization"]
            return (status: 200, headers: [:], body: "ok")
        case "/cross-start":
            return (status: 302, headers: ["Location": "http://evil.example/collect"], body: "")
        default:
            return (status: 404, headers: [:], body: "missing")
        }
    }) else {
        T.skip("testNetFollowsSameOriginRedirectViaLocalServer", "could not bind local HTTP server")
        return
    }
    defer { server.stop() }
    Thread.sleep(forTimeInterval: 0.05)

    let origin = URL(string: "http://127.0.0.1:\(server.port)/start")!
    var request = URLRequest(url: origin)
    request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
    let delegate = Net.SameHostRedirectDelegate(originalURL: origin)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 5
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    let sem = DispatchSemaphore(value: 0)
    var body: String?
    var err: Error?
    session.dataTask(with: request) { data, _, error in
        body = data.flatMap { String(data: $0, encoding: .utf8) }
        err = error
        sem.signal()
    }.resume()
    guard sem.wait(timeout: .now() + 5) == .success else {
        T.check("same-origin redirect request completes", false)
        return
    }
    T.isNil("same-origin redirect raises no error", err)
    T.eq("redirect target body received", body, "ok")
    // Measured, not assumed: Foundation drops Authorization when it follows a
    // redirect, even same-origin. The delegate is the first line of defence,
    // this is the second - so a credential cannot ride a redirect at all.
    T.isNil("Authorization is not carried across the hop", nextAuth)

    var crossReq = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/cross-start")!)
    crossReq.setValue("Bearer leaked", forHTTPHeaderField: "Authorization")
    let crossDelegate = Net.SameHostRedirectDelegate(originalURL: crossReq.url!)
    let crossSession = URLSession(configuration: config, delegate: crossDelegate, delegateQueue: nil)
    let crossSem = DispatchSemaphore(value: 0)
    var crossStatus: Int?
    crossSession.dataTask(with: crossReq) { _, resp, _ in
        crossStatus = (resp as? HTTPURLResponse)?.statusCode
        crossSem.signal()
    }.resume()
    _ = crossSem.wait(timeout: .now() + 5)
    T.eq("cross-origin redirect is refused", crossStatus, 302)
}

func runIntegrationTests() {
    T.beginTest("testKeychainModificationDateIsReadableAndAbsentWhenTheItemIs")
    testKeychainModificationDateIsReadableAndAbsentWhenTheItemIs()
    T.beginTest("testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt")
    testSecurityToolReadsAnItemWrittenTheWayTheCLIWritesIt()
    T.beginTest("testCredentialCacheFollowsTheItemRatherThanTheProcess")
    testCredentialCacheFollowsTheItemRatherThanTheProcess()
    T.beginTest("testCredentialReportsABlankTokenAsASignOutNotAsAMissingOne")
    testCredentialReportsABlankTokenAsASignOutNotAsAMissingOne()
    T.beginTest("testCheckNowForgetsARefusalButKeepsTheToken")
    testCheckNowForgetsARefusalButKeepsTheToken()
    T.beginTest("testClaudeCLIActuallyRunsTheBinaryOnThisMachine")
    testClaudeCLIActuallyRunsTheBinaryOnThisMachine()
    T.beginTest("testNetFollowsSameOriginRedirectViaLocalServer")
    testNetFollowsSameOriginRedirectViaLocalServer()
}
